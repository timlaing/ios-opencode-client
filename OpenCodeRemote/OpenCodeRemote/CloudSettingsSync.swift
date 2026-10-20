import Foundation
import Observation
import OpenCodeDomain

/// The KVS touch points behind a protocol so the merge, tombstone
/// and quota rules are testable without NSUbiquitousKeyValueStore.
/// Not Sendable by design: the engine is MainActor-isolated, the real
/// store is thread-safe but Apple-owned.
protocol KeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func removeValue(forKey key: String)
}

/// The real NSUbiquitousKeyValueStore bridge. KVS writes never throw —
/// Apple's quota failures arrive later, as the store's external-change
/// notification (see CloudSettingsSync.noteQuotaFailure).
final class UbiquitousKeyValueStore: KeyValueStore {
    private let store: NSUbiquitousKeyValueStore

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
    }

    func string(forKey key: String) -> String? {
        store.string(forKey: key)
    }

    func set(_ value: String, forKey key: String) {
        store.set(value, forKey: key)
        store.synchronize()
    }

    func removeValue(forKey key: String) {
        store.removeObject(forKey: key)
        store.synchronize()
    }
}

/// W17 iCloud settings sync (docs/implementation-defaults.md I6):
/// NSUbiquitousKeyValueStore carries ONLY the opted-in scope —
/// appearance and host addresses, versioned per field with stable
/// host UUIDs, deletion tombstones and deterministic device-ID
/// tie-breaking. Never credentials, pairing codes, authorization-
/// bearing URLs, notification enrollment, drafts or attachment
/// references. Turning sync off keeps local settings and stops
/// applying cloud changes; a separate confirmed Clear Synced Settings
/// removes the cloud records (tombstones included). Quota failures
/// keep every local edit and report status — they never lose data.
@MainActor
@Observable
final class CloudSettingsSync {
    static let key = "settings.sync.v1"
    static let mirrorKey = "settings.synclocal.v1"
    private static let deviceIDKey = "settings.sync.deviceid.v1"

    // MARK: - Records (versioned, stable identities)

    /// The one versioned payload. A schema mismatch reads as empty
    /// rather than guessing — sync converges instead of corrupting.
    struct Snapshot: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var appearance: Record<AppearanceMode>?
        /// Keyed by STABLE HOST UUID, addresses stripped of
        /// userinfo/query/fragment before acceptance. A tombstoned
        /// record keeps its identity until Clear Synced Settings, so
        /// a deletion cannot resurrect from a slower device's stale
        /// upload.
        var hosts: [String: HostRecord] = [:]
    }

    struct Record<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        var value: Value
        var modifiedAt: Date
        var deviceID: String
    }

    struct HostRecord: Codable, Equatable, Sendable {
        /// Stored WITHOUT userinfo/query/fragment — a synced record
        /// can never carry credentials forward.
        var address: String
        var modifiedAt: Date
        var deviceID: String
        var deletedAt: Date?
    }

    /// What one reconcile pass actually achieved — surfaced in S19.
    struct SyncReport: Equatable, Sendable {
        /// A newer cloud edit was applied to local appearance.
        var appearanceApplied = false
        /// Live (non-tombstoned) addresses in the synced list.
        var syncedHostCount = 0
        /// Cloud addresses NOT paired on this device — OFFERED for
        /// merge, never silently merged with another credential
        /// identity (docs I6). The pairing-flow offer UI rides with a
        /// later slice; W17 surfaces them in S19.
        var pendingCandidates: [String] = []
    }

    // MARK: - Pure rules (tested directly)

    /// Which recorded edit wins (docs I6: "last recorded edit per
    /// field, with modification time and deterministic device-ID
    /// tie-breaking"). Eventually consistent only — the docs are
    /// explicit this leans on device clocks, not a distributed
    /// ordering guarantee.
    static func wins(_ a: (date: Date, device: String), over b: (date: Date, device: String)) -> Bool {
        if a.date != b.date { return a.date > b.date }
        return a.device > b.device
    }

    /// An address is stored WITHOUT userinfo, query or fragment
    /// (docs I6: "Strip URL userinfo/query/fragment before accepting
    /// a host address"). A malformed string passes through unchanged
    /// — refusing it would silently drop a host address.
    static func strippedAddress(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? raw
    }

    // MARK: - Instance

    private let store: KeyValueStore
    private let defaults: UserDefaults
    private let deviceID: String
    private let now: () -> Date
    private var observers: [NSObjectProtocol] = []

    private(set) var status: SyncStatus = .off
    private(set) var lastReport = SyncReport()

    enum SyncStatus: Equatable, Sendable {
        case off
        case upToDate
        case error(String)
    }

    init(
        store: KeyValueStore = UbiquitousKeyValueStore(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.defaults = defaults
        self.deviceID = CloudSettingsSync.installDeviceID(defaults: defaults)
        self.now = now
    }

    /// The stable per-install ID the tie-break needs (docs I6) — one
    /// random UUID per installation, kept in LOCAL defaults so it is
    /// never part of the synced payload.
    static func installDeviceID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: deviceIDKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIDKey)
        return fresh
    }

    /// The stored snapshot; a corrupt or foreign-schema payload reads
    /// as empty — a bad line must never wedge sync or the settings
    /// that lean on it.
    func snapshot() -> Snapshot {
        guard let raw = store.string(forKey: Self.key),
              let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaVersion == Snapshot().schemaVersion
        else {
            return Snapshot()
        }
        return snapshot
    }

    /// What THIS device last recorded — the local half of the
    /// per-field merge (docs I6's "last recorded edit per field").
    /// Hosts are included so a VANISHING is measured against this
    /// device's own previous set: a cloud-only record from another
    /// device is never in here, so this device never tombstones it (it
    /// stays a pending candidate until offered and merged).
    private struct LocalMirror: Codable {
        var appearance: Record<AppearanceMode>?
        var hosts: [String: HostRecord] = [:]
    }

    private var localMirror: LocalMirror {
        get {
            defaults.data(forKey: Self.mirrorKey)
                .flatMap { try? JSONDecoder().decode(LocalMirror.self, from: $0) }
                ?? LocalMirror()
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.mirrorKey)
        }
    }

    /// One pull-merge-push-apply pass. Nothing is read or written
    /// while sync is off (the opt-in gate: iCloud off until opted in
    /// — implementation-defaults.md). A quota or write failure leaves
    /// local state untouched and surfaces through `status`.
    @discardableResult
    func reconcile(
        settings: SettingsLibrary,
        hostAddresses: [String: String]
    ) -> SyncReport {
        guard settings.state.icloudSyncRequested else {
            status = .off
            lastReport = SyncReport()
            return lastReport
        }

        let cloud = snapshot()
        var report = SyncReport()

        // --- Appearance: last recorded edit per field.
        var mirror = localMirror
        var localAppearance = mirror.appearance
        if localAppearance?.value != settings.state.appearance {
            localAppearance = Record(value: settings.state.appearance, modifiedAt: now(), deviceID: deviceID)
        }
        var mergedAppearance = localAppearance
        if let cloudAppearance = cloud.appearance {
            let beatsOurs = mergedAppearance.map {
                Self.wins(
                    (cloudAppearance.modifiedAt, cloudAppearance.deviceID),
                    over: ($0.modifiedAt, $0.deviceID)
                )
            } ?? true
            if beatsOurs { mergedAppearance = cloudAppearance }
        }
        if let winner = mergedAppearance, winner.value != settings.state.appearance {
            settings.update { $0.appearance = winner.value }
            report.appearanceApplied = true
        }

        // --- Hosts: per-host records with tombstones kept until Clear.
        // `mergedHosts` starts from the cloud list; `ownHosts` tracks
        // THIS device's own live set (persisted to the mirror) so a
        // vanishing is measured against what this device itself
        // recorded — never against cloud-only records another device
        // synced (those are pending candidates, not removals).
        var mergedHosts = cloud.hosts
        var ownHosts: [String: HostRecord] = [:]
        for (hostID, address) in hostAddresses {
            let stripped = Self.strippedAddress(address)
            if let existing = mergedHosts[hostID] {
                if existing.address == stripped, existing.deletedAt == nil {
                    ownHosts[hostID] = existing
                    continue
                }
                // Changed locally (a re-pair) or reinstating a
                // tombstone: a NEW edit, stamped and merged by the
                // same rule as every other field.
                let candidate = HostRecord(
                    address: stripped, modifiedAt: now(), deviceID: deviceID, deletedAt: nil
                )
                if existing.deletedAt != nil || Self.wins(
                    (candidate.modifiedAt, candidate.deviceID),
                    over: (existing.modifiedAt, existing.deviceID)
                ) {
                    mergedHosts[hostID] = candidate
                }
                ownHosts[hostID] = mergedHosts[hostID] ?? candidate
            } else {
                let candidate = HostRecord(
                    address: stripped, modifiedAt: now(), deviceID: deviceID, deletedAt: nil
                )
                mergedHosts[hostID] = candidate
                ownHosts[hostID] = candidate
            }
        }
        // A host THIS device previously recorded and no longer has
        // becomes a tombstone — the deletion stays recorded so a slower
        // device's stale upload cannot resurrect it. Measured against
        // this device's own previous set (`mirror.hosts`), so a
        // cloud-only record from another device is never tombstoned
        // here. Snapshot keys first — mutating while iterating a live
        // key view is undefined.
        for hostID in Array(mirror.hosts.keys) {
            guard !hostAddresses.keys.contains(hostID),
                  mergedHosts[hostID]?.deletedAt == nil
            else { continue }
            let stamp = now()
            mergedHosts[hostID]?.deletedAt = stamp
            mergedHosts[hostID]?.deviceID = deviceID
            mergedHosts[hostID]?.modifiedAt = stamp
        }

        report.syncedHostCount = mergedHosts.values.filter { $0.deletedAt == nil }.count
        report.pendingCandidates = mergedHosts
            .filter { $0.value.deletedAt == nil && !hostAddresses.keys.contains($0.key) }
            .map { $0.value.address }
            .sorted()

        let merged = Snapshot(schemaVersion: 1, appearance: mergedAppearance, hosts: mergedHosts)

        // --- Push, only when the payload changed.
        if merged != cloud,
           let payload = (try? JSONEncoder().encode(merged)).flatMap({ String(data: $0, encoding: .utf8) }) {
            store.set(payload, forKey: Self.key)
            if store.string(forKey: Self.key) != payload {
                // The store refused the payload (size limit): local
                // state stays authoritative for this pass and the
                // failure is reported — never silently dropped.
                status = .error("iCloud did not accept the update (limit reached). Local settings are intact.")
                lastReport = report
                localMirror = LocalMirror(appearance: mergedAppearance, hosts: ownHosts)
                return report
            }
        }
        localMirror = LocalMirror(appearance: mergedAppearance, hosts: ownHosts)
        status = .upToDate
        lastReport = report
        return report
    }

    /// The confirmed S19 action: removes the cloud record AND the
    /// local mirror — tombstones included (docs I6: tombstones live
    /// "until explicitly clearing synced settings"). Local settings
    /// and hosts are untouched.
    func clearSyncedSettings() {
        store.removeValue(forKey: Self.key)
        defaults.removeObject(forKey: Self.mirrorKey)
        status = .off
        lastReport = SyncReport()
    }

    /// The OS reported the store changed underneath us — most often
    /// the quota reason (docs I6). Local edits are kept and the
    /// failure is reported; every other change converges on the next
    /// pull, since the records are versioned.
    func noteQuotaFailure() {
        status = .error("iCloud hit its settings-sync limit. Local settings are intact; the next sync retries.")
    }

    /// One app-lifetime subscription to the store's external-change
    /// notification — the real path by which Apple's quota failure
    /// reaches this engine (KVS writes never throw).
    func observeExternalChanges() {
        guard observers.isEmpty else { return }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
                    Task { @MainActor in self?.noteQuotaFailure() }
                }
            }
        )
    }
}
