import Foundation

/// `Permission.Source` — where a request came from (the baseline defines
/// exactly one kind: a tool call). `type` is a known-state string with a
/// helper, per the enum-ish convention (docs/api-contract.md W09);
/// `messageID` + `id` locate the tool within the transcript.
public struct PermissionSource: Codable, Equatable, Sendable {
    public var type: String
    public var messageID: String
    public var id: String

    public init(type: String = "tool", messageID: String, id: String) {
        self.type = type
        self.messageID = messageID
        self.id = id
    }

    /// The only source type this baseline defines.
    public var isTool: Bool { type == "tool" }
}

/// `Permission.Request` (S11): what the host asks before a tool runs.
/// Required: `id`/`sessionID`/`action`/`resources`. `save` is the host's
/// ACTUAL save scope — the only basis for an Always action, never
/// renamed “Allow everything”. `metadata` is a free-form object carried
/// as raw JSON; `source`/`message` add tool context and the ask text.
public struct PermissionRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var action: String
    public var resources: [String]
    public var save: [String]?
    public var metadata: [String: JSONValue]?
    public var source: PermissionSource?
    public var message: String?

    public init(
        id: String,
        sessionID: String,
        action: String,
        resources: [String],
        save: [String]? = nil,
        metadata: [String: JSONValue]? = nil,
        source: PermissionSource? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.action = action
        self.resources = resources
        self.save = save
        self.metadata = metadata
        self.source = source
        self.message = message
    }

    /// True when the host requested a meaningful save scope — the ONLY
    /// condition under which an Always action may be offered (S11).
    public var offersSaveScope: Bool { !(save ?? []).isEmpty }
}

/// `Permission.Reply`: the only accepted decisions; 204-authoritative —
/// never synthesised from local state (docs/api-contract.md W09).
public enum PermissionDecision: String, Codable, Equatable, Sendable {
    case once
    case always
    case reject
}

/// The reply body `{decision,message?}` — `message` is omitted when nil,
/// so a decision without an explanation is exactly `{"decision":"…"}`.
public struct PermissionReplyBody: Encodable, Equatable, Sendable {
    public var decision: PermissionDecision
    public var message: String?

    public init(decision: PermissionDecision, message: String? = nil) {
        self.decision = decision
        self.message = message
    }
}

/// `{data:[Permission.Request]}` — the payload BOTH list routes share:
/// the session-scoped list wraps it plainly, the location-wide route
/// adds `location`; a decoder of `data` alone reads both honestly.
public struct PermissionListResponse: Decodable, Equatable, Sendable {
    public var data: [PermissionRequest]
}

/// `{data:Permission.Request}` — single-request read before acting.
public struct PermissionDetailResponse: Decodable, Equatable, Sendable {
    public var data: PermissionRequest
}

/// W09 builders (docs/api-contract.md W09): reconcile with the
/// session-scoped or location-wide list, re-read one before acting, and
/// reply to the OWNER session's route — a linked child entry replies
/// under its actual `sessionID`, never the viewing session's.
public enum W09Requests {
    /// `GET /api/session/{sessionID}/permission` → `{data:[…]}`.
    public static func list(sessionID: String, credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "session.permission.list",
            method: .get,
            path: "/api/session/\(sessionID)/permission",
            credential: credential
        )
    }

    /// `GET /api/permission/request` → `{location:{directory},data:[…]}`:
    /// every pending request in the location, used to find child-session
    /// entries for linked attribution.
    public static func listAll(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "permission.request.list",
            method: .get,
            path: "/api/permission/request",
            credential: credential
        )
    }

    /// `GET /api/session/{sessionID}/permission/{requestID}` →
    /// `{data:{…}}` — the re-read before acting; a stale 404 means the
    /// request was answered elsewhere.
    public static func get(
        sessionID: String,
        requestID: String,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "session.permission.get",
            method: .get,
            path: "/api/session/\(sessionID)/permission/\(requestID)",
            credential: credential
        )
    }

    /// `POST /api/session/{sessionID}/permission/{requestID}/reply` with
    /// `{decision,message?}` → 204. 404 (`PermissionNotFoundError`) means
    /// no longer pending — never a local success.
    public static func reply(
        sessionID: String,
        requestID: String,
        decision: PermissionDecision,
        message: String? = nil,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        try APIRequest.jsonBody(
            operationID: "session.permission.reply",
            method: .post,
            path: "/api/session/\(sessionID)/permission/\(requestID)/reply",
            value: PermissionReplyBody(decision: decision, message: message),
            credential: credential
        )
    }
}
