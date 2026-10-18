import Foundation

/// `PromptInput` — the session.prompt REQUEST body. `id` is the app's
/// STABLE client-chosen message ID (`msg_` pattern): after a timeout or
/// disconnect the app reconciles admission by searching the inbox and
/// transcript for it before ever offering a retry (docs/api-contract.md
/// W05). `files`/`agents`/`skills` are W08/W06 territory — the W05
/// composer sends text only.
public struct PromptBody: Codable, Equatable, Sendable {
    public var id: String?
    public var text: String
    public var delivery: InboxDelivery?
    public var resume: Bool?

    public init(id: String? = nil, text: String, delivery: InboxDelivery? = nil, resume: Bool? = nil) {
        self.id = id
        self.text = text
        self.delivery = delivery
        self.resume = resume
    }
}

/// `Session.Inbox.Delivery` — the only two native values; the default
/// follows the server.
public enum InboxDelivery: String, Codable, Equatable, Sendable {
    case steer
    case queue
}

/// One `Session.Inbox.Info` union member — admitted work not yet
/// delivered to the transcript, discriminated by `type`.
public struct InboxItem: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case user(text: String, files: [SessionMessage.Attachment], metadata: JSONValue?)
        case synthetic(text: String, description: String?)
        /// `CompactionPayload` is anyOf object|array — kept lossless.
        case compaction(payload: JSONValue)
        case move(projectID: String, subpath: String?, directory: String?)
    }

    public var id: String
    public var sessionID: String
    public var time: SessionMessage.TimeInfo
    public var rawType: String
    public var delivery: InboxDelivery
    public var kind: Kind

    public init(id: String, sessionID: String, time: SessionMessage.TimeInfo, rawType: String, delivery: InboxDelivery, kind: Kind) {
        self.id = id
        self.sessionID = sessionID
        self.time = time
        self.rawType = rawType
        self.delivery = delivery
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, sessionID, time, type, delivery, payload }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        time = try container.decode(SessionMessage.TimeInfo.self, forKey: .time)
        let type = try container.decode(String.self, forKey: .type)
        rawType = type
        delivery = try container.decode(InboxDelivery.self, forKey: .delivery)
        switch type {
        case "user":
            let payload = try container.decode(UserPayload.self, forKey: .payload)
            kind = .user(text: payload.text, files: payload.files ?? [], metadata: payload.metadata)
        case "synthetic":
            let payload = try container.decode(SyntheticPayload.self, forKey: .payload)
            kind = .synthetic(text: payload.text, description: payload.description)
        case "compaction":
            kind = .compaction(payload: try container.decode(JSONValue.self, forKey: .payload))
        case "move":
            let payload = try container.decode(MovePayload.self, forKey: .payload)
            kind = .move(projectID: payload.projectID, subpath: payload.subpath, directory: payload.location.directory)
        default:
            // Unknown inbox variant: keep its payload so the pending item
            // stays visible and cancellable instead of silently dropped.
            kind = .compaction(payload: try container.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(time, forKey: .time)
        try container.encode(rawType, forKey: .type)
        try container.encode(delivery, forKey: .delivery)
        switch kind {
        case .user(let text, let files, let metadata):
            try container.encode(
                UserPayload(text: text, files: files.isEmpty ? nil : files, metadata: metadata),
                forKey: .payload
            )
        case .synthetic(let text, let description):
            try container.encode(SyntheticPayload(text: text, description: description), forKey: .payload)
        case .compaction(let payload):
            try container.encode(payload, forKey: .payload)
        case .move(let projectID, let subpath, let directory):
            // `location` is schema-required; decoding enforces it, so only
            // a hand-built item could omit the directory.
            try container.encode(
                MovePayload(projectID: projectID, subpath: subpath, location: LocationRefValue(directory: directory ?? "")),
                forKey: .payload
            )
        }
    }

    /// Projects the admitted user item into the transcript's message
    /// shape — the SAME record once the server delivers it, so the later
    /// refresh dedupes by ID instead of double-rendering.
    public var projectedMessage: SessionMessage? {
        guard case .user(let text, let files, _) = kind else { return nil }
        return SessionMessage(id: id, time: time, rawType: "user", kind: .user(text: text, files: files))
    }

    struct UserPayload: Codable {
        var text: String
        var files: [SessionMessage.Attachment]?
        var metadata: JSONValue?
    }

    struct SyntheticPayload: Codable {
        var text: String
        var description: String?
    }

    struct MovePayload: Codable {
        var projectID: String
        var subpath: String?
        var location: LocationRefValue
    }
}

/// `Location.PublicRef` — `{directory}` for inbox moves.
struct LocationRefValue: Codable {
    var directory: String
}

/// `{data:Session.Inbox.User}` after durable admission — NOT a completed
/// assistant answer (docs/api-contract.md W05).
public struct InboxEnvelope: Codable, Equatable, Sendable {
    public var data: InboxItem

    public init(data: InboxItem) {
        self.data = data
    }
}

/// `GET /api/session/{sessionID}/inbox` — admitted work not yet
/// delivered (user, synthetic, compaction, move items).
public struct InboxListResponse: Codable, Equatable, Sendable {
    public var data: [InboxItem]

    public init(data: [InboxItem]) {
        self.data = data
    }
}

/// `SessionInterruptResponse` — `false` means no active execution owned
/// by the server process, NEVER a failed request.
public struct InterruptResponse: Codable, Equatable, Sendable {
    public var interrupted: Bool

    public init(interrupted: Bool) {
        self.interrupted = interrupted
    }
}

/// W05 request builders (docs/api-contract.md W05). The app never adds
/// an exactly-once guarantee: reconciliation is by stable message ID.
public enum W05Requests {
    /// `POST /api/session/{sessionID}/prompt` — returns the durably
    /// admitted `Session.Inbox.User`.
    public static func prompt(
        sessionID: String,
        body: PromptBody,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        try APIRequest.jsonBody(
            operationID: "session.prompt",
            method: .post,
            path: "/api/session/\(sessionID)/prompt",
            value: body,
            credential: credential
        )
    }

    /// `GET /api/session/{sessionID}/inbox`.
    public static func listInbox(sessionID: String, credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "session.inbox.list",
            method: .get,
            path: "/api/session/\(sessionID)/inbox",
            credential: credential
        )
    }

    /// `PATCH /api/session/{sessionID}/inbox/{inboxID}` — `{delivery}` →
    /// 204; cancelling first requires an available item (no-op otherwise).
    public static func updateInbox(
        sessionID: String,
        inboxID: String,
        delivery: InboxDelivery,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        struct DeliveryPatch: Encodable { let delivery: InboxDelivery }
        return try APIRequest.jsonBody(
            operationID: "session.inbox.update",
            method: .patch,
            path: "/api/session/\(sessionID)/inbox/\(inboxID)",
            value: DeliveryPatch(delivery: delivery),
            credential: credential
        )
    }

    /// `DELETE /api/session/{sessionID}/inbox/{inboxID}` → 204; an
    /// unavailable item is a no-op, not an error.
    public static func cancelInbox(
        sessionID: String,
        inboxID: String,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "session.inbox.cancel",
            method: .delete,
            path: "/api/session/\(sessionID)/inbox/\(inboxID)",
            credential: credential
        )
    }

    /// `POST /api/session/{sessionID}/interrupt?resume=false` — the
    /// ordinary Stop. `resume=true` is a specific steering control and is
    /// never wired to the ordinary Stop button.
    public static func interrupt(
        sessionID: String,
        resume: Bool = false,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "session.interrupt",
            method: .post,
            path: "/api/session/\(sessionID)/interrupt",
            query: [QueryPair(key: "resume", value: resume ? "true" : "false")],
            credential: credential
        )
    }
}
