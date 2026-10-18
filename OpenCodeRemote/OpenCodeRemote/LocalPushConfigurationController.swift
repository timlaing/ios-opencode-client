import Foundation
import NetworkExtension
import OpenCodeDomain

/// App-side NEAppPushManager preference operations, abstracted so the
/// reconciliation controller is testable without the platform type
/// (docs/local-push-implementation.md §"App-side manager configuration").
@MainActor
protocol PushManagerAdapter: AnyObject {
    /// Only this app's managed configurations.
    func loadAll() async throws -> [ManagedPushConfiguration]
    func save(_ configuration: ManagedPushConfiguration) async throws
    func remove(ssid: String) async throws
}

/// Serializes and coalesces reconciliation of NEAppPushManager preferences,
/// with the tested `PushConfigurationPlanner` as its policy engine (spec
/// steps 1–6). No view writes manager preferences directly; failures
/// surface through `lastFailure` for the S17 status/retry UX.
///
/// The SSID-eligibility input comes from user settings (W17/S17); reading
/// the *current* network is a convenience for recovery, not a prerequisite
/// for configuration. A recovery action never enables APNs, starts a
/// tunnel, submits a prompt, or changes server configuration.
@MainActor
final class LocalPushConfigurationController {
    private let adapter: PushManagerAdapter
    /// HA-derived initial default (spec §"App-side manager configuration"):
    /// a reference-derived starting value, not an Apple timing guarantee.
    private let settleDelay: TimeInterval

    private var isApplying = false
    private var queued: [LocalPushHostEligibility]?
    private(set) var lastFailure: String?
    private(set) var revision = 0
    /// Sessions followed across hosts, propagated to the local-push
    /// extension through the manager payload. Populated by the app's
    /// session workflows (W03+); empty means "notify nothing yet", which
    /// is the correct default until those flows exist.
    var followedSessions: [String] = []

    /// Upgrades stored credentials for hosts that gained local-push access
    /// to the docs-mandated background-readable class
    /// (docs/implementation-defaults.md: AfterFirstUnlockThisDeviceOnly
    /// once local-push access is enabled — the extension may start while
    /// the device is locked). Injected so this controller stays free of
    /// Keychain dependencies; the composition root wires the real store.
    private let enableBackgroundAccess: ([String]) -> Void

    init(
        adapter: PushManagerAdapter,
        settleDelay: TimeInterval = 0.5,
        enableBackgroundAccess: @escaping ([String]) -> Void = { _ in }
    ) {
        self.adapter = adapter
        self.settleDelay = settleDelay
        self.enableBackgroundAccess = enableBackgroundAccess
    }

    /// Requests a reconciliation. Latest-wins coalescing: while an apply is
    /// in flight, further requests replace the queued one, so a queued
    /// user Disable/Remove is serviced as soon as the gate releases and
    /// intermediate churn is dropped.
    func reconcile(eligibility: [LocalPushHostEligibility]) {
        queued = eligibility
        guard !isApplying else { return }
        isApplying = true
        Task { await applyLoop() }
    }

    private func applyLoop() async {
        defer { isApplying = false }
        while let request = queued {
            queued = nil
            do {
                try await apply(request)
                lastFailure = nil
            } catch {
                lastFailure = Self.message(for: error)
                // The gate is released by looping on whatever is queued —
                // a request that arrived during the failed apply is not
                // lost behind the retry.
            }
        }
    }

    private func apply(_ eligibility: [LocalPushHostEligibility]) async throws {
        revision += 1
        let desired = PushConfigurationPlanner.desiredState(from: eligibility)
        let current = try await adapter.loadAll()
        let plan = PushConfigurationPlanner.plan(
            desired: desired,
            current: current,
            revision: revision,
            followedSessions: followedSessions
        )
        for ssid in plan.removals {
            try await adapter.remove(ssid: ssid)
        }
        for upsert in plan.upserts {
            try await adapter.save(upsert)
        }
        // Local-push access is now (or still) enabled for these hosts:
        // their credentials must be readable while the device is locked
        // (docs/implementation-defaults.md — AfterFirstUnlockThisDeviceOnly
        // once background access is enabled). Runs on every apply so a
        // re-pair that downgraded the class is healed; the store treats a
        // missing credential as a no-op.
        let enabledHostIDs = Set(eligibility.filter(\.enabled).map(\.hostID)).sorted()
        if !enabledHostIDs.isEmpty {
            enableBackgroundAccess(enabledHostIDs)
        }
        guard !plan.isEmpty else { return }
        // Adopt the settle delay before reloading: a successful save is not
        // evidence of an active manager (spec step 5).
        try await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        _ = try await adapter.loadAll()
    }

    private static func message(for error: Error) -> String {
        switch error {
        case is CancellationError:
            return "Local push configuration was interrupted. Try again."
        default:
            return "Local push settings could not be saved: \(error.localizedDescription). Your host pairing is unaffected."
        }
    }
}

/// The production adapter over NEAppPushManager preferences, matching only
/// this app's provider configurations (spec step 2).
@MainActor
final class NEAppPushManagerAdapter: PushManagerAdapter {
    private let providerBundleIdentifier: String

    init(providerBundleIdentifier: String) {
        self.providerBundleIdentifier = providerBundleIdentifier
    }

    func loadAll() async throws -> [ManagedPushConfiguration] {
        let managers = try await loadAllManagers()
        return managers
            .filter { $0.providerBundleIdentifier == providerBundleIdentifier }
            .compactMap { manager -> ManagedPushConfiguration? in
                guard let ssid = manager.matchSSIDs.first,
                      let data = manager.providerConfiguration["payload"] as? Data,
                      let payload = try? JSONDecoder().decode(PushProviderConfiguration.self, from: data)
                else { return nil }
                return ManagedPushConfiguration(
                    ssid: ssid,
                    hostIDs: payload.hostIDs,
                    revision: payload.revision,
                    followedSessions: payload.followedSessions
                )
            }
    }

    func save(_ configuration: ManagedPushConfiguration) async throws {
        let matches = try await loadAllManagers().filter {
            $0.providerBundleIdentifier == providerBundleIdentifier && $0.matchSSIDs.first == configuration.ssid
        }
        // Stale preferences can hold duplicates for one SSID (interrupted
        // save): keep the first, remove the rest so the rewrite reconciles.
        for extra in matches.dropFirst() {
            try await removeFromPreferences(extra)
        }
        let manager = matches.first ?? NEAppPushManager()
        manager.providerBundleIdentifier = providerBundleIdentifier
        manager.localizedDescription = "OpenCode Client — \(configuration.ssid)"
        manager.matchSSIDs = [configuration.ssid]
        manager.isEnabled = true
        var providerConfiguration = manager.providerConfiguration
        providerConfiguration["payload"] = try JSONEncoder().encode(
            PushProviderConfiguration(
                revision: configuration.revision,
                hostIDs: configuration.hostIDs,
                followedSessions: configuration.followedSessions
            )
        )
        manager.providerConfiguration = providerConfiguration
        try await saveToPreferences(manager)
    }

    func remove(ssid: String) async throws {
        let managers = try await loadAllManagers().filter {
            $0.providerBundleIdentifier == providerBundleIdentifier && $0.matchSSIDs.first == ssid
        }
        for manager in managers {
            try await removeFromPreferences(manager)
        }
    }

    // NEAppPushManager preference APIs are completion-based; bridge them.

    private func loadAllManagers() async throws -> [NEAppPushManager] {
        try await withCheckedThrowingContinuation { continuation in
            NEAppPushManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func saveToPreferences(_ manager: NEAppPushManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func removeFromPreferences(_ manager: NEAppPushManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
