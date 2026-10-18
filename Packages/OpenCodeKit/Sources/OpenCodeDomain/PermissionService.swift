import Foundation
import OpenCodeTransport

/// W09 approvals (docs/api-contract.md W09, S11): reconcile pending
/// permission requests (session-scoped or location-wide), re-read one
/// before acting, and reply 204-authoritatively. A stale 404 is NOT a
/// local success — it maps to `notPending` so the UI settles the entry
/// as “Answered Elsewhere / No Longer Pending” instead of claiming an
/// approval that never happened.
public struct PermissionService: Sendable {
    public enum ServiceError: Error, Equatable, Sendable {
        /// 404 on get/reply: the request no longer exists (answered
        /// elsewhere, cancelled, or superseded).
        case notPending(requestID: String)
    }

    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// `GET /api/session/{sessionID}/permission` → this session's own
    /// pending requests.
    public func list(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String
    ) async throws -> [PermissionRequest] {
        try await makeTransport(host)
            .perform(W09Requests.list(sessionID: sessionID, credential: credential))
            .decodedJSON(PermissionListResponse.self)
            .data
    }

    /// `GET /api/permission/request` → every pending request in the
    /// location (located envelope — `location` is not part of the
    /// payload contract). Callers filter it down to the sessions they
    /// can actually attribute (current session + known descendants).
    public func listAll(at host: URL, credential: BasicCredential?) async throws -> [PermissionRequest] {
        try await makeTransport(host)
            .perform(W09Requests.listAll(credential: credential))
            .decodedJSON(PermissionListResponse.self)
            .data
    }

    /// `GET …/permission/{requestID}` — the re-read before acting after
    /// a notification/reconnect. 404 → `notPending`.
    public func get(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        requestID: String
    ) async throws -> PermissionRequest {
        do {
            return try await makeTransport(host)
                .perform(W09Requests.get(
                    sessionID: sessionID, requestID: requestID, credential: credential
                ))
                .decodedJSON(PermissionDetailResponse.self)
                .data
        } catch TransportError.http(let status, _) where status == 404 {
            throw ServiceError.notPending(requestID: requestID)
        }
    }

    /// `POST …/reply` → 204 (authoritative). `sessionID` is the
    /// request's OWNER session — linked child entries reply under their
    /// actual owner, never the viewing session.
    public func reply(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        requestID: String,
        decision: PermissionDecision,
        message: String? = nil
    ) async throws {
        do {
            _ = try await makeTransport(host).perform(W09Requests.reply(
                sessionID: sessionID,
                requestID: requestID,
                decision: decision,
                message: message,
                credential: credential
            ))
        } catch TransportError.http(let status, _) where status == 404 {
            throw ServiceError.notPending(requestID: requestID)
        }
    }
}
