import Foundation

/// W14 request shapes (docs/api-contract.md W14/W15,
/// contracts/mobile-scope.json W14): the plugin inventory, the ordered
/// configuration documents, and the location reload that follows a
/// config edit. `PATCH /api/experimental/config` accepts only
/// `{shell}` in this baseline and is NEVER used as a plugin/MCP patch
/// route — the plugin toggle edits the JSONC document itself through
/// `fs.read`/`experimental.fs.write` (W02 builders).
public enum W14Requests {
    /// `GET /api/plugin` — the RUNTIME plugin inventory, location-
    /// wrapped like every inventory route. `directory` scopes the
    /// inventory (`location[directory]`, optional per the baseline) so
    /// runtime facts are never combined with directives from a
    /// different location — the caller compares the answer's
    /// `location` against what it asked for. Absence from this list is
    /// NOT proof a plugin is disabled: declared directives and runtime
    /// sources must be combined (docs/api-contract.md W14).
    public static func pluginList(
        directory: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "plugin.list",
            method: .get,
            path: "/api/plugin",
            query: directory.map { [QueryPair(key: "location[directory]", value: $0)] } ?? [],
            credential: credential
        )
    }

    /// `GET /api/config` — ordered configuration entries, LOW to HIGH
    /// precedence. A BARE array, not a `{data}` envelope. `directory`
    /// scopes the query (`location[directory]`, declared by this
    /// route): without it the host answers its DEFAULT location,
    /// whose documents may not live under the session directory —
    /// leaving every session outside that location with no editable
    /// document while the inventory is scoped to the session.
    public static func configList(
        directory: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "config.get",
            method: .get,
            path: "/api/config",
            query: directory.map { [QueryPair(key: "location[directory]", value: $0)] } ?? [],
            credential: credential
        )
    }

    /// `POST /api/location/reload` → 204 — asks the host to re-read the
    /// location's configuration after a document edit. It is a
    /// location-level reload, NOT an unverified per-plugin endpoint.
    /// The baseline declares NO location parameter and NO request body
    /// for this route (api-contract.md Line 15 forbids sending one):
    /// the host scopes the reload itself, and the post-write readback
    /// — not this call — decides whether it reflected the session.
    public static func locationReload(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "location.reload",
            method: .post,
            path: "/api/location/reload",
            credential: credential
        )
    }
}

/// `Plugin.Info` — one runtime plugin. `id` is absent for some sources;
/// every union keeps unknown host values visible rather than dropping
/// the row (house rule: decoded enums tolerate unknown values).
public struct PluginInfo: Codable, Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable {
        case builtin
        case package(target: String, version: String?, outdated: Bool, updating: Bool)
        case local(path: String)
        case sdk
        /// A source outside this baseline's set — kept distinct so it
        /// is never presented as a known kind.
        case unknown(type: String)

        enum TypeKeys: String, CodingKey { case type, target, version, outdated, updating, path }
    }

    /// `server`/`tui`/`rpc` are enum-`true` booleans; absent means the
    /// host does not report the feature (never invented).
    public struct Features: Codable, Equatable, Sendable {
        public var server: Bool
        public var tui: Bool
        public var rpc: Bool

        public init(server: Bool = false, tui: Bool = false, rpc: Bool = false) {
            self.server = server
            self.tui = tui
            self.rpc = rpc
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            server = try container.decodeIfPresent(Bool.self, forKey: .server) ?? false
            tui = try container.decodeIfPresent(Bool.self, forKey: .tui) ?? false
            rpc = try container.decodeIfPresent(Bool.self, forKey: .rpc) ?? false
        }

        enum CodingKeys: String, CodingKey { case server, tui, rpc }
    }

    public enum State: Equatable, Sendable {
        case active
        case failed(error: String, ref: String?)
        /// A status outside `active`/`failed` — visible, never mapped
        /// onto a known state.
        case unknown(status: String)
    }

    public var id: String?
    public var source: Source
    public var features: Features
    public var state: State

    public init(id: String? = nil, source: Source, features: Features = Features(), state: State) {
        self.id = id
        self.source = source
        self.features = features
        self.state = state
    }

    enum CodingKeys: String, CodingKey { case id, source, features, state }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        features = try container.decodeIfPresent(Features.self, forKey: .features) ?? Features()

        let sourceContainer = try container.nestedContainer(keyedBy: Source.TypeKeys.self, forKey: .source)
        let sourceType = try sourceContainer.decode(String.self, forKey: .type)
        switch sourceType {
        case "builtin":
            source = .builtin
        case "package":
            source = .package(
                target: try sourceContainer.decode(String.self, forKey: .target),
                version: try sourceContainer.decodeIfPresent(String.self, forKey: .version),
                outdated: try sourceContainer.decodeIfPresent(Bool.self, forKey: .outdated) ?? false,
                updating: try sourceContainer.decodeIfPresent(Bool.self, forKey: .updating) ?? false
            )
        case "local":
            source = .local(path: try sourceContainer.decode(String.self, forKey: .path))
        case "sdk":
            source = .sdk
        default:
            source = .unknown(type: sourceType)
        }

        let stateContainer = try container.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
        let status = try stateContainer.decode(String.self, forKey: .status)
        switch status {
        case "active":
            state = .active
        case "failed":
            state = .failed(
                error: try stateContainer.decode(String.self, forKey: .error),
                ref: try stateContainer.decodeIfPresent(String.self, forKey: .ref)
            )
        default:
            state = .unknown(status: status)
        }
    }

    enum StateKeys: String, CodingKey { case status, error, ref }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(features, forKey: .features)

        var sourceContainer = container.nestedContainer(keyedBy: Source.TypeKeys.self, forKey: .source)
        switch source {
        case .builtin:
            try sourceContainer.encode("builtin", forKey: .type)
        case .package(let target, let version, let outdated, let updating):
            try sourceContainer.encode("package", forKey: .type)
            try sourceContainer.encode(target, forKey: .target)
            try sourceContainer.encodeIfPresent(version, forKey: .version)
            if outdated { try sourceContainer.encode(true, forKey: .outdated) }
            if updating { try sourceContainer.encode(true, forKey: .updating) }
        case .local(let path):
            try sourceContainer.encode("local", forKey: .type)
            try sourceContainer.encode(path, forKey: .path)
        case .sdk:
            try sourceContainer.encode("sdk", forKey: .type)
        case .unknown(let type):
            try sourceContainer.encode(type, forKey: .type)
        }

        var stateContainer = container.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
        switch state {
        case .active:
            try stateContainer.encode("active", forKey: .status)
        case .failed(let error, let ref):
            try stateContainer.encode("failed", forKey: .status)
            try stateContainer.encode(error, forKey: .error)
            try stateContainer.encodeIfPresent(ref, forKey: .ref)
        case .unknown(let status):
            try stateContainer.encode(status, forKey: .status)
        }
    }
}

/// `Config.Entry` — one ordered configuration source, LOW to HIGH
/// precedence. Documents keep their parsed `info` lossless as
/// `JSONValue`: the app reads the `plugins` directives from the RAW
/// document bytes (fs.read), never from this re-serialisation.
public enum ConfigEntry: Codable, Equatable, Sendable {
    case document(path: String?, info: JSONValue)
    case directory(path: String)
    /// An entry outside this baseline's set — kept visible.
    case unknown(raw: JSONValue)

    enum CodingKeys: String, CodingKey { case type, path, info }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "document":
            self = .document(
                path: try container.decodeIfPresent(String.self, forKey: .path),
                info: try container.decodeIfPresent(JSONValue.self, forKey: .info) ?? .object([:])
            )
        case "directory":
            self = .directory(path: try container.decode(String.self, forKey: .path))
        default:
            self = .unknown(raw: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .document(let path, let info):
            try container.encode("document", forKey: .type)
            try container.encodeIfPresent(path, forKey: .path)
            try container.encode(info, forKey: .info)
        case .directory(let path):
            try container.encode("directory", forKey: .type)
            try container.encode(path, forKey: .path)
        case .unknown(let raw):
            try raw.encode(to: encoder)
        }
    }
}
