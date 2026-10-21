import XCTest
import OpenCodeDomain
@testable import OpenCodeRemote

/// W17 I6: the opt-in gate, versioned records, the last-recorded-edit
/// merge with deterministic tie-break, address stripping, tombstones
/// that cannot resurrect, pending-candidate surfacing, and quota
/// failures that keep every local edit
/// (docs/implementation-defaults.md I6).
@MainActor
final class CloudSettingsSyncTests: XCTestCase {
    /// Dictionary-backed KVS. `failWrites` models Apple's quota: the
    /// set call "succeeds" but nothing is kept.
    private final class FakeStore: KeyValueStore, @unchecked Sendable {
        var storage: [String: String] = [:]
        var failWrites = false
        var synchronizeCalls = 0

        func string(forKey key: String) -> String? { storage[key] }
        func set(_ value: String, forKey key: String) {
            guard !failWrites else { return }
            storage[key] = value
        }
        func removeValue(forKey key: String) { storage.removeValue(forKey: key) }
        func synchronize() { synchronizeCalls += 1 }
    }

    /// Mutable clock, safe to hand to the @Sendable closure.
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date = Date(timeIntervalSince1970: 1_000_000)) { self.now = now }
    }

    private var suiteName: String!
    private var store: FakeStore!
    private var clock: Clock!

    override func setUp() {
        super.setUp()
        suiteName = "CloudSettingsSyncTests-\(UUID().uuidString)"
        store = FakeStore()
        clock = Clock()
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        store = nil
        clock = nil
        super.tearDown()
    }

    private func makeSync() -> CloudSettingsSync {
        CloudSettingsSync(
            store: store,
            defaults: UserDefaults(suiteName: suiteName)!,
            now: { [clock] in clock!.now }
        )
    }

    private func makeSettings() -> SettingsLibrary {
        SettingsLibrary(defaults: UserDefaults(suiteName: "\(suiteName).settings-\(UUID().uuidString)")!)
    }

    /// Seeds the fake KVS with a snapshot (encoding the way the
    /// engine does).
    private func seed(_ snapshot: CloudSettingsSync.Snapshot) {
        let data = try! JSONEncoder().encode(snapshot)
        store.storage[CloudSettingsSync.key] = String(data: data, encoding: .utf8)!
    }

    // MARK: - Pure rules

    func testWinsIsLaterTimestampThenDeterministicDeviceTieBreak() {
        let a = Date(timeIntervalSince1970: 100)
        let b = Date(timeIntervalSince1970: 200)

        XCTAssertTrue(CloudSettingsSync.wins((b, "device-1"), over: (a, "device-2")), "later edit wins")
        XCTAssertFalse(CloudSettingsSync.wins((a, "device-2"), over: (b, "device-1")))

        // Equal timestamps break by device ID in BOTH directions —
        // two devices converge instead of flip-flopping.
        XCTAssertTrue(CloudSettingsSync.wins((a, "device-2"), over: (a, "device-1")))
        XCTAssertFalse(CloudSettingsSync.wins((a, "device-1"), over: (a, "device-2")))
    }

    func testStrippedAddressDropsUserinfoQueryAndFragment() {
        XCTAssertEqual(
            CloudSettingsSync.strippedAddress("https://user:secret@example.com:4096/api?token=abc#frag"),
            "https://example.com:4096/api",
            "a synced record can never carry credentials or authorization-bearing parameters"
        )
        XCTAssertEqual(CloudSettingsSync.strippedAddress("https://plain.example.com"), "https://plain.example.com")
    }

    // MARK: - Opt-in gate

    func testOptOutNeverTouchesTheCloudStore() {
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = false }
        let sync = makeSync()

        let report = sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])

        XCTAssertTrue(store.storage.isEmpty, "iCloud off until opted in — nothing leaves the device")
        XCTAssertEqual(sync.status, .off)
        XCTAssertEqual(report, CloudSettingsSync.SyncReport())
        XCTAssertEqual(settings.state.appearance, .system, "opting out never rewrites local settings")
    }

    func testTurningSyncOffAfterwardsStopsApplyingCloudChanges() {
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }
        let sync = makeSync()
        sync.reconcile(settings: settings, hostAddresses: [:])

        // Another device later records a newer appearance…
        clock.now = clock.now.addingTimeInterval(1_000)
        var cloud = sync.snapshot()
        cloud.appearance = .init(value: .dark, modifiedAt: clock.now, deviceID: "device-remote")
        seed(cloud)

        // …but this device has turned sync off: local settings stay.
        settings.update { $0.icloudSyncRequested = false }
        sync.reconcile(settings: settings, hostAddresses: [:])

        XCTAssertEqual(settings.state.appearance, .system, "sync off keeps local settings and stops applying cloud changes")
    }

    // MARK: - Upload

    func testFirstReconcileUploadsStrippedAddressesAndAppearance() throws {
        let settings = makeSettings()
        settings.update {
            $0.icloudSyncRequested = true
            $0.appearance = .light
        }

        let sync = makeSync()
        let report = sync.reconcile(
            settings: settings,
            hostAddresses: ["h1": "https://user:pw@example.com/path?q=1"]
        )

        let snapshot = sync_snapshot()
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.appearance?.value, .light)
        XCTAssertEqual(snapshot.hosts["h1"]?.address, "https://example.com/path", "userinfo and query stripped before acceptance")
        XCTAssertNil(snapshot.hosts["h1"]?.deletedAt)
        XCTAssertEqual(report.syncedHostCount, 1)
        XCTAssertEqual(sync.status, .upToDate, "a successful reconcile leaves no error")
    }

    // MARK: - Download and merge

    func testNewerCloudAppearanceAppliesLocally() {
        seed(CloudSettingsSync.Snapshot(appearance: .init(
            value: .dark,
            modifiedAt: Date(timeIntervalSince1970: 2_000_000),
            deviceID: "device-remote"
        )))
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }

        let report = makeSync().reconcile(settings: settings, hostAddresses: [:])

        XCTAssertEqual(settings.state.appearance, .dark, "last recorded edit per field — the cloud's newer edit applies")
        XCTAssertTrue(report.appearanceApplied)
    }

    func testLocalAppearanceEditBeatsAnOlderCloudRecord() throws {
        let settings = makeSettings()
        settings.update {
            $0.icloudSyncRequested = true
            $0.appearance = .light
        }
        let sync = makeSync()

        // First pass: the cloud is empty, so this device's value is
        // RECORDED as its edit (the clock is pinned at 1_000_000).
        _ = sync.reconcile(settings: settings, hostAddresses: [:])
        XCTAssertEqual(sync_snapshot().appearance?.value, .light)

        // Second pass: the cloud carries an OLDER edit from another
        // device — a slower device's stale upload. This device's
        // recorded value has not changed, so it stands and wins.
        seed(CloudSettingsSync.Snapshot(appearance: .init(
            value: .dark,
            modifiedAt: Date(timeIntervalSince1970: 500_000),
            deviceID: "device-remote"
        )))
        let report = sync.reconcile(settings: settings, hostAddresses: [:])

        XCTAssertEqual(settings.state.appearance, .light, "the recorded local edit is newer — it stands")
        XCTAssertEqual(sync_snapshot().appearance?.value, .light, "and wins the merge into the cloud record")
        XCTAssertFalse(report.appearanceApplied, "the local value already is the winner — nothing was applied over it")
    }

    func testFreshOptInAdoptsTheCloudEditInsteadOfStampingItsDefault() throws {
        // Another device already chose .dark; THIS device has never
        // recorded an appearance (fresh install, untouched default).
        // An unrecorded value must never be stamped with now() — that
        // clock would beat the recorded edit on every other device
        // (review W17 r1).
        seed(CloudSettingsSync.Snapshot(appearance: .init(
            value: .dark,
            modifiedAt: Date(timeIntervalSince1970: 500_000),
            deviceID: "device-remote"
        )))
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }

        let report = makeSync().reconcile(settings: settings, hostAddresses: [:])

        XCTAssertEqual(settings.state.appearance, .dark, "the recorded cloud edit beats an unrecorded local default")
        XCTAssertTrue(report.appearanceApplied)
        let stored = try XCTUnwrap(sync_snapshot().appearance)
        XCTAssertEqual(stored.value, .dark)
        XCTAssertEqual(stored.deviceID, "device-remote", "adopted, never re-stamped with this device's clock")
        XCTAssertEqual(stored.modifiedAt, Date(timeIntervalSince1970: 500_000), "the original stamp survives")
    }

    func testPendingCandidatesAreSurfacedNotMerged() {
        seed(CloudSettingsSync.Snapshot(hosts: [
            "h2": .init(address: "https://b.example.com", modifiedAt: Date(timeIntervalSince1970: 900_000), deviceID: "device-remote", deletedAt: nil),
        ]))
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }

        let report = makeSync().reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])

        XCTAssertEqual(report.pendingCandidates, ["https://b.example.com"], "an address from another device is OFFERED, never silently merged")
        XCTAssertEqual(report.syncedHostCount, 2, "both live records ride in the synced list")
    }

    // MARK: - Tombstones

    func testRemovalBecomesATombstoneThatCannotResurrect() throws {
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }
        let sync = makeSync()

        sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])
        clock.now = clock.now.addingTimeInterval(100)
        let afterRemoval = sync.reconcile(settings: settings, hostAddresses: [:])

        XCTAssertEqual(afterRemoval.syncedHostCount, 0)
        let record = try XCTUnwrap(sync_snapshot().hosts["h1"])
        XCTAssertNotNil(record.deletedAt, "the deletion stays recorded (tombstone)")

        // A second ABSENCE pass never re-stamps the recorded
        // deletion: this device's mirror no longer holds the host, so
        // the recorded time stands. (The still-LOCAL case — an
        // unchanged stale copy — is pinned by
        // testAnUnchangedLocalCopyCannotResurrectATombstone.)
        clock.now = clock.now.addingTimeInterval(100)
        _ = sync.reconcile(settings: settings, hostAddresses: [:])
        let stillGone = try XCTUnwrap(sync_snapshot().hosts["h1"])
        XCTAssertNotNil(stillGone.deletedAt)
        XCTAssertEqual(stillGone.modifiedAt, record.modifiedAt, "no re-stamp — the recorded deletion time stands")
    }

    func testRepairedHostReinstatesItsTombstone() throws {
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }
        let sync = makeSync()

        sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])
        clock.now = clock.now.addingTimeInterval(100)
        _ = sync.reconcile(settings: settings, hostAddresses: [:])
        clock.now = clock.now.addingTimeInterval(100)
        let report = sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])

        let record = try XCTUnwrap(sync_snapshot().hosts["h1"])
        XCTAssertNil(record.deletedAt, "a real re-pair is a new edit — it reinstates the address")
        XCTAssertEqual(report.syncedHostCount, 1)
    }

    func testAnUnchangedLocalCopyCannotResurrectATombstone() throws {
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }
        let sync = makeSync()

        // This device records the host…
        sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])
        // …and then another device's removal arrives as a tombstone.
        var seeded = sync_snapshot()
        seeded.hosts["h1"] = CloudSettingsSync.HostRecord(
            address: "https://a.example.com",
            modifiedAt: Date(timeIntervalSince1970: 999_999),
            deviceID: "device-remote",
            deletedAt: Date(timeIntervalSince1970: 999_999)
        )
        seed(seeded)

        // The local copy is UNCHANGED — a stale copy must never
        // resurrect a removed entry (docs I6; review W17 r1).
        let report = sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])

        let record = try XCTUnwrap(sync_snapshot().hosts["h1"])
        XCTAssertNotNil(record.deletedAt, "an unchanged stale copy cannot resurrect a removed entry")
        XCTAssertEqual(record.modifiedAt, Date(timeIntervalSince1970: 999_999), "nothing was re-stamped")
        XCTAssertEqual(report.syncedHostCount, 0)
        XCTAssertEqual(sync.status, .upToDate, "the standing tombstone is not an error")
    }

    func testSameAddressUnderTwoDeviceLocalIDsIsNotOfferedBack() throws {
        // Device B paired the SAME address under its own device-local
        // UUID — the cloud holds two keys for one address, and this
        // device must never be offered what it already has (review
        // W17 r2).
        seed(CloudSettingsSync.Snapshot(hosts: [
            "remote-id": .init(
                address: "https://a.example.com",
                modifiedAt: Date(timeIntervalSince1970: 900_000),
                deviceID: "device-remote",
                deletedAt: nil
            ),
        ]))
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }

        let report = makeSync().reconcile(
            settings: settings,
            hostAddresses: ["local-id": "https://a.example.com"]
        )

        XCTAssertEqual(report.pendingCandidates, [], "an address this device already has is never offered back")
        XCTAssertEqual(report.syncedHostCount, 1, "one address is one host — never double-counted by key")
    }

    // MARK: - Quota and corruption

    func testQuotaRefusalKeepsLocalEditsAndTheNextRetrySucceeds() {
        let settings = makeSettings()
        settings.update {
            $0.icloudSyncRequested = true
            $0.appearance = .light
        }
        let sync = makeSync()
        store.failWrites = true

        sync.reconcile(settings: settings, hostAddresses: [:])

        XCTAssertEqual(settings.state.appearance, .light, "quota never loses local edits")
        guard case .error = sync.status else {
            return XCTFail("a refused write must surface an error status")
        }

        store.failWrites = false
        clock.now = clock.now.addingTimeInterval(100)
        sync.reconcile(settings: settings, hostAddresses: [:])
        XCTAssertEqual(sync.status, .upToDate, "the next pass retries the push")
    }

    func testQuotaRefusalKeepsTheTombstoneBasisForTheRetry() throws {
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }
        let sync = makeSync()

        // Pass 1 records h1 and is accepted.
        sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])
        XCTAssertNil(sync_snapshot().hosts["h1"]?.deletedAt, "pass 1 recorded h1 as live")

        // The removal's tombstone push is REFUSED — the mirror must
        // keep its basis so the next pass re-derives the tombstone
        // (review W17 r3).
        store.failWrites = true
        _ = sync.reconcile(settings: settings, hostAddresses: [:])
        guard case .error = sync.status else {
            return XCTFail("the refusal must surface as an error status")
        }

        // Once the quota frees, the retry re-derives and pushes.
        store.failWrites = false
        _ = sync.reconcile(settings: settings, hostAddresses: [:])

        let record = try XCTUnwrap(sync_snapshot().hosts["h1"])
        XCTAssertNotNil(record.deletedAt, "a refused write must never lose the removal — the cloud tombstones on retry")
    }

    func testUnreadableCloudPayloadIsNeverOverwritten() throws {
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }
        let sync = makeSync()

        // A corrupt record: reconcile refuses to write over it — the
        // other devices' records and tombstones live there (review
        // W17 r4).
        store.storage[CloudSettingsSync.key] = "not json at all"
        let report = sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])
        XCTAssertEqual(store.storage[CloudSettingsSync.key], "not json at all", "a corrupt record is never overwritten")
        guard case .error = sync.status else {
            return XCTFail("an unreadable payload surfaces as an error")
        }
        XCTAssertTrue(report.pendingCandidates.isEmpty, "nothing untrusted is ever offered")

        // A foreign (newer) schema is likewise never downgraded.
        let foreign = String(
            data: try JSONEncoder().encode(CloudSettingsSync.Snapshot(schemaVersion: 99)),
            encoding: .utf8
        )!
        store.storage[CloudSettingsSync.key] = foreign
        _ = sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])
        XCTAssertEqual(store.storage[CloudSettingsSync.key], foreign, "a newer-schema record is never downgraded")
        guard case .error = sync.status else {
            return XCTFail("a foreign schema surfaces as an error")
        }

        // Clear Synced Settings is the recovery: the next pass
        // starts fresh and converges.
        sync.clearSyncedSettings()
        sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])
        XCTAssertEqual(sync.status, .upToDate)
        XCTAssertEqual(sync_snapshot().hosts["h1"]?.address, "https://a.example.com", "the fresh pass pairs normally")
    }

    func testCorruptOrForeignSchemaSnapshotReadsAsEmpty() throws {
        store.storage[CloudSettingsSync.key] = "not json at all"
        let sync = makeSync()
        XCTAssertEqual(sync.snapshot(), CloudSettingsSync.Snapshot(), "a corrupt line never wedges sync")

        store.storage[CloudSettingsSync.key] = String(
            data: try JSONEncoder().encode(CloudSettingsSync.Snapshot(schemaVersion: 99)),
            encoding: .utf8
        )!
        XCTAssertEqual(sync.snapshot(), CloudSettingsSync.Snapshot(), "a future schema is not guessed at")
    }

    // MARK: - Clear

    func testClearSyncedSettingsRemovesCloudRecordsAndTombstones() throws {
        let settings = makeSettings()
        settings.update { $0.icloudSyncRequested = true }
        let sync = makeSync()
        sync.reconcile(settings: settings, hostAddresses: ["h1": "https://a.example.com"])
        clock.now = clock.now.addingTimeInterval(100)
        _ = sync.reconcile(settings: settings, hostAddresses: [:])
        XCTAssertNotNil(sync_snapshot().hosts["h1"]?.deletedAt)

        sync.clearSyncedSettings()

        XCTAssertEqual(
            sync.status, .upToDate,
            "clear leaves a consistent empty record — Off means NOT opted in, and the toggle stays on (review W17 r9)"
        )
        XCTAssertNil(store.storage[CloudSettingsSync.key], "the cloud record is gone")
        XCTAssertNil(UserDefaults(suiteName: suiteName)!.data(forKey: CloudSettingsSync.mirrorKey), "the local mirror goes too")
        XCTAssertEqual(settings.state.appearance, .system, "clearing synced settings never touches local settings")
    }

    // MARK: - External changes (review W17 r2)

    func testExternalServerChangeFiresTheReconcileHookAndSynchronizesOnce() async {
        let sync = makeSync()
        sync.observeExternalChanges()
        XCTAssertEqual(store.synchronizeCalls, 1, "one synchronize() per launch, as Apple recommends")

        let converged = expectation(description: "the shell's reconcile hook ran")
        sync.onExternalChange = { converged.fulfill() }
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreServerChange]
        )
        await fulfillment(of: [converged], timeout: 2)

        // The quota reason reports status and never asks the shell to
        // converge.
        let quotaNeverConverges = expectation(description: "quota must not fire the hook")
        quotaNeverConverges.isInverted = true
        sync.onExternalChange = { quotaNeverConverges.fulfill() }
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil,
            userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreQuotaViolationChange]
        )
        await fulfillment(of: [quotaNeverConverges], timeout: 1)
        guard case .error = sync.status else {
            return XCTFail("the quota reason must surface as an error status")
        }
    }

    // MARK: - Helpers

    private func sync_snapshot() -> CloudSettingsSync.Snapshot {
        let raw = store.storage[CloudSettingsSync.key]!
        return try! JSONDecoder().decode(CloudSettingsSync.Snapshot.self, from: Data(raw.utf8))
    }

}
