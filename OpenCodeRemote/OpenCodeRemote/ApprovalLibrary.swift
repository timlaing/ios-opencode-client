import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// S11 approvals (W09): the pending-permission dock above the
/// composer (docs/navigation-screens.md S08/S11,
/// docs/api-contract.md W09). Refresh-driven — the app has no live SSE
/// yet (W16): reloaded when the conversation opens, on pull-to-refresh,
/// and after every submission. Because `send` returns on durable
/// ADMISSION — before the host creates the permission request — the
/// post-send refresh is a BOUNDED WATCH, not a one-off (review R2).
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
    /// IDs settled by a 204/404 reply: a refresh that started earlier
    /// must never bring them back into the dock.
    private var settledIDs: Set<String> = []
    /// Monotonic load token — results from a superseded load are
    /// discarded, so overlapping refreshes cannot finish out of order.
    private var loadGeneration = 0
    /// The running (or last) post-send watch, with the exact context
    /// it polls under — reused when an answer through S11 re-opens the
    /// window (the released turn may ask again).
    private var watchTask: Task<Void, Never>?
    private var watchContext: (
        host: OpenCodeDomain.Host, sessionID: String,
        childSessionIDs: Set<String>, attempts: Int, intervalNanoseconds: UInt64
    )?

    var hasPending: Bool { !entries.isEmpty }
    var pendingCount: Int { entries.count }

    /// Post-send watch cadence: a bounded ~2-minute window per
    /// admission/answer. Best-effort until the live event stream (W16)
    /// replaces polling.
    static let postSendWatchAttempts = 30
    static let postSendWatchIntervalNanoseconds: UInt64 = 4_000_000_000

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
    /// back by a slow/failed location-wide call; when that call fails,
    /// the previously attributed LINKED entries are kept (still pending
    /// until the host says otherwise) and the failure surfaced.
    func load(
        host: OpenCodeDomain.Host,
        sessionID: String,
        childSessionIDs: Set<String>
    ) async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            refreshError = "Re-pair this host to check approvals."
            return
        }
        do {
            let own = try await service.list(
                at: host.address, credential: credential, sessionID: sessionID
            )
            var merged = own.map { Entry(request: $0, isLinked: false) }
            var linkedError: String?
            if !childSessionIDs.isEmpty {
                do {
                    let all = try await service.listAll(at: host.address, credential: credential)
                    let linked = all.filter {
                        childSessionIDs.contains($0.sessionID) && $0.sessionID != sessionID
                    }
                    merged += linked.map { Entry(request: $0, isLinked: true) }
                } catch {
                    // Linked entries are still pending on the host —
                    // keep the ones already attributed on screen, but
                    // ONLY for the CURRENT descendants: an owner that
                    // left the subtree must not linger in this dock.
                    merged += entries.filter {
                        $0.isLinked && childSessionIDs.contains($0.request.sessionID)
                    }
                    if !Self.isSilent(error) { linkedError = Self.message(for: error) }
                }
            }
            // A superseded load finishing late must not clobber a newer
            // result, entries settled meanwhile never return, and a
            // caller cancelled mid-flight (dismissed view, stopped
            // watch) must not publish at all — cancellation is
            // cooperative, so the service call may have completed.
            guard generation == loadGeneration, !Task.isCancelled else { return }
            entries = merged.filter { !settledIDs.contains($0.id) }
            refreshError = linkedError
        } catch {
            // A failed refresh keeps the entries on screen — they stay
            // pending until the host says otherwise — unless the
            // caller is gone: a cancelled refresh reports nothing.
            guard generation == loadGeneration, !Task.isCancelled else { return }
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
            // The answered turn resumes and may ask again — the same
            // admission-late race applies, so the watch re-opens.
            reopenWatchAfterAnswer()
            return .accepted
        } catch PermissionService.ServiceError.notPending {
            remove(entry.id)
            reopenWatchAfterAnswer()
            return .answeredElsewhere
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    // MARK: - Post-send watch (review R2)

    /// Starts (or restarts) the bounded post-send dock watch. The
    /// host creates a permission request only when the agent REACHES
    /// the guarded tool — after `send` has already returned on durable
    /// admission — and the empty/error transcript states offer no
    /// pull-to-refresh, so one refresh after send routinely ran too
    /// early. Until the live event stream (W16) arrives, the dock
    /// polls on this cadence instead: each tick reconciles through
    /// `load` (same generation, settled-ID, and cancellation guards),
    /// and the watch ends early once the dock gains a request THIS
    /// window discovered — a request that predates the window is not
    /// what it is for, and must not end it (the admitted prompt may
    /// still raise its own). Cancellation — a newer watch superseding
    /// it, the view going away — is routine and silent.
    func startPostSendWatch(
        host: OpenCodeDomain.Host,
        sessionID: String,
        childSessionIDs: Set<String>,
        attempts: Int = ApprovalLibrary.postSendWatchAttempts,
        intervalNanoseconds: UInt64 = ApprovalLibrary.postSendWatchIntervalNanoseconds
    ) {
        watchTask?.cancel()
        watchContext = (host, sessionID, childSessionIDs, attempts, intervalNanoseconds)
        // Whatever is already on the dock predates this window (an
        // earlier turn's approval, a linked child's) — only a request
        // the window itself surfaces ends it.
        let preexisting = Set(entries.map(\.id))
        watchTask = Task { [weak self] in
            for _ in 0..<max(1, attempts) {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return // cancelled — a newer watch or the view went away
                }
                guard let self, !Task.isCancelled else { return }
                await load(host: host, sessionID: sessionID, childSessionIDs: childSessionIDs)
                // The window found what it was opened for — a request
                // nobody had seen yet is on the dock; the sheet takes
                // over from here and an answer re-opens the watch.
                if entries.contains(where: { !preexisting.contains($0.id) }) { return }
            }
        }
    }

    /// Ends the watch (view dismissed) and forgets its context: a
    /// reply still in flight when the view went away must not revive
    /// a watch for a dock nobody can see. The view re-records the
    /// context on its next load (appear, pull-to-refresh, or send), so
    /// an answer after coming back still re-opens the watch.
    func stopPostSendWatch() {
        watchTask?.cancel()
        watchTask = nil
        watchContext = nil
    }

    /// Records the context an answer re-opens the watch under, WITHOUT
    /// starting to poll: a conversation opened onto an approval that
    /// predates any send here still releases its turn on answer, and
    /// that next request has the same admission-late timing. Called on
    /// every load so attribution stays current; the parameters carry
    /// the watch cadence the reopen should reuse (tests shorten it).
    func recordWatchContext(
        host: OpenCodeDomain.Host,
        sessionID: String,
        childSessionIDs: Set<String>,
        attempts: Int = ApprovalLibrary.postSendWatchAttempts,
        intervalNanoseconds: UInt64 = ApprovalLibrary.postSendWatchIntervalNanoseconds
    ) {
        watchContext = (host, sessionID, childSessionIDs, attempts, intervalNanoseconds)
    }

    /// Re-opens the watch after S11 answered (or found settled
    /// elsewhere): the released turn continues and may raise the next
    /// request with the same admission-late timing.
    private func reopenWatchAfterAnswer() {
        guard let context = watchContext else { return }
        startPostSendWatch(
            host: context.host,
            sessionID: context.sessionID,
            childSessionIDs: context.childSessionIDs,
            attempts: context.attempts,
            intervalNanoseconds: context.intervalNanoseconds
        )
    }

    private func remove(_ id: String) {
        settledIDs.insert(id)
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
