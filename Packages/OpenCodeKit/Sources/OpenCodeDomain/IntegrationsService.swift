import Foundation
import OpenCodeTransport

/// W14 operations for the S16 integrations inspector
/// (docs/api-contract.md W14/W15): the runtime plugin inventory, the
/// ordered configuration documents, the raw document bytes a plugin
/// toggle edits, and the location reload that makes the host re-read
/// them. Honesty rules: the runtime inventory and the declared
/// directives are SEPARATE facts — absence from `/api/plugin` is never
/// presented alone as "disabled" — and `location.reload` is a
/// location-level reload, never an unverified per-plugin endpoint.
public struct IntegrationsService: Sendable {
    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// `GET /api/plugin` — runtime inventory with the location the host
    /// actually answered under. `directory` scopes the query; the
    /// RETURNED directory is authoritative — combine it with
    /// directives from the same location only.
    public func plugins(
        at host: URL,
        credential: BasicCredential?,
        directory: String? = nil
    ) async throws -> (directory: String, plugins: [PluginInfo]) {
        let envelope = try await makeTransport(host)
            .perform(W14Requests.pluginList(directory: directory, credential: credential))
            .decodedJSON(LocationEnvelope<[PluginInfo]>.self)
        return (envelope.location.directory, envelope.data)
    }

    /// `GET /api/config` — ordered entries (bare array, LOW → HIGH
    /// precedence).
    public func configDocuments(
        at host: URL,
        credential: BasicCredential?
    ) async throws -> [ConfigEntry] {
        try await makeTransport(host)
            .perform(W14Requests.configList(credential: credential))
            .decodedJSON([ConfigEntry].self)
    }

    /// `POST /api/location/reload` → 204 — the host re-reads the
    /// location's configuration after a document edit.
    public func reload(at host: URL, credential: BasicCredential?) async throws {
        _ = try await makeTransport(host)
            .perform(W14Requests.locationReload(credential: credential))
    }

    /// `POST /api/experimental/fs/write` (W02 builder) — the edited
    /// document bytes. Callers MUST have read the file first
    /// (fs.write has no create-only mode; docs/implementation-defaults).
    public func writeFile(
        at host: URL,
        credential: BasicCredential?,
        directory: String,
        path: String,
        bytes: Data
    ) async throws {
        _ = try await makeTransport(host)
            .perform(W02Requests.writeFile(
                directory: directory, path: path, bytes: bytes, credential: credential
            ))
    }
}
