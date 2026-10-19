import XCTest
import OpenCodeStorage
import Security

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

    func testSaveUsesForegroundAccessibilityByDefault() throws {
        try store.save(secret: "token-fg", for: hostID)
        XCTAssertEqual(
            try storedAccessibility(),
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
            "foreground-only host credentials keep the docs' default class"
        )
    }

    func testEnableBackgroundAccessUpgradesClassWithoutTouchingTheSecret() throws {
        try store.save(secret: "token-bg", for: hostID)

        try store.enableBackgroundAccess(for: hostID)
        XCTAssertEqual(
            try storedAccessibility(),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "local-push-enabled hosts must be readable while the device is locked"
        )
        XCTAssertEqual(try store.secret(for: hostID), "token-bg", "the secret itself is untouched")

        try store.enableBackgroundAccess(for: hostID) // idempotent
        XCTAssertEqual(try storedAccessibility(), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testEnableBackgroundAccessWithoutCredentialIsANoOp() throws {
        XCTAssertNoThrow(try store.enableBackgroundAccess(for: hostID), "no item -> nothing to upgrade")
    }

    func testSaveWithBackgroundAccessibilityStoresTheClassDirectly() throws {
        try store.save(secret: "token-both", for: hostID, accessibility: .afterFirstUnlockThisDeviceOnly)
        XCTAssertEqual(try storedAccessibility(), kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(try store.secret(for: hostID), "token-both")
    }

    func testSaveUpdateKeepsTheUpgradedAccessibilityClass() throws {
        try store.save(secret: "token-1", for: hostID)
        try store.enableBackgroundAccess(for: hostID)

        // A re-pair rewrites the secret over the SAME item (HostID survives
        // re-pairing): the update path must not demote the class back to
        // foreground-only — the background extension would then fail
        // credential reads while the device is locked.
        try store.save(secret: "token-2", for: hostID)

        XCTAssertEqual(
            try storedAccessibility(),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "save's update path must never touch kSecAttrAccessible"
        )
        XCTAssertEqual(try store.secret(for: hostID), "token-2", "the new secret still lands")
    }

    private func storedAccessibility() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecAttrAccount as String: hostID,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
    }
}
