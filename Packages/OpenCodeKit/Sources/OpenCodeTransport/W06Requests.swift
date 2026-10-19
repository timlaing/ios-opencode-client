import Foundation

/// `Model.Capabilities`: `input`/`output` are STRING ARRAYS of media
/// kinds (`"text"`, `"image"`, `"pdf"`, …). The picker maps these to UI
/// booleans explicitly (docs/api-contract.md W06) — the raw arrays are
/// never presented as if they were booleans.
public struct ModelCapabilities: Codable, Equatable, Sendable {
    public var tools: Bool
    public var input: [String]
    public var output: [String]

    public init(tools: Bool, input: [String], output: [String]) {
        self.tools = tools
        self.input = input
        self.output = output
    }
}

/// `Model.Variant` — variants exist for display/selection context; only
/// `id` is part of the picker's vocabulary (settings/headers/body are
/// server-side request plumbing and are not decoded here).
public struct ModelVariant: Codable, Equatable, Sendable, Identifiable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

/// `Model.Cost` — USD per million tokens. Missing pricing stays missing
/// (never invented); a `tier` marks context-tiered pricing when the
/// host reports it.
public struct ModelCost: Codable, Equatable, Sendable {
    public struct Tier: Codable, Equatable, Sendable {
        public var type: String
        public var size: Int

        public init(type: String, size: Int) {
            self.type = type
            self.size = size
        }
    }

    public struct Cache: Codable, Equatable, Sendable {
        public var read: Double
        public var write: Double

        public init(read: Double, write: Double) {
            self.read = read
            self.write = write
        }
    }

    public var tier: Tier?
    public var input: Double
    public var output: Double
    public var cache: Cache

    public init(tier: Tier? = nil, input: Double, output: Double, cache: Cache) {
        self.tier = tier
        self.input = input
        self.output = output
        self.cache = cache
    }
}

/// `Model.Info` (`GET /api/model`). `id` + `providerID` form the
/// selection identity (`Model.Ref`) — `modelID` is provider metadata and
/// is NEVER the selection field (docs/api-contract.md W06). `status` is
/// kept as a plain string so a host status outside the known enum stays
/// visible instead of failing the whole list. All schema-required fields
/// are non-optional; unknown JSON keys are ignored on decode.
public struct ModelInfo: Codable, Equatable, Sendable, Identifiable {
    public struct Time: Codable, Equatable, Sendable {
        public var released: Double

        public init(released: Double) {
            self.released = released
        }
    }

    /// `limit`: `context`/`output` are schema-required; `input` when the
    /// host reports it.
    public struct Limits: Codable, Equatable, Sendable {
        public var context: Int
        public var input: Int?
        public var output: Int

        public init(context: Int, input: Int? = nil, output: Int) {
            self.context = context
            self.input = input
            self.output = output
        }
    }

    public var id: String
    public var modelID: String
    public var providerID: String
    public var name: String
    public var capabilities: ModelCapabilities
    public var variants: [ModelVariant]
    public var time: Time
    public var cost: [ModelCost]
    /// `alpha` | `beta` | `deprecated` | `active`, plus anything else a
    /// host may send — unknowns stay visible, never a decode failure.
    public var status: String
    public var enabled: Bool
    public var limit: Limits

    public init(
        id: String, modelID: String, providerID: String, name: String,
        capabilities: ModelCapabilities, variants: [ModelVariant], time: Time,
        cost: [ModelCost], status: String, enabled: Bool, limit: Limits
    ) {
        self.id = id
        self.modelID = modelID
        self.providerID = providerID
        self.name = name
        self.capabilities = capabilities
        self.variants = variants
        self.time = time
        self.cost = cost
        self.status = status
        self.enabled = enabled
        self.limit = limit
    }
}

/// W06 model-facing helpers: the `Model.Ref` selection identity and the
/// explicit input-capability booleans the UI renders.
public extension ModelInfo {
    /// The `Model.Ref` for session selection — `{id, providerID,
    /// variant?}`, never a bare `modelID`.
    func selectionRef(variant: String? = nil) -> Session.ModelRef {
        Session.ModelRef(id: id, providerID: providerID, variant: variant)
    }

    var acceptsText: Bool { capabilities.input.contains("text") }
    var acceptsImages: Bool { capabilities.input.contains("image") }
    var acceptsPDFs: Bool { capabilities.input.contains("pdf") }
    var outputsText: Bool { capabilities.output.contains("text") }

    /// Whether the host currently offers this model for selection —
    /// disabled or deprecated models stay VISIBLE but unselectable so
    /// the picker never pretends they are available.
    var isSelectable: Bool { enabled && status != "deprecated" }
}

/// `Agent.Info` (`GET /api/agent`). The picker needs identity and
/// offerability; provider request plumbing (`request`, `system`,
/// `permissions`, …) is server-side and not rendered for S10, so it is
/// not decoded (unknown JSON keys are ignored).
public struct AgentInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    /// `subagent` | `primary` | `all`, plus anything else a host may
    /// send — kept as a string so unknown modes stay visible.
    public var mode: String
    public var hidden: Bool
    /// The agent's configured default model, when it reports one.
    public var model: Session.ModelRef?

    public init(
        id: String, name: String, description: String? = nil, mode: String,
        hidden: Bool, model: Session.ModelRef? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.mode = mode
        self.hidden = hidden
        self.model = model
    }

    /// Whether the agent is offered as the session's primary agent:
    /// visible agents except `subagent`-mode ones (subagents are W08
    /// attachments, not S10 selections). An UNKNOWN mode stays offered —
    /// the host authoritatively accepts or rejects the switch — instead
    /// of being silently dropped from the list.
    public var isOfferedAsPrimary: Bool { !hidden && mode != "subagent" }
}

/// Location-wrapped single value (`{location:{directory}, data:…}`) —
/// the envelope `model.list`, `model.default`, `agent.list` and
/// `agent.get` share (docs/api-contract.md W06).
public struct LocationEnvelope<T: Codable & Sendable>: Codable, Sendable {
    public struct LocationRef: Codable, Sendable, Equatable {
        public var directory: String

        public init(directory: String) {
            self.directory = directory
        }
    }

    public var location: LocationRef
    public var data: T

    public init(location: LocationRef, data: T) {
        self.location = location
        self.data = data
    }
}

extension LocationEnvelope: Equatable where T: Equatable {}

/// W06 request builders (docs/api-contract.md W06, S10): the model and
/// agent inventories plus the session switches that affect SUBSEQUENT
/// turns and answer 204.
public enum W06Requests {
    /// `GET /api/model` — location-wrapped model list.
    public static func listModels(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "model.list",
            method: .get,
            path: "/api/model",
            credential: credential
        )
    }

    /// `GET /api/model/default` — location-wrapped default when the
    /// host has one (503 means unavailable, mapped by the service).
    public static func defaultModel(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "model.default",
            method: .get,
            path: "/api/model/default",
            credential: credential
        )
    }

    /// `GET /api/agent` — location-wrapped agent list.
    public static func listAgents(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "agent.list",
            method: .get,
            path: "/api/agent",
            credential: credential
        )
    }

    /// `GET /api/agent/{agentID}` — one agent's detail (404 when the
    /// host does not expose it).
    public static func getAgent(agentID: String, credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "agent.get",
            method: .get,
            path: "/api/agent/\(agentID)",
            credential: credential
        )
    }

    /// `POST /api/session/{sessionID}/model` — `{model: Model.Ref}` →
    /// 204. The body carries `id`+`providerID`(+`variant`) only —
    /// never `modelID`.
    public static func switchModel(
        sessionID: String,
        model: Session.ModelRef,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        try APIRequest.jsonBody(
            operationID: "session.switchModel",
            method: .post,
            path: "/api/session/\(sessionID)/model",
            value: SwitchModelBody(model: model),
            credential: credential
        )
    }

    /// `POST /api/session/{sessionID}/agent` — `{agent: <id>}` → 204.
    public static func switchAgent(
        sessionID: String,
        agent: String,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        try APIRequest.jsonBody(
            operationID: "session.switchAgent",
            method: .post,
            path: "/api/session/\(sessionID)/agent",
            value: SwitchAgentBody(agent: agent),
            credential: credential
        )
    }

    struct SwitchModelBody: Encodable {
        var model: Session.ModelRef
    }

    struct SwitchAgentBody: Encodable {
        var agent: String
    }
}
