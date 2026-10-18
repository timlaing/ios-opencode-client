import Foundation

/// `Session.Info` for W03/W04 (docs/api-contract.md W03): id, project,
/// location, title, agent/model, cumulative cost/tokens, outcome and time
/// are modeled; unmodeled server fields (metadata, permissions, revert,
/// fork) decode as absent rather than being invented. `outcome` is the
/// pinned schema's enum (succeeded/failed/interrupted) but is kept a
/// String so an unexpected value still decodes — unknowns stay visible,
/// never silently dropped.
public struct Session: Codable, Equatable, Sendable, Identifiable {
    /// `Model.Ref`: `{id, providerID, variant?}` — never a bare `modelID`.
    public struct ModelRef: Codable, Equatable, Sendable {
        public var id: String
        public var providerID: String
        public var variant: String?

        public init(id: String, providerID: String, variant: String? = nil) {
            self.id = id
            self.providerID = providerID
            self.variant = variant
        }
    }

    public struct TokenUsage: Codable, Equatable, Sendable {
        public struct Cache: Codable, Equatable, Sendable {
            public var read: Int?
            public var write: Int?

            public init(read: Int? = nil, write: Int? = nil) {
                self.read = read
                self.write = write
            }
        }

        public var input: Int?
        public var output: Int?
        public var reasoning: Int?
        public var cache: Cache?

        public init(input: Int? = nil, output: Int? = nil, reasoning: Int? = nil, cache: Cache? = nil) {
            self.input = input
            self.output = output
            self.reasoning = reasoning
            self.cache = cache
        }
    }

    /// Server-side epochs in milliseconds. `idle`/`viewed`/`archived` are
    /// only present when the host supplies them.
    public struct TimeInfo: Codable, Equatable, Sendable {
        public var created: Int64?
        public var updated: Int64?
        public var idle: Int64?
        public var viewed: Int64?
        public var archived: Int64?

        public init(created: Int64? = nil, updated: Int64? = nil, idle: Int64? = nil, viewed: Int64? = nil, archived: Int64? = nil) {
            self.created = created
            self.updated = updated
            self.idle = idle
            self.viewed = viewed
            self.archived = archived
        }
    }

    public struct LocationRef: Codable, Equatable, Sendable {
        public var directory: String

        public init(directory: String) {
            self.directory = directory
        }
    }

    public var id: String
    public var parentID: String?
    public var projectID: String?
    public var title: String?
    public var agent: String?
    public var model: ModelRef?
    public var cost: Double?
    public var tokens: TokenUsage?
    public var time: TimeInfo?
    public var outcome: String?
    public var subpath: String?
    public var location: LocationRef?

    public init(
        id: String,
        parentID: String? = nil,
        projectID: String? = nil,
        title: String? = nil,
        agent: String? = nil,
        model: ModelRef? = nil,
        cost: Double? = nil,
        tokens: TokenUsage? = nil,
        time: TimeInfo? = nil,
        outcome: String? = nil,
        subpath: String? = nil,
        location: LocationRef? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.projectID = projectID
        self.title = title
        self.agent = agent
        self.model = model
        self.cost = cost
        self.tokens = tokens
        self.time = time
        self.outcome = outcome
        self.subpath = subpath
        self.location = location
    }

    /// Server-side unread: the host recorded a view and has updated since.
    /// Absent `viewed` means the client has never acknowledged this
    /// session — surfaced as unread, cleared by `session.view`.
    public var isUnread: Bool {
        guard let time else { return true }
        guard let viewed = time.viewed else { return true }
        guard let updated = time.updated else { return false }
        return updated > viewed
    }
}

/// `SessionsResponse`: data page plus opaque cursor. Cursor CONTENTS are
/// never decoded by the app — they are consumed as opaque strings
/// (docs/api-contract.md W03 pagination rules).
public struct SessionListResponse: Codable, Equatable, Sendable {
    public struct Cursor: Codable, Equatable, Sendable {
        public var previous: String?
        public var next: String?

        public init(previous: String? = nil, next: String? = nil) {
            self.previous = previous
            self.next = next
        }
    }

    public var data: [Session]
    public var cursor: Cursor?

    public init(data: [Session], cursor: Cursor? = nil) {
        self.data = data
        self.cursor = cursor
    }
}

/// `{data: Session.Info}` envelope for create/get.
public struct SessionEnvelope: Codable, Equatable, Sendable {
    public var data: Session

    public init(data: Session) {
        self.data = data
    }
}

/// `GET /api/session/active` → `{data: {[sessionID]: {type:"running"}}}`.
/// Absence means "not actively drained by this server process", not proof
/// of completion (docs/api-contract.md W03).
public struct ActiveSessionsResponse: Codable, Equatable, Sendable {
    public struct ActiveInfo: Codable, Equatable, Sendable {
        public var type: String

        public init(type: String) {
            self.type = type
        }
    }

    public var data: [String: ActiveInfo]

    public init(data: [String: ActiveInfo]) {
        self.data = data
    }
}

/// `POST /api/session` body: null-valued fields are omitted (synthesized
/// optionals encode with `encodeIfPresent`); no fields beyond the pinned
/// schema are invented.
public struct SessionCreateBody: Codable, Equatable, Sendable {
    public var id: String?
    public var title: String?
    public var agent: String?
    public var model: Session.ModelRef?
    public var location: Session.LocationRef?
    public var parentID: String?

    public init(
        id: String? = nil,
        title: String? = nil,
        agent: String? = nil,
        model: Session.ModelRef? = nil,
        location: Session.LocationRef? = nil,
        parentID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.model = model
        self.location = location
        self.parentID = parentID
    }
}

/// W03 request builders for session management (docs/api-contract.md
/// W03/W04). Filter scopes ride as individual query pairs; cursor values
/// are passed through opaquely.
public enum W03Requests {
    public enum Order: String, Sendable {
        case ascending = "asc"
        case descending = "desc"
    }

    /// `GET /api/session` — optional `directory`, `project`, `subpath`,
    /// `search` (server title search), `parentID`, `limit` 1..200, `order`,
    /// `cursor`. The contract forbids combining incompatible filter scopes
    /// — pass one of `directory`/`project` per call. The literal parentID
    /// value `"null"` selects root sessions.
    public static func listSessions(
        directory: String? = nil,
        project: String? = nil,
        subpath: String? = nil,
        search: String? = nil,
        parentID: String? = nil,
        limit: Int? = nil,
        order: Order? = nil,
        cursor: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        var query: [QueryPair] = []
        func add(_ key: String, _ value: String?) {
            if let value { query.append(QueryPair(key: key, value: value)) }
        }
        add("directory", directory)
        add("project", project)
        add("subpath", subpath)
        add("search", search)
        add("parentID", parentID)
        add("limit", limit.map(String.init))
        add("order", order?.rawValue)
        add("cursor", cursor)
        return APIRequest(
            operationID: "session.list",
            method: .get,
            path: "/api/session",
            query: query,
            credential: credential
        )
    }

    /// `POST /api/session` — creates the native session; `{location:{directory}}`
    /// binds it to a reviewed directory.
    public static func createSession(
        _ body: SessionCreateBody,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        try APIRequest.jsonBody(
            operationID: "session.create",
            method: .post,
            path: "/api/session",
            value: body,
            credential: credential
        )
    }

    /// `GET /api/session/{sessionID}` — full info with cumulative
    /// cost/tokens, outcome, time, location.
    public static func getSession(sessionID: String, credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "session.get",
            method: .get,
            path: "/api/session/\(sessionID)",
            credential: credential
        )
    }

    /// `PATCH /api/session/{sessionID}` — rename via `{title}` → 204.
    /// Metadata/permissions are patched only deliberately; this builder
    /// sends the title alone so unrelated fields are preserved.
    public static func updateSession(
        sessionID: String,
        title: String,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        struct TitlePatch: Encodable { let title: String }
        return try APIRequest.jsonBody(
            operationID: "session.update",
            method: .patch,
            path: "/api/session/\(sessionID)",
            value: TitlePatch(title: title),
            credential: credential
        )
    }

    /// `DELETE /api/session/{sessionID}` → 204; removal includes child
    /// sessions (docs/api-contract.md W03).
    public static func removeSession(sessionID: String, credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "session.remove",
            method: .delete,
            path: "/api/session/\(sessionID)",
            credential: credential
        )
    }

    /// `POST /api/session/{sessionID}/view` — `{idle:<observed-idle-epoch-ms>}`
    /// → 204. `idle` must be a server-observed epoch, never the phone's
    /// clock (docs/api-contract.md W03 unread state).
    public static func viewSession(
        sessionID: String,
        observedIdleEpoch: Int64,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        struct ViewBody: Encodable { let idle: Int64 }
        return try APIRequest.jsonBody(
            operationID: "session.view",
            method: .post,
            path: "/api/session/\(sessionID)/view",
            value: ViewBody(idle: observedIdleEpoch),
            credential: credential
        )
    }

    /// `GET /api/session/active` — sessions actively drained by this
    /// server process.
    public static func activeSessions(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "session.active",
            method: .get,
            path: "/api/session/active",
            credential: credential
        )
    }
}
