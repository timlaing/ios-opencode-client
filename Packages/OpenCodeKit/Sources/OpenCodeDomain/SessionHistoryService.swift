import Foundation
import OpenCodeTransport

/// W04 operations for a paired host (docs/api-contract.md W04,
/// docs/navigation-screens.md S08/S14): the paged transcript, single
/// messages, and the active model context (messages since the last
/// compaction — distinct from the full transcript).
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
}
