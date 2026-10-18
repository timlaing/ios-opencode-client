import Foundation
import OpenCodeTransport

/// W05 operations for a paired host (docs/api-contract.md W05,
/// docs/navigation-screens.md S08/S09): prompt admission, the connected-
/// session inbox, and interrupt.
///
/// `prompt` returns the durably ADMITTED inbox item — never a completed
/// answer. The app claims no exactly-once delivery: reconciliation after
/// a timeout/409 is by the STABLE message ID the app chose.
public struct PromptService: Sendable {
    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// Admits one text prompt. `messageID` should be the app's stable
    /// `msg_` ID so failures can be reconciled against the inbox instead
    /// of blindly retried.
    public func prompt(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        text: String,
        messageID: String? = nil,
        delivery: InboxDelivery? = nil
    ) async throws -> InboxItem {
        let body = PromptBody(id: messageID, text: text, delivery: delivery, resume: nil)
        return try await makeTransport(host)
            .perform(try W05Requests.prompt(sessionID: sessionID, body: body, credential: credential))
            .decodedJSON(InboxEnvelope.self)
            .data
    }

    /// Admitted work not yet delivered — the reconciliation source after
    /// an uncertain submission.
    public func inbox(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String
    ) async throws -> [InboxItem] {
        try await makeTransport(host)
            .perform(W05Requests.listInbox(sessionID: sessionID, credential: credential))
            .decodedJSON(InboxListResponse.self)
            .data
    }

    /// Changes a pending item's delivery (`steer`/`queue`) → 204.
    public func updateDelivery(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        inboxID: String,
        delivery: InboxDelivery
    ) async throws {
        _ = try await makeTransport(host)
            .perform(try W05Requests.updateInbox(
                sessionID: sessionID, inboxID: inboxID, delivery: delivery, credential: credential
            ))
    }

    /// Cancels a not-yet-delivered item → 204. An unavailable item is a
    /// server-side no-op — callers treat success as "verified gone" and
    /// re-read the inbox rather than assuming local removal.
    public func cancel(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        inboxID: String
    ) async throws {
        _ = try await makeTransport(host)
            .perform(W05Requests.cancelInbox(sessionID: sessionID, inboxID: inboxID, credential: credential))
    }

    /// Ordinary Stop (`interrupt?resume=false`) → whether an active
    /// execution owned by this server process was interrupted. `false`
    /// is an honest outcome, never an error.
    public func interrupt(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String
    ) async throws -> Bool {
        try await makeTransport(host)
            .perform(W05Requests.interrupt(sessionID: sessionID, resume: false, credential: credential))
            .decodedJSON(InterruptResponse.self)
            .interrupted
    }
}
