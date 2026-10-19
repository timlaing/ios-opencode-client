import Foundation

/// W15 MCP runtime controls (docs/api-contract.md W14/W15,
/// docs/navigation-screens.md S16): the location-scoped runtime MCP
/// inventory and the per-server Connect/Disconnect runtime controls.
/// These builders NEVER edit configuration — persistent MCP
/// add/remove/authentication are later scope (contracts/mobile-scope
/// W18) — and every route here declares the baseline's optional
/// deep-object `location` query.
public enum W15Requests {
    /// `GET /api/mcp` — the RUNTIME MCP inventory, location-wrapped
    /// like every inventory route. `directory` scopes it; the caller
    /// compares the answer's `location` against what it asked for,
    /// exactly as with `/api/plugin` (api-contract.md W14's location
    /// equality rule).
    public static func mcpList(
        directory: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "mcp.list",
            method: .get,
            path: "/api/mcp",
            query: directory.map { [QueryPair(key: "location[directory]", value: $0)] } ?? [],
            credential: credential
        )
    }

    /// `POST /api/experimental/mcp/{server}/connect` → 204 — asks the
    /// host to connect this server for the RUNTIME. It never writes a
    /// persisted enabled flag, and 204 is ADMISSION: only the
    /// refetched inventory decides which status is shown
    /// (api-contract.md W15). The server NAME is a config key that
    /// may contain `/`, `?`, `%` or spaces, so it is pre-encoded as
    /// ONE path component here — the transport's per-segment encoder
    /// preserves those escapes, so the name can never become extra
    /// path structure (api-contract.md Line 14: every path component
    /// percent-encoded on its own, exactly once).
    public static func mcpConnect(
        server: String,
        directory: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "experimental.mcp.connect",
            method: .post,
            path: "/api/experimental/mcp/\(PercentCoding.encode(server))/connect",
            query: directory.map { [QueryPair(key: "location[directory]", value: $0)] } ?? [],
            credential: credential
        )
    }

    /// `POST /api/experimental/mcp/{server}/disconnect` → 204 — the
    /// runtime counterpart of `mcpConnect` (same admission rule:
    /// refetch the inventory for the shown status; same one-segment
    /// encoding of the server name).
    public static func mcpDisconnect(
        server: String,
        directory: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "experimental.mcp.disconnect",
            method: .post,
            path: "/api/experimental/mcp/\(PercentCoding.encode(server))/disconnect",
            query: directory.map { [QueryPair(key: "location[directory]", value: $0)] } ?? [],
            credential: credential
        )
    }
}

/// One runtime MCP server (`Mcp.Server`): just the name, the runtime
/// status and (when the host reports one) its integration identity —
/// there is deliberately NO persisted-enabled field, because the
/// baseline exposes runtime controls only (api-contract.md W15).
public struct McpServer: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var status: McpStatus
    public var integrationID: String?

    /// Display identity: the server name (unique within one
    /// inventory answer).
    public var id: String { name }

    public init(name: String, status: McpStatus, integrationID: String? = nil) {
        self.name = name
        self.status = status
        self.integrationID = integrationID
    }
}

/// `Mcp.Status.*` — an OBJECT discriminant (`{status:"connected"}`);
/// `failed` and `needs_auth` also carry the host's `error`. The
/// pinned schema enumerates five kinds, but clients pair with
/// SELF-HOSTED hosts that may run NEWER than the baseline: one
/// unknown status must not fail the decode and hide the whole MCP
/// list, so the kind keeps its raw string (the transport's convention
/// for DECODED strings hosts may evolve — `FileDiff.Status`,
/// `ModelInfo.status`); the known vocabulary stays addressable as
/// `Kind` and `isKnown`.
public struct McpStatus: Codable, Equatable, Sendable {
    /// The wire's discriminant, verbatim — unknown kinds included.
    public var rawKind: String
    /// The host's explanation for `failed`/`needs_auth` (required
    /// there by the pinned schema; kept whenever sent).
    public var error: String?

    public init(rawKind: String, error: String? = nil) {
        self.rawKind = rawKind
        self.error = error
    }

    /// The pinned five (docs/api-contract.md W15).
    public enum Kind: String, Sendable, Equatable {
        case connected
        case pending
        case disabled
        case failed
        case needsAuth = "needs_auth"
    }

    public var kind: Kind? { Kind(rawValue: rawKind) }

    /// Whether the value is one of the pinned five — consumers show
    /// unknown raw kinds verbatim rather than guessing a label.
    public var isKnown: Bool { kind != nil }

    private enum CodingKeys: String, CodingKey {
        case status
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawKind = try container.decode(String.self, forKey: .status)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawKind, forKey: .status)
        try container.encodeIfPresent(error, forKey: .error)
    }
}
