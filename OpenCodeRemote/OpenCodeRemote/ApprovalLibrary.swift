import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// S11 approvals (W09): the pending-permission dock above the
/// composer (docs/navigation-screens.md S08/S11,
/// docs/api-contract.md W09). Refresh-driven — the app has no live SSE
/// yet (W16): reloaded when the conversation opens, on pull-to-refresh,
/// and after every submission.
///
/// The session-scoped list is authoritative for the session's OWN
/// requests; the location-wide list contributes linked child-session
/// entries only when attribution is available (the sessions inventory
/// knows the descendants). Owner IDs are preserved: a linked entry
/// replies under `request.sessionID`, never the viewing session. A
/// stale 404 settles an entry as answered elsewhere — never a local
/// success — and a failed refresh KEEPS the entries already on screen
/// (still pending until the host says otherwise).
@MainActor
@Observable
final class ApprovalLibrary {
    typealias CredentialProvider = @MainActor (HostID) -> BasicCredential?

    /// One pending request plus its dock attribution.
    struct Entry: Identifiable, Equatable {
        let request: PermissionRequest
        /// True when the request belongs to a known DESCENDANT session
        /// (linked entry — the owner ID stays on `request.sessionID`).
        let isLinked: Bool
        var id: String { request.id }
    }

    /// S11 submission outcomes: the settled states of one reply.
    enum Submission: Equatable {
        /// 204 — the host accepted the decision.
        case accepted
        /// 404 — answered elsewhere / no longer pending.
        case answeredElsewhere
        /// Any other failure: the entry stays pending; retry is the
        /// user's call, never automatic.
        case failed(String)
    }

    private let service: PermissionService
    private var credentialProvider: CredentialProvider?

    /// Pending entries: the viewing session's own first, linked
    /// children after.
    private(set) var entries: [Entry] = []
    /// Last refresh failure — surfaced in the sheet; entries are kept.
    private(set) var refreshError: String?

    var hasPending: Bool { !entries.isEmpty }
    var pendingCount: Int { entries.count }

    init(
        service: PermissionService? = nil,
        credentialProvider: CredentialProvider? = nil
    ) {
        self.service = service
            ?? PermissionService(makeTransport: { URLSessionTransport(baseURL: $0) })
        self.credentialProvider = credentialProvider
    }

    /// Late-binds credential access to the host library (SwiftUI
    /// creates view state before the environment is available).
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] in hosts?.credential(for: $0) }
    }

    /// Reconciles the pending approvals for this conversation. The own
    /// list arrives first so the session's approvals are never held
    /// back by a slow/failed location-wide call — linked attribution
    /// needs the latter and is simply unavailable when it fails.
    func load(
        host: OpenCodeDomain.Host,
        sessionID: String,
        childSessionIDs: Set<String>
    ) async {
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            refreshError = "Re-pair this host to check approvals."
            return
        }
        do {
            let own = try await service.list(
                at: host.address, credential: credential, sessionID: sessionID
            )
            var merged = own.map { Entry(request: $0, isLinked: false) }
            if !childSessionIDs.isEmpty,
               let all = try? await service.listAll(at: host.address, credential: credential) {
                let linked = all.filter {
                    childSessionIDs.contains($0.sessionID) && $0.sessionID != sessionID
                }
                merged += linked.map { Entry(request: $0, isLinked: true) }
            }
            entries = merged
            refreshError = nil
        } catch {
            // A failed refresh keeps the entries on screen — they stay
            // pending until the host says otherwise.
            if !Self.isSilent(error) { refreshError = Self.message(for: error) }
        }
    }

    /// One reply (S11): 204 removes the entry; a stale 404 settles it
    /// as answered elsewhere; other failures keep it pending.
    func submit(
        _ entry: Entry,
        decision: PermissionDecision,
        message: String?,
        host: OpenCodeDomain.Host
    ) async -> Submission {
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            return .failed("Re-pair this host to answer approvals.")
        }
        do {
            try await service.reply(
                at: host.address,
                credential: credential,
                // The OWNER session — linked child entries reply at
                // their source, preserving the actual owner IDs.
                sessionID: entry.request.sessionID,
                requestID: entry.request.id,
                decision: decision,
                message: message
            )
            remove(entry.id)
            return .accepted
        } catch PermissionService.ServiceError.notPending {
            remove(entry.id)
            return .answeredElsewhere
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    private func remove(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host returned an error (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable right now. Try again once it is back."
        default:
            return "The request could not be completed."
        }
    }

    /// Cancellation is routine (view dismissed, request superseded)
    /// and never surfaced as a failure.
    private static func isSilent(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case TransportError.cancelled = error { return true }
        return false
    }
}
