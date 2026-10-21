import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeStorage

final class HostStoreTests: XCTestCase {
    private var store: HostStore!

    override func setUpWithError() throws {
        store = try HostStore(inMemory: ())
    }

    private func host(
        id: String,
        name: String = "demo",
        address: String = "https://host.example:4096",
        created: Date = Date(timeIntervalSince1970: 1_700_000_000),
        version: String? = nil
    ) throws -> OpenCodeDomain.Host {
        OpenCodeDomain.Host(
            id: HostID(rawValue: id),
            displayName: name,
            address: try XCTUnwrap(URL(string: address)),
            createdAt: created,
            lastVersion: version
        )
    }

    func testUpsertAndFetchRoundTripsAllFields() throws {
        let original = try host(id: "H-1", name: "Lab", version: "2.0.25")
        try store.upsert(original)
        let fetched = try XCTUnwrap(store.host(id: original.id))
        XCTAssertEqual(fetched, original)
    }

    func testHostsAreOrderedByPairingTime() throws {
        try store.upsert(try host(id: "H-2", created: Date(timeIntervalSince1970: 200)))
        try store.upsert(try host(id: "H-1", created: Date(timeIntervalSince1970: 100)))
        XCTAssertEqual(try store.hosts().map(\.id.rawValue), ["H-1", "H-2"])
    }

    func testUpsertReplacesExistingRowWithSameID() throws {
        try store.upsert(try host(id: "H-1", name: "Old"))
        try store.upsert(try host(id: "H-1", name: "New", version: "2.1.0"))
        let hosts = try store.hosts()
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.displayName, "New")
        XCTAssertEqual(hosts.first?.lastVersion, "2.1.0")
    }

    func testFileBackedStoreWaitsForTheLockInsteadOfFailingImmediately() {
        // The file-backed HostStore relies on GRDB's default busyMode
        // (.immediateError): callers swallow SQLITE_BUSY into silently
        // missing hosts, so wait briefly for the lock instead.
        guard case .timeout(let seconds) = SharedDatabase.configuration.busyMode else {
            return XCTFail("shared stores must wait briefly for the lock, not fail on contention")
        }
        XCTAssertEqual(seconds, 5)
    }

    func testDeleteHostRemovesOnlyThatRow() throws {
        try store.upsert(try host(id: "H-1"))
        try store.upsert(try host(id: "H-2"))
        try store.deleteHost(id: HostID(rawValue: "H-1"))
        XCTAssertEqual(try store.hosts().map(\.id.rawValue), ["H-2"])
        XCTAssertNil(try store.host(id: HostID(rawValue: "H-1")))
    }
}
