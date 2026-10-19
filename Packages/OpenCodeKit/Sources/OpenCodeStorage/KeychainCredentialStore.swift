import Foundation
import Security

/// Device-only Keychain storage for host credentials
/// (docs/implementation-defaults.md): `ThisDeviceOnly`, never
/// iCloud-synced, never logged. Restoring to another device therefore requires
/// re-pairing, by design. Foreground-only host credentials default to
/// `WhenUnlockedThisDeviceOnly`; hosts with local-push/background access
/// enabled are upgraded via `enableBackgroundAccess` so the extension can
/// read them while the device is locked. The access group shared with the
/// local-push extension is added together with the app-push entitlement.
public struct KeychainCredentialStore: Sendable {
    public enum StoreError: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    /// The `ThisDeviceOnly` accessibility classes the implementation
    /// defaults permit for host credentials.
    public enum Accessibility: Sendable, Equatable {
        /// Foreground-only host credentials — the default.
        case whenUnlockedThisDeviceOnly
        /// Hosts with local-push/background-upload access enabled: the
        /// extension may start while the device is locked, where a
        /// `WhenUnlocked` item is unreadable (errSecInteractionNotAllowed).
        case afterFirstUnlockThisDeviceOnly

        var attribute: CFString {
            switch self {
            case .whenUnlockedThisDeviceOnly: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .afterFirstUnlockThisDeviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    public var service: String

    public init(service: String = "uk.co.laingcorp.opencode-client.host-credentials") {
        self.service = service
    }

    public func save(
        secret: String,
        for hostID: String,
        accessibility: Accessibility = .whenUnlockedThisDeviceOnly
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID,
        ]
        // kSecAttrAccessible is deliberately NOT in the UPDATE attributes:
        // save() writes the secret, never the class. The class is policy —
        // set at creation and upgraded by enableBackgroundAccess — and an
        // update forcing the default would silently DEMOTE an item the
        // upgrade raised to afterFirstUnlock (re-pair rewrites the secret
        // over the same item), costing the background extension credential
        // access until the next reconcile re-upgrades it.
        let attributes: [String: Any] = [
            kSecValueData as String: Data(secret.utf8),
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            for (key, value) in attributes { add[key] = value }
            add[kSecAttrAccessible as String] = accessibility.attribute
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.unexpectedStatus(addStatus) }
        } else {
            guard updateStatus == errSecSuccess else { throw StoreError.unexpectedStatus(updateStatus) }
        }
    }

    /// Upgrades an existing credential to `AfterFirstUnlockThisDeviceOnly`
    /// — the docs-mandated class once local-push/background access is
    /// enabled for the host — without touching the stored secret. A host
    /// with no credential yet is a no-op: pairing saves it later, and the
    /// enablement path re-runs on every reconcile.
    public func enableBackgroundAccess(for hostID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: Accessibility.afterFirstUnlockThisDeviceOnly.attribute,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw StoreError.unexpectedStatus(status) }
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
