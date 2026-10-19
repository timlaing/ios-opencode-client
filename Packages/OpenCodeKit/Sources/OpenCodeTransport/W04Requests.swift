import Foundation

/// One `Session.Message.Info` from the pinned baseline. The wire format is
/// a TYPE UNION discriminated by `type` — never a V1 role/parts object
/// (docs/api-contract.md W03/W04). Variants the app does not know decode
/// as `.unknown` with their full raw payload retained.
public struct SessionMessage: Codable, Equatable, Sendable, Identifiable {
    /// Millisecond server epochs; only `created` is required by the schema.
    public struct TimeInfo: Codable, Equatable, Sendable {
        public var created: Int64
        public var streamed: Int64?
        public var completed: Int64?

        public init(created: Int64, streamed: Int64? = nil, completed: Int64? = nil) {
            self.created = created
            self.streamed = streamed
            self.completed = completed
        }
    }

    /// `Session.StructuredError`, decoded loosely — name/message/data.
    public struct StructuredError: Codable, Equatable, Sendable {
        public var name: String?
        public var message: String?
        public var data: JSONValue?

        public init(name: String? = nil, message: String? = nil, data: JSONValue? = nil) {
            self.name = name
            self.message = message
            self.data = data
        }
    }

    /// `Prompt.FileAttachment`: data is base64 — chips render name/mime
    /// only, never the inline bytes.
    public struct Attachment: Codable, Equatable, Sendable {
        public var data: String
        public var mime: String
        public var name: String?
        public var description: String?

        public init(data: String, mime: String, name: String? = nil, description: String? = nil) {
            self.data = data
            self.mime = mime
            self.name = name
            self.description = description
        }
    }

    /// `Tool.Content`: text or file reference (file keeps uri/mime/name).
    public struct ToolContent: Codable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case text(String)
            case file(uri: String, mime: String, name: String?)
            case unknown(type: String, raw: [String: JSONValue])
        }

        public var kind: Kind

        public init(kind: Kind) {
            self.kind = kind
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                kind = .text(try container.decode(String.self, forKey: .text))
            case "file":
                kind = .file(
                    uri: try container.decode(String.self, forKey: .uri),
                    mime: try container.decode(String.self, forKey: .mime),
                    name: try container.decodeIfPresent(String.self, forKey: .name)
                )
            default:
                kind = .unknown(type: type, raw: try [String: JSONValue](from: decoder))
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch kind {
            case .text(let text):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .file(let uri, let mime, let name):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("file", forKey: .type)
                try container.encode(uri, forKey: .uri)
                try container.encode(mime, forKey: .mime)
                try container.encodeIfPresent(name, forKey: .name)
            case .unknown(_, let raw):
                try raw.encode(to: encoder)
            }
        }

        enum CodingKeys: String, CodingKey { case type, text, uri, mime, name }
    }

    /// Tool execution state — the schema's `ToolState.*` union, kept
    /// exhaustive for the pinned baseline with an honest unknown case.
    public enum ToolState: Equatable, Sendable {
        case streaming(input: String)
        case running(input: JSONValue?, metadata: JSONValue?)
        case completed(input: JSONValue?, content: [ToolContent])
        case error(input: JSONValue?, error: StructuredError, content: [ToolContent]?)
        case unknown(status: String, raw: [String: JSONValue])
    }

    /// One ordered assistant content item (`Text` | `Reasoning` | `Tool`).
    public struct ContentItem: Codable, Equatable, Sendable {
        public var type: String
        public var text: String?
        public var id: String?
        public var name: String?
        public var time: TimeInfo?
        public var state: ToolState?

        public init(type: String, text: String? = nil, id: String? = nil, name: String? = nil, time: TimeInfo? = nil, state: ToolState? = nil) {
            self.type = type
            self.text = text
            self.id = id
            self.name = name
            self.time = time
            self.state = state
        }

        enum CodingKeys: String, CodingKey { case type, text, id, name, time, state }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            time = try container.decodeIfPresent(TimeInfo.self, forKey: .time)
            state = try container.decodeIfPresent(ToolStateValue.self, forKey: .state)?.value
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(time, forKey: .time)
            try container.encodeIfPresent(state.map(ToolStateValue.init), forKey: .state)
        }
    }

    /// Wrapper decoding the ToolState union by its `status` discriminator.
    struct ToolStateValue: Codable, Equatable, Sendable {
        var value: ToolState

        init(_ value: ToolState) { self.value = value }

        enum CodingKeys: String, CodingKey { case status, input, content, error, metadata }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case "streaming":
                value = .streaming(input: try container.decodeIfPresent(String.self, forKey: .input) ?? "")
            case "running":
                value = .running(
                    input: try container.decodeIfPresent(JSONValue.self, forKey: .input),
                    metadata: try container.decodeIfPresent(JSONValue.self, forKey: .metadata)
                )
            case "completed":
                value = .completed(
                    input: try container.decodeIfPresent(JSONValue.self, forKey: .input),
                    content: try container.decodeIfPresent([ToolContent].self, forKey: .content) ?? []
                )
            case "error":
                value = .error(
                    input: try container.decodeIfPresent(JSONValue.self, forKey: .input),
                    error: try container.decode(StructuredError.self, forKey: .error),
                    content: try container.decodeIfPresent([ToolContent].self, forKey: .content)
                )
            default:
                value = .unknown(status: status, raw: try [String: JSONValue](from: decoder))
            }
        }

        func encode(to encoder: Encoder) throws {
            switch value {
            case .streaming(let input):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("streaming", forKey: .status)
                try container.encode(input, forKey: .input)
            case .running(let input, let metadata):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("running", forKey: .status)
                try container.encodeIfPresent(input, forKey: .input)
                try container.encodeIfPresent(metadata, forKey: .metadata)
            case .completed(let input, let content):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("completed", forKey: .status)
                try container.encodeIfPresent(input, forKey: .input)
                try container.encode(content, forKey: .content)
            case .error(let input, let error, let content):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("error", forKey: .status)
                try container.encodeIfPresent(input, forKey: .input)
                try container.encode(error, forKey: .error)
                try container.encodeIfPresent(content, forKey: .content)
            case .unknown(_, let raw):
                try raw.encode(to: encoder)
            }
        }
    }

    /// The per-variant payloads, decoded by the `type` discriminator.
    public enum Kind: Equatable, Sendable {
        case user(text: String, files: [Attachment])
        case assistant(agent: String, model: Session.ModelRef?, content: [ContentItem], error: StructuredError?, retryAttempt: Int?)
        case synthetic(text: String, description: String?)
        case system(text: String, description: String?)
        case skill(skill: String, name: String, text: String)
        case shell(shellID: String, command: String, status: String, exit: Int?, output: String?)
        case agentSwitched(agent: String, previous: String?)
        case modelSwitched(model: Session.ModelRef?, previous: Session.ModelRef?)
        case locationSwitched(projectID: String?, subpath: String?, directory: String?)
        case compaction(status: String, reason: String?, summary: String?, errorMessage: String?)
        case idle(outcome: String)
        case unknown(type: String, raw: [String: JSONValue])
    }

    public var id: String
    public var time: TimeInfo
    /// The wire `type` discriminator, always present per the pinned schema.
    public var rawType: String
    public var kind: Kind
    /// The message's REPORTED token usage (`Session.Message.Assistant`
    /// and `Session.Message.Compaction.*` carry it; other variants do
    /// not) — decoded at the envelope level so the `Kind` union stays
    /// untouched. This is a per-STEP figure: session-cumulative totals
    /// come from `Session.tokens` (`session.get`), and the client never
    /// extrapolates live context utilisation between reports
    /// (docs/api-contract.md W13).
    public var tokens: Session.TokenUsage?

    public init(
        id: String,
        time: TimeInfo,
        rawType: String,
        kind: Kind,
        tokens: Session.TokenUsage? = nil
    ) {
        self.id = id
        self.time = time
        self.rawType = rawType
        self.kind = kind
        self.tokens = tokens
    }

    enum CodingKeys: String, CodingKey { case id, time, type, tokens }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        time = try container.decode(TimeInfo.self, forKey: .time)
        let type = try container.decode(String.self, forKey: .type)
        rawType = type
        tokens = try container.decodeIfPresent(Session.TokenUsage.self, forKey: .tokens)
        switch type {
        case "user":
            let payload = try UserPayload(from: decoder)
            kind = .user(text: payload.text, files: payload.files ?? [])
        case "assistant":
            let payload = try AssistantPayload(from: decoder)
            kind = .assistant(
                agent: payload.agent,
                model: payload.model,
                content: payload.content ?? [],
                error: payload.error,
                retryAttempt: payload.retry?.attempt
            )
        case "synthetic":
            let payload = try TextPayload(from: decoder)
            kind = .synthetic(text: payload.text, description: payload.description)
        case "system":
            let payload = try TextPayload(from: decoder)
            kind = .system(text: payload.text, description: payload.description)
        case "skill":
            let payload = try SkillPayload(from: decoder)
            kind = .skill(skill: payload.skill, name: payload.name, text: payload.text)
        case "shell":
            let payload = try ShellPayload(from: decoder)
            kind = .shell(shellID: payload.shellID, command: payload.command, status: payload.status, exit: payload.exit, output: payload.output)
        case "agent-switched":
            let payload = try AgentSwitchPayload(from: decoder)
            kind = .agentSwitched(agent: payload.agent, previous: payload.previous)
        case "model-switched":
            let payload = try ModelSwitchPayload(from: decoder)
            kind = .modelSwitched(model: payload.model, previous: payload.previous)
        case "location-switched":
            let payload = try LocationSwitchPayload(from: decoder)
            kind = .locationSwitched(projectID: payload.projectID, subpath: payload.subpath, directory: payload.location?.directory)
        case "compaction":
            let payload = try CompactionPayload(from: decoder)
            kind = .compaction(status: payload.status, reason: payload.reason, summary: payload.summary, errorMessage: payload.error?.message)
        case "idle":
            let payload = try IdlePayload(from: decoder)
            kind = .idle(outcome: payload.outcome)
        default:
            // Unknown variant: keep the FULL raw payload so nothing is
            // dropped — rendered as a hidden bookkeeping row, never a bubble.
            kind = .unknown(type: type, raw: try [String: JSONValue](from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .unknown(_, let raw) = kind {
            try raw.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(time, forKey: .time)
        try container.encode(rawType, forKey: .type)
        try container.encodeIfPresent(tokens, forKey: .tokens)
        switch kind {
        case .user(let text, let files):
            var payload = encoder.container(keyedBy: UserPayload.Keys.self)
            try payload.encode(text, forKey: .text)
            try payload.encodeIfPresent(files.isEmpty ? nil : files, forKey: .files)
        case .assistant(let agent, let model, let content, let error, let retryAttempt):
            var payload = encoder.container(keyedBy: AssistantPayload.Keys.self)
            try payload.encode(agent, forKey: .agent)
            try payload.encodeIfPresent(model, forKey: .model)
            try payload.encode(content, forKey: .content)
            try payload.encodeIfPresent(error, forKey: .error)
            try payload.encodeIfPresent(retryAttempt.map { RetryPayload(attempt: $0) }, forKey: .retry)
        case .synthetic(let text, let description), .system(let text, let description):
            var payload = encoder.container(keyedBy: TextPayload.Keys.self)
            try payload.encode(text, forKey: .text)
            try payload.encodeIfPresent(description, forKey: .description)
        case .skill(let skill, let name, let text):
            var payload = encoder.container(keyedBy: SkillPayload.Keys.self)
            try payload.encode(skill, forKey: .skill)
            try payload.encode(name, forKey: .name)
            try payload.encode(text, forKey: .text)
        case .shell(let shellID, let command, let status, let exit, let output):
            var payload = encoder.container(keyedBy: ShellPayload.Keys.self)
            try payload.encode(shellID, forKey: .shellID)
            try payload.encode(command, forKey: .command)
            try payload.encode(status, forKey: .status)
            try payload.encodeIfPresent(exit, forKey: .exit)
            try payload.encodeIfPresent(output, forKey: .output)
        case .agentSwitched(let agent, let previous):
            var payload = encoder.container(keyedBy: AgentSwitchPayload.Keys.self)
            try payload.encode(agent, forKey: .agent)
            try payload.encodeIfPresent(previous, forKey: .previous)
        case .modelSwitched(let model, let previous):
            var payload = encoder.container(keyedBy: ModelSwitchPayload.Keys.self)
            try payload.encodeIfPresent(model, forKey: .model)
            try payload.encodeIfPresent(previous, forKey: .previous)
        case .locationSwitched(let projectID, let subpath, let directory):
            var payload = encoder.container(keyedBy: LocationSwitchPayload.Keys.self)
            try payload.encodeIfPresent(projectID, forKey: .projectID)
            try payload.encodeIfPresent(subpath, forKey: .subpath)
            try payload.encodeIfPresent(directory.map { Session.LocationRef(directory: $0) }, forKey: .location)
        case .compaction(let status, let reason, let summary, let errorMessage):
            var payload = encoder.container(keyedBy: CompactionPayload.Keys.self)
            try payload.encode(status, forKey: .status)
            try payload.encodeIfPresent(reason, forKey: .reason)
            try payload.encodeIfPresent(summary, forKey: .summary)
            try payload.encodeIfPresent(errorMessage.map { StructuredError(message: $0) }, forKey: .error)
        case .idle(let outcome):
            var payload = encoder.container(keyedBy: IdlePayload.Keys.self)
            try payload.encode(outcome, forKey: .outcome)
        case .unknown:
            break // handled above
        }
    }

    // MARK: - Payload shapes (per-variant keys, tolerant decoding)

    struct UserPayload: Decodable {
        enum Keys: String, CodingKey { case text, files }
        var text: String
        var files: [Attachment]?
    }

    struct RetryPayload: Encodable {
        var attempt: Int
    }

    struct AssistantPayload: Decodable {
        enum Keys: String, CodingKey { case agent, model, content, error, retry }
        var agent: String
        var model: Session.ModelRef?
        var content: [ContentItem]?
        var error: StructuredError?
        var retry: RetryPayloadBox?
    }

    /// Box so the Decodable side decodes `{attempt, at, error}` loosely.
    struct RetryPayloadBox: Decodable {
        var attempt: Int
    }

    struct TextPayload: Decodable {
        enum Keys: String, CodingKey { case text, description }
        var text: String
        var description: String?
    }

    struct SkillPayload: Decodable {
        enum Keys: String, CodingKey { case skill, name, text }
        var skill: String
        var name: String
        var text: String
    }

    struct ShellPayload: Decodable {
        enum Keys: String, CodingKey { case shellID, command, status, exit, output }
        var shellID: String
        var command: String
        var status: String
        var exit: Int?
        var output: String?
    }

    struct AgentSwitchPayload: Decodable {
        enum Keys: String, CodingKey { case agent, previous }
        var agent: String
        var previous: String?
    }

    struct ModelSwitchPayload: Decodable {
        enum Keys: String, CodingKey { case model, previous }
        var model: Session.ModelRef?
        var previous: Session.ModelRef?
    }

    struct LocationSwitchPayload: Decodable {
        enum Keys: String, CodingKey { case projectID, subpath, location }
        var projectID: String?
        var subpath: String?
        var location: Session.LocationRef?
    }

    struct CompactionPayload: Decodable {
        enum Keys: String, CodingKey { case status, reason, summary, error }
        var status: String
        var reason: String?
        var summary: String?
        var error: StructuredError?
    }

    struct IdlePayload: Decodable {
        enum Keys: String, CodingKey { case outcome }
        var outcome: String
    }
}

/// `SessionMessagesResponse`: one history page plus opaque cursor.
public struct MessageListResponse: Codable, Equatable, Sendable {
    public var data: [SessionMessage]
    public var cursor: SessionListResponse.Cursor?

    public init(data: [SessionMessage], cursor: SessionListResponse.Cursor? = nil) {
        self.data = data
        self.cursor = cursor
    }
}

/// `{data: Session.Message.Info}` envelope for single-message reads.
public struct MessageEnvelope: Codable, Equatable, Sendable {
    public var data: SessionMessage

    public init(data: SessionMessage) {
        self.data = data
    }
}

/// `session.context`: `{data:[messages after last compaction]}` — the
/// ACTIVE model context, distinct from the full paged transcript.
public struct ContextResponse: Codable, Equatable, Sendable {
    public var data: [SessionMessage]

    public init(data: [SessionMessage]) {
        self.data = data
    }
}

/// W04 request builders (docs/api-contract.md W04). Cursor and order are
/// never combined by callers — the contract forbids it for history paging.
public enum W04Requests {
    /// `GET /api/session/{sessionID}/message` — `limit` 1...200, first-page
    /// `order`, optional `type` filter (preserve it when paging), opaque
    /// `cursor`.
    public static func listMessages(
        sessionID: String,
        limit: Int? = nil,
        order: W03Requests.Order? = nil,
        type: String? = nil,
        cursor: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        var query: [QueryPair] = []
        func add(_ key: String, _ value: String?) {
            if let value { query.append(QueryPair(key: key, value: value)) }
        }
        add("limit", limit.map(String.init))
        add("order", order?.rawValue)
        add("type", type)
        add("cursor", cursor)
        return APIRequest(
            operationID: "session.message.list",
            method: .get,
            path: "/api/session/\(sessionID)/message",
            query: query,
            credential: credential
        )
    }

    /// `GET /api/session/{sessionID}/message/{messageID}`.
    public static func getMessage(
        sessionID: String,
        messageID: String,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "session.message.get",
            method: .get,
            path: "/api/session/\(sessionID)/message/\(messageID)",
            credential: credential
        )
    }

    /// `GET /api/session/{sessionID}/context` — messages after the last
    /// compaction (active context, not the transcript).
    public static func context(
        sessionID: String,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "session.context",
            method: .get,
            path: "/api/session/\(sessionID)/context",
            credential: credential
        )
    }
}
