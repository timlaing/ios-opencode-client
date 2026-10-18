import Foundation
import OpenCodeTransport

/// W03 operations for a paired host (docs/api-contract.md W03,
/// docs/navigation-screens.md S07): list/search, create, read, rename,
/// delete, unread acknowledgement and active-session probing. Cursors are
/// opaque pass-throughs; default mobile page size is 50, newest first.
public struct SessionService: Sendable {
    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// One page of sessions. `directory` and `project` are alternative
    /// scopes (never combined per contract); `search` is the server's
    /// TITLE search — never labelled transcript search.
    public func sessions(
        at host: URL,
        credential: BasicCredential?,
        directory: String? = nil,
        project: String? = nil,
        search: String? = nil,
        limit: Int = 50,
        order: W03Requests.Order = .descending,
        cursor: String? = nil
    ) async throws -> SessionListResponse {
        try await makeTransport(host)
            .perform(W03Requests.listSessions(
                directory: directory,
                project: project,
                search: search,
                limit: limit,
                order: order,
                cursor: cursor,
                credential: credential
            ))
            .decodedJSON(SessionListResponse.self)
    }

    /// Creates a native session bound to a reviewed directory.
    public func createSession(
        at host: URL,
        credential: BasicCredential?,
        directory: String,
        title: String? = nil
    ) async throws -> Session {
        let body = SessionCreateBody(
            title: title,
            location: Session.LocationRef(directory: directory)
        )
        return try await makeTransport(host)
            .perform(try W03Requests.createSession(body, credential: credential))
            .decodedJSON(SessionEnvelope.self)
            .data
    }

    /// Reads one session's full info (cumulative cost/tokens, outcome).
    public func session(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String
    ) async throws -> Session {
        try await makeTransport(host)
            .perform(W03Requests.getSession(sessionID: sessionID, credential: credential))
            .decodedJSON(SessionEnvelope.self)
            .data
    }

    /// Renames a session (`{title}` patch only → 204).
    public func rename(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        title: String
    ) async throws {
        _ = try await makeTransport(host)
            .perform(try W03Requests.updateSession(sessionID: sessionID, title: title, credential: credential))
    }

    /// Deletes a session and its children (server-side, 204). Success is
    /// only reported after the server confirms — an optimistic local
    /// removal alone never counts.
    public func remove(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String
    ) async throws {
        _ = try await makeTransport(host)
            .perform(W03Requests.removeSession(sessionID: sessionID, credential: credential))
    }

    /// Acknowledges unread state with a server-observed epoch (the last
    /// `time.updated` this client has seen) — never the phone clock.
    public func markViewed(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        observedIdleEpoch: Int64
    ) async throws {
        _ = try await makeTransport(host)
            .perform(try W03Requests.viewSession(
                sessionID: sessionID,
                observedIdleEpoch: observedIdleEpoch,
                credential: credential
            ))
    }

    /// Sessions this server process is actively draining. Absence means
    /// "not actively drained here", not proof of completion.
    public func activeSessionIDs(
        at host: URL,
        credential: BasicCredential?
    ) async throws -> Set<String> {
        let response = try await makeTransport(host)
            .perform(W03Requests.activeSessions(credential: credential))
            .decodedJSON(ActiveSessionsResponse.self)
        return Set(response.data.keys)
    }
}
