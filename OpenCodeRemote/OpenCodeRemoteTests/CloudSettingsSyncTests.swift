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

        func string(forKey key: String) -> String? { storage[key] }
        func set(_ value: String, forKey key: String) {
            guard !failWrites else { return }
            storage[key] = value
        }
        func removeValue(forKey key: String) { storage.removeValue(forKey: key) }
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

        let report = makeSync().reconcile(
            settings: settings,
            hostAddresses: ["h1": "https://user:pw@example.com/path?q=1"]
        )

        let snapshot = sync_snapshot()
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.appearance?.value, .light)
        XCTAssertEqual(snapshot.hosts["h1"]?.address, "https://example.com/path", "userinfo and query stripped before acceptance")
        XCTAssertNil(snapshot.hosts["h1"]?.deletedAt)
        XCTAssertEqual(report.syncedHostCount, 1)
        XCTAssertEqual(sync_lastError(), nil)
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
        seed(CloudSettingsSync.Snapshot(appearance: .init(
            value: .dark,
            modifiedAt: Date(timeIntervalSince1970: 500_000),
            deviceID: "device-remote"
        )))
        let settings = makeSettings()
        settings.update {
            $0.icloudSyncRequested = true
            $0.appearance = .light
        }

        _ = makeSync().reconcile(settings: settings, hostAddresses: [:])

        XCTAssertEqual(settings.state.appearance, .light, "the local edit is newer — it stands")
        XCTAssertEqual(sync_snapshot().appearance?.value, .light, "and wins the merge into the cloud record")
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

        // A device whose copy is UNCHANGED never re-stamps: even when
        // it still has the host locally, the tombstone survives its
        // upload — a stale copy cannot resurrect a removed entry.
        clock.now = clock.now.addingTimeInterval(100)
        _ = sync.reconcile(settings: settings, hostAddresses: [:])
        let stillGone = try XCTUnwrap(sync_snapshot().hosts["h1"])
        XCTAssertNotNil(stillGone.deletedAt)
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

        XCTAssertNil(store.storage[CloudSettingsSync.key], "the cloud record is gone")
        XCTAssertNil(UserDefaults(suiteName: suiteName)!.data(forKey: CloudSettingsSync.mirrorKey), "the local mirror goes too")
        XCTAssertEqual(settings.state.appearance, .system, "clearing synced settings never touches local settings")
    }

    // MARK: - Helpers

    private func sync_snapshot() -> CloudSettingsSync.Snapshot {
        let raw = store.storage[CloudSettingsSync.key]!
        return try! JSONDecoder().decode(CloudSettingsSync.Snapshot.self, from: Data(raw.utf8))
    }

    private func sync_lastError() -> String? {
        if case .error(let message) = makeSync().status { return message }
        return nil
    }
}
