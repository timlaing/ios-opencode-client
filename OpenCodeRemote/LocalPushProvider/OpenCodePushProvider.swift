import Foundation
import NetworkExtension
import os
import OpenCodeDomain
import OpenCodeStorage
import OpenCodeTransport
import UserNotifications

/// Local Push Connectivity provider for OpenCode hosts
/// (docs/local-push-implementation.md).
///
/// Activation on a device still requires the approved app-push-provider
/// entitlement on app and provider targets plus the App Group/Keychain
/// sharing groups (docs/design-review.md release gates); those entitlement
/// files are deliberately absent from the repository until Apple approves.
/// Everything below the entitlement — configuration decoding, per-host
/// observers, classification, ledger-backed scheduling — is complete and
/// runs the moment the signed entitlement exists.
final class OpenCodePushProvider: NEAppPushProvider {
    /// Versioned configuration payload carried in `providerConfiguration`.
    /// Identifiers and revision only — never passwords, tokens, prompts or
    /// transcript text (spec §"App-side manager configuration" step 3).
    typealias ConfigurationPayload = PushProviderConfiguration

    private let logger = Logger(
        subsystem: "uk.co.laingcorp.opencode-client.LocalPushProvider",
        category: "OpenCodePushProvider"
    )

    private var generation = 0
    private var supervisors: [String: HostEventSupervisor] = [:]
    private var ledger: NotificationLedger?
    private var hostStore: HostStore?
    private let credentials = KeychainCredentialStore()
    private var configurationObservation: NSKeyValueObservation?

    // MARK: - NEAppPushProvider lifecycle

    override func start(completionHandler: @escaping (Error?) -> Void) {
        generation += 1
        logger.info("start (generation \(self.generation))")
        do {
            let configuration = try decodeConfiguration()
            try prepareStores()
            startObservers(for: configuration, generation: generation)
            observeConfigurationChanges()
            // Per-host status stays authoritative: a success callback is not
            // evidence that every stream is ready (spec §7).
            completionHandler(nil)
        } catch {
            logger.error("start failed: \(String(describing: error))")
            completionHandler(error)
        }
    }

    override func stop(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("stop reason \(String(describing: reason))")
        generation += 1 // stale callbacks from the old generation are ignored
        configurationObservation = nil
        let stopping = supervisors.values
        supervisors = [:]
        Task { @Sendable in
            for supervisor in stopping {
                await supervisor.stop()
            }
            completionHandler()
        }
    }

    override func handleTimerEvent() {
        for supervisor in supervisors.values {
            Task { await supervisor.handleTimerEvent() }
        }
    }

    /// Applies configuration diffs: start new hosts, stop removed hosts,
    /// leave healthy streams untouched (spec §7). Cancel old observers
    /// before replacing them.
    private func observeConfigurationChanges() {
        configurationObservation = observe(\.providerConfiguration, options: [.new]) { [weak self] _, _ in
            self?.applyConfigurationChange()
        }
    }

    private func applyConfigurationChange() {
        generation += 1
        let generation = generation
        do {
            let configuration = try decodeConfiguration()
            let desired = Set(configuration.hostIDs)
            for (hostID, supervisor) in supervisors where !desired.contains(hostID) {
                supervisors.removeValue(forKey: hostID)
                Task { await supervisor.stop() }
                logger.info("stopped removed host observer")
            }
            try prepareStores()
            startObservers(for: configuration, generation: generation)
        } catch {
            logger.error("configuration change rejected: \(String(describing: error))")
        }
    }

    // MARK: - Wiring

    private func decodeConfiguration() throws -> ConfigurationPayload {
        guard let raw = providerConfiguration?["payload"] as? Data else {
            throw StoreIssue.missingConfiguration
        }
        let payload = try JSONDecoder().decode(ConfigurationPayload.self, from: raw)
        guard payload.schemaVersion == ConfigurationPayload.currentSchemaVersion else {
            throw StoreIssue.unsupportedSchema(payload.schemaVersion)
        }
        return payload
    }

    private enum StoreIssue: Error {
        case missingConfiguration
        case unsupportedSchema(Int)
        case storesUnavailable
    }

    private func prepareStores() throws {
        let directory = try SharedStoreLocation.directory()
        hostStore = try HostStore(writingAt: directory)
        ledger = try NotificationLedger(writingAt: directory)
    }

    private func startObservers(for configuration: ConfigurationPayload, generation: Int) {
        guard let hostStore, let ledger else { return }
        let hosts = (try? hostStore.hosts()) ?? []
        for host in hosts where configuration.hostIDs.contains(host.id.rawValue) {
            guard supervisors[host.id.rawValue] == nil else { continue } // never a second stream per host
            let secret: String?
            do { secret = try credentials.secret(for: host.id.rawValue) } catch { secret = nil }
            guard let secret else {
                logger.warning("host has no stored credential; observer not started")
                continue
            }
            supervisors[host.id.rawValue] = makeSupervisor(
                host: host,
                secret: secret,
                ledger: ledger,
                generation: generation
            )
        }
    }

    private func makeSupervisor(
        host: OpenCodeDomain.Host,
        secret: String,
        ledger: NotificationLedger,
        generation: Int
    ) -> HostEventSupervisor {
        let logger = self.logger
        return HostEventSupervisor(
            host: host,
            classifier: EventClassifier(hostID: host.id.rawValue, policy: NotificationPolicy()),
            environment: .init(
                makeTransport: { address, credential in
                    URLSessionTransport(baseURL: address, credential: credential)
                },
                credential: { BasicCredential(secret: secret) },
                sleep: { duration in
                    try await Task.sleep(for: duration)
                },
                jitter: { Double.random(in: 0...1) },
                now: { Date() }
            ),
            callbacks: .init(
                onStatus: { status in
                    // Status publication to the shared store ships with the
                    // S17 status/diagnostics screens; transitions are logged
                    // redacted meanwhile (spec §"Status and diagnostics").
                    logger.info("host stream status: \(String(describing: status))")
                },
                deliver: { draft in
                    await Self.schedule(draft: draft, hostID: host.id.rawValue, ledger: ledger, logger: logger)
                },
                onReconnect: {
                    // Reconciliation of followed sessions uses the W03/W04
                    // read APIs once those slices land; the stream never
                    // replays history, so bootstrap cannot flood alerts
                    // (spec §"OpenCode-specific stream adapter").
                }
            )
        )
    }

    /// Ledger-claimed scheduling through UNUserNotificationCenter. The
    /// ledger key is the request identifier, so the OS dedupes repeats and
    /// overlapping provider lifetimes cannot double-schedule a transition.
    private static func schedule(
        draft: NotificationDraft,
        hostID: String,
        ledger: NotificationLedger,
        logger: Logger
    ) async {
        let claimed = (try? ledger.claim(
            key: draft.ledgerKey,
            hostID: hostID,
            category: draft.category.rawValue,
            sessionID: draft.sessionID,
            owner: "provider",
            lease: 60
        )) ?? false
        guard claimed else { return }

        let content = UNMutableNotificationContent()
        content.title = draft.title
        content.body = draft.body
        // Routing identifiers only — no transcript text, tool arguments or
        // file content; a tap leads to reauthentication/refetch, never an
        // automatic approval (spec §"Notification classification").
        content.userInfo = [
            "ledgerKey": draft.ledgerKey,
            "sessionID": draft.sessionID,
            "ownerID": draft.ownerID ?? "",
            "category": draft.category.rawValue,
        ]
        let request = UNNotificationRequest(identifier: draft.ledgerKey, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            try ledger.recordScheduled(key: draft.ledgerKey)
        } catch {
            try? ledger.recordFailed(key: draft.ledgerKey)
            logger.error("notification scheduling failed")
        }
    }
}
