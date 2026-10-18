import Foundation
import OpenCodeTransport

/// W10 forms (docs/api-contract.md W10, S12): reconcile pending forms
/// (session-scoped or location-wide), read one for its `state`, reply
/// 204-authoritatively, and cancel explicitly. The reply's failures are
/// DISTINCT: 404 is `notFound` — never a local success; 409 is
/// `alreadySettled` — re-read and show the authoritative settled state;
/// and a 400 carrying FormInvalidAnswerError is `invalidAnswer`, whose
/// host message goes beside the field. Any other 400 stays a plain
/// transport error — never dressed up as a validation answer.
public struct FormService: Sendable {
    public enum ServiceError: Error, Equatable, Sendable {
        /// 404 on get/reply/cancel: the form does not exist for this
        /// owner (answered elsewhere, cancelled, or superseded).
        case notFound(formID: String)
        /// 409 on reply: the form is no longer pending — the host's
        /// state is authoritative and the local input must not be
        /// claimed as submitted.
        case alreadySettled(formID: String)
        /// 400 FormInvalidAnswerError: the answer failed field
        /// validation; the host's message reports what to fix.
        case invalidAnswer(message: String)
    }

    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// `GET /api/session/{sessionID}/form` → this session's own pending
    /// forms (the list route never includes settled ones).
    public func list(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String
    ) async throws -> [FormInfo] {
        try await makeTransport(host)
            .perform(W10Requests.list(sessionID: sessionID, credential: credential))
            .decodedJSON(FormListResponse.self)
            .data
    }

    /// `GET /api/form` → every pending form in the location (located
    /// envelope — `location` is not part of the payload contract).
    /// Callers filter it down to sessions they can actually attribute
    /// (the current session + known descendants).
    public func listAll(at host: URL, credential: BasicCredential?) async throws -> [FormInfo] {
        try await makeTransport(host)
            .perform(W10Requests.listAll(credential: credential))
            .decodedJSON(FormListResponse.self)
            .data
    }

    /// `GET …/form/{formID}` — the detail (with `state`) the sheet
    /// renders, and the re-read after a 409. 404 → `notFound`.
    /// `sessionID` is the form's OWNER session, plain string as-is.
    public func get(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        formID: String
    ) async throws -> FormDetail {
        do {
            return try await makeTransport(host)
                .perform(W10Requests.get(
                    sessionID: sessionID, formID: formID, credential: credential
                ))
                .decodedJSON(FormDetailResponse.self)
                .data
        } catch TransportError.http(let status, _) where status == 404 {
            throw ServiceError.notFound(formID: formID)
        }
    }

    /// `POST …/reply` with `{answer}` → 204 (authoritative). `sessionID`
    /// is the form's OWNER session — linked child forms reply under
    /// their actual owner, never the viewing session.
    public func reply(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        formID: String,
        answer: [String: FormValue]
    ) async throws {
        do {
            _ = try await makeTransport(host).perform(try W10Requests.reply(
                sessionID: sessionID,
                formID: formID,
                answer: answer,
                credential: credential
            ))
        } catch TransportError.http(let status, let envelope) {
            switch status {
            case 404:
                throw ServiceError.notFound(formID: formID)
            case 409:
                throw ServiceError.alreadySettled(formID: formID)
            case 400 where envelope?.tag == "FormInvalidAnswerError":
                throw ServiceError.invalidAnswer(message: envelope?.message ?? "")
            default:
                throw TransportError.http(status: status, envelope: envelope)
            }
        }
    }

    /// `DELETE …/form/{formID}?message=…` → 204 — explicit
    /// cancellation only. 404 → `notFound` (already gone is settled,
    /// never a failure the user must retry); 409 → `alreadySettled`
    /// (answered/cancelled elsewhere — also settled, with the host's
    /// state authoritative).
    public func cancel(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        formID: String,
        message: String? = nil
    ) async throws {
        do {
            _ = try await makeTransport(host).perform(W10Requests.cancel(
                sessionID: sessionID,
                formID: formID,
                message: message,
                credential: credential
            ))
        } catch TransportError.http(let status, _) where status == 404 {
            throw ServiceError.notFound(formID: formID)
        } catch TransportError.http(let status, _) where status == 409 {
            // DELETE carries FormAlreadySettledError in the pinned
            // contract: the form was answered/cancelled elsewhere —
            // the caller must settle it, not surface a generic failure.
            throw ServiceError.alreadySettled(formID: formID)
        }
    }
}
