import Foundation
import OpenCodeTransport

/// W04 and W12 session operations for a paired host
/// (docs/api-contract.md W04/W12–W13, docs/navigation-screens.md
/// S08/S14/S15): the paged transcript, single messages, the active model
/// context (messages since the last compaction — distinct from the full
/// transcript), and per-turn change diffs.
///
/// History paging NEVER combines `cursor` and `order` — the contract
/// forbids it, so a cursor call drops `order` (the server keeps the
/// original sort).
public struct SessionHistoryService: Sendable {
    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// One page of messages. First pages pass `order` (mobile default:
    /// newest first, limit 50); cursor pages pass `cursor` only, keeping
    /// any `type` filter from the first page.
    public func messages(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        limit: Int = 50,
        order: W03Requests.Order = .descending,
        type: String? = nil,
        cursor: String? = nil
    ) async throws -> MessageListResponse {
        try await makeTransport(host)
            .perform(W04Requests.listMessages(
                sessionID: sessionID,
                limit: cursor == nil ? limit : nil,
                order: cursor == nil ? order : nil,
                type: type,
                cursor: cursor,
                credential: credential
            ))
            .decodedJSON(MessageListResponse.self)
    }

    /// One message by ID (`session.message.get`).
    public func message(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        messageID: String
    ) async throws -> SessionMessage {
        try await makeTransport(host)
            .perform(W04Requests.getMessage(
                sessionID: sessionID,
                messageID: messageID,
                credential: credential
            ))
            .decodedJSON(MessageEnvelope.self)
            .data
    }

    /// The ACTIVE model context — messages after the last compaction
    /// (`session.context`). Not the transcript and not paginated.
    public func context(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String
    ) async throws -> [SessionMessage] {
        try await makeTransport(host)
            .perform(W04Requests.context(sessionID: sessionID, credential: credential))
            .decodedJSON(ContextResponse.self)
            .data
    }

    /// W12 `session.diff` — the per-file changes a TURN (or turn range)
    /// produced. Omit `from` for the newest user turn, `to` for one turn
    /// alone, `context` for full-file patches. A turn runs from its first
    /// prompt after idle to the next idle; steering prompts belong to the
    /// same turn, and a range spanning a location change is rejected by
    /// the host (docs/api-contract.md W12/W13).
    public func diff(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        from: String? = nil,
        to: String? = nil,
        context: String? = nil
    ) async throws -> [FileDiff.Info] {
        try await makeTransport(host)
            .perform(W12Requests.sessionDiff(
                sessionID: sessionID,
                from: from,
                to: to,
                context: context,
                credential: credential
            ))
            .decodedJSON(SessionDiffResponse.self)
            .data
    }

    /// `GET /api/session/active` — the session IDs this server is
    /// actively draining RIGHT NOW. W16 reconnect reconciliation: the
    /// event stream has no replay, so a terminal that landed while the
    /// connection was down leaves the working indicator stale; the open
    /// session's ABSENCE from this inventory is the authoritative fact
    /// that its turn is over (docs/api-contract.md W16).
    public func activeSessions(
        at host: URL,
        credential: BasicCredential?
    ) async throws -> Set<String> {
        let envelope = try await makeTransport(host)
            .perform(W03Requests.activeSessions(credential: credential))
            .decodedJSON(ActiveSessionsResponse.self)
        return Set(envelope.data.keys)
    }
}
