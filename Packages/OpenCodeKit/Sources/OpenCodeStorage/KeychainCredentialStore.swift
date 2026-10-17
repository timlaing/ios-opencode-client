import Foundation
import Security

/// Device-only Keychain storage for host credentials
/// (docs/implementation-defaults.md): `WhenUnlockedThisDeviceOnly`, never
/// iCloud-synced, never logged. Restoring to another device therefore requires
/// re-pairing, by design. The access group shared with the local-push
/// extension is added together with the app-push entitlement.
public struct KeychainCredentialStore: Sendable {
    public enum StoreError: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    public var service: String

    public init(service: String = "uk.co.laingcorp.opencode-client.host-credentials") {
        self.service = service
    }

    public func save(secret: String, for hostID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            for (key, value) in attributes { add[key] = value }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.unexpectedStatus(addStatus) }
        } else {
            guard updateStatus == errSecSuccess else { throw StoreError.unexpectedStatus(updateStatus) }
        }
    }

    /// The stored secret, or nil when the host has no credential on this
    /// device (for example after restoring to new hardware — re-pair).
    public func secret(for hostID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw StoreError.unexpectedStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteSecret(for hostID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }
}
