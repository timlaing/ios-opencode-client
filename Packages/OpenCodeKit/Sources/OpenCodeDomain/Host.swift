import Foundation

public struct HostID: Hashable, Codable, Sendable {
    public var rawValue: String

    public init(rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }
}

/// A paired OpenCode host. Credentials are never stored on the model; they live
/// in the Keychain only (docs/implementation-defaults.md privacy rules).
public struct Host: Identifiable, Hashable, Codable, Sendable {
    public var id: HostID
    public var displayName: String
    public var address: URL
    public var createdAt: Date

    public init(id: HostID = HostID(), displayName: String, address: URL, createdAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.createdAt = createdAt
    }

    /// Diagnostics-safe description: identifiers only, addresses redacted
    /// (docs/local-push-implementation.md §11).
    public var redactedDiagnosticsDescription: String {
        "host \(id.rawValue) (address redacted)"
    }
}
