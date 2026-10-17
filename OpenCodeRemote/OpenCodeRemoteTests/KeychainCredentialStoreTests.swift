import XCTest
import OpenCodeStorage

/// Keychain round-trip on the simulator. Each test uses a unique service so
/// runs never collide with each other or with real app items.
final class KeychainCredentialStoreTests: XCTestCase {
    private var store: KeychainCredentialStore!
    private let hostID = "H-TEST-\(UUID().uuidString.prefix(8))"

    override func setUp() {
        super.setUp()
        store = KeychainCredentialStore(service: "tests.keychain.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? store.deleteSecret(for: hostID)
        store = nil
        super.tearDown()
    }

    func testSaveReadDeleteRoundTrip() throws {
        XCTAssertNil(try store.secret(for: hostID))

        try store.save(secret: "token-1", for: hostID)
        XCTAssertEqual(try store.secret(for: hostID), "token-1")

        // Saving again updates in place rather than duplicating.
        try store.save(secret: "token-2", for: hostID)
        XCTAssertEqual(try store.secret(for: hostID), "token-2")

        try store.deleteSecret(for: hostID)
        XCTAssertNil(try store.secret(for: hostID))

        // Deleting again is a no-op, not an error.
        XCTAssertNoThrow(try store.deleteSecret(for: hostID))
    }

    func testSecretsAreScopedByHostID() throws {
        try store.save(secret: "alpha", for: "H-A")
        try store.save(secret: "beta", for: "H-B")
        defer {
            try? store.deleteSecret(for: "H-A")
            try? store.deleteSecret(for: "H-B")
        }

        XCTAssertEqual(try store.secret(for: "H-A"), "alpha")
        XCTAssertEqual(try store.secret(for: "H-B"), "beta")
        XCTAssertNil(try store.secret(for: "H-C"))
    }
}
