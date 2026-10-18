import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// S12 forms (W10): the pending-question dock above the composer
/// (docs/navigation-screens.md S08/S12, docs/api-contract.md W10).
/// Refresh-driven like S11 — reconciled when the conversation opens,
/// on pull-to-refresh, and after every submission — and, for the same
/// reason as the approval watch, the post-send refresh is a BOUNDED
/// WATCH: `send` returns on durable admission before the host creates
/// the form (a form is raised mid-turn by the agent), and the
/// empty/error transcript states offer no pull-to-refresh.
///
/// The session-scoped list is authoritative for the session's OWN
/// forms; the location-wide list contributes linked child-session forms
/// only when attribution is available (the sessions inventory knows the
/// descendants). Owner IDs are preserved: a linked entry replies and
/// cancels under `form.sessionID`, never the viewing session. A settled
/// form never returns — 204, 409, and 404 all settle it locally — and
/// a failed refresh KEEPS the entries already on screen (still pending
/// until the host says otherwise), scoped to CURRENT descendants.
@MainActor @Observable
final class FormLibrary {
    typealias CredentialProvider = @MainActor (HostID) -> BasicCredential?

    /// One pending form plus its dock attribution.
    struct Entry: Identifiable, Equatable {
        let form: FormInfo
        /// True when the form belongs to a known DESCENDANT session
        /// (linked entry — the owner ID stays on `form.sessionID`).
        let isLinked: Bool
        var id: String { form.id }
        /// The session that owns the form — every reply/cancel/cancel
        /// re-read targets this, never the viewing session.
        var ownerSessionID: String { form.sessionID }
    }

    /// S12 submission outcomes: the settled states of one reply or
    /// cancellation.
    enum Submission: Equatable {
        /// 204 — the host settled the form.
        case accepted
        /// 409 — the form was already settled (answered or cancelled
        /// elsewhere): the host's state is authoritative and the local
        /// input must not be claimed as submitted.
        case alreadySettled
        /// 404 — the form no longer exists for this owner.
        case gone
        /// Any other failure (including a rejected answer): the entry
        /// stays pending with its input retained; retry is the user's
        /// call, never automatic.
        case failed(String)
    }

    /// The single-form re-read the sheet renders from: its `state` is
    /// what decides editable vs settled (S12).
    enum DetailOutcome: Equatable {
        case loaded(FormDetail)
        /// 404 — settled or withdrawn elsewhere before the sheet read it.
        case gone
        case unavailable(String)
    }

    private let service: FormService
    private var credentialProvider: CredentialProvider?

    /// Pending entries: the viewing session's own first, linked
    /// children after.
    private(set) var entries: [Entry] = []
    /// Last refresh failure — surfaced in the sheet; entries are kept.
    private(set) var refreshError: String?
    /// IDs settled by a 204/409/404: a refresh that started earlier
    /// must never bring them back into the dock.
    private var settledIDs: Set<String> = []
    /// Monotonic load token — results from a superseded load are
    /// discarded, so overlapping refreshes cannot finish out of order.
    private var loadGeneration = 0
    /// The running (or last) post-send watch, with the exact context
    /// it polls under — reused when an answer through S12 re-opens the
    /// window (the released turn may raise the next question).
    private var watchTask: Task<Void, Never>?
    private var watchContext: (
        host: OpenCodeDomain.Host, sessionID: String,
        childSessionIDs: Set<String>, attempts: Int, intervalNanoseconds: UInt64
    )?

    var hasPending: Bool { !entries.isEmpty }
    var pendingCount: Int { entries.count }

    /// Post-send watch cadence: a bounded ~2-minute window per
    /// admission/answer, the same as S11's. Best-effort until the live
    /// event stream (W16) replaces polling.
    static let postSendWatchAttempts = 30
    static let postSendWatchIntervalNanoseconds: UInt64 = 4_000_000_000

    init(
        service: FormService? = nil,
        credentialProvider: CredentialProvider? = nil
    ) {
        self.service = service
            ?? FormService(makeTransport: { URLSessionTransport(baseURL: $0) })
        self.credentialProvider = credentialProvider
    }

    /// Late-binds credential access to the host library (SwiftUI
    /// creates view state before the environment is available).
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] in hosts?.credential(for: $0) }
    }

    /// Reconciles the pending forms for this conversation. The own
    /// list arrives first so the session's questions are never held
    /// back by a slow/failed location-wide call; when that call fails,
    /// the previously attributed LINKED entries are kept (still pending
    /// until the host says otherwise) — but ONLY for the CURRENT
    /// descendants, and the failure is surfaced.
    func load(
        host: OpenCodeDomain.Host,
        sessionID: String,
        childSessionIDs: Set<String>
    ) async {
        loadGeneration += 1
        let generation = loadGeneration
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            refreshError = "Re-pair this host to check questions."
            return
        }
        do {
            let own = try await service.list(
                at: host.address, credential: credential, sessionID: sessionID
            )
            var merged = own.map { Entry(form: $0, isLinked: false) }
            var linkedError: String?
            if !childSessionIDs.isEmpty {
                do {
                    let all = try await service.listAll(at: host.address, credential: credential)
                    let linked = all.filter {
                        childSessionIDs.contains($0.sessionID) && $0.sessionID != sessionID
                    }
                    merged += linked.map { Entry(form: $0, isLinked: true) }
                } catch {
                    // Linked entries are still pending on the host —
                    // keep the ones already attributed on screen, but
                    // ONLY for the CURRENT descendants: an owner that
                    // left the subtree must not linger in this dock.
                    merged += entries.filter {
                        $0.isLinked && childSessionIDs.contains($0.ownerSessionID)
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

    /// The single-form re-read for S12: the sheet renders from the
    /// detail's `state` (and re-reads it after a 409 to show the
    /// authoritative settled state). Never publishes dock state.
    func detail(
        host: OpenCodeDomain.Host,
        sessionID: String,
        formID: String
    ) async -> DetailOutcome {
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            return .unavailable("Re-pair this host to open this question.")
        }
        do {
            let detail = try await service.get(
                at: host.address, credential: credential,
                sessionID: sessionID, formID: formID
            )
            return .loaded(detail)
        } catch FormService.ServiceError.notFound {
            return .gone
        } catch {
            if Self.isSilent(error) { return .unavailable("The question closed while loading.") }
            return .unavailable(Self.message(for: error))
        }
    }

    /// Settles an entry the sheet found already gone (a 404 detail
    /// read): a form that no longer exists on the host must not linger
    /// in the dock until the next refresh — and never returns.
    func settleGone(_ id: String) {
        remove(id)
    }

    /// One reply (S12): 204 settles it locally; 409 and 404 also settle
    /// it — the host is authoritative about its state and a settled
    /// form is never editable again; a rejected answer (400) keeps the
    /// entry AND the user's input so the fix can be applied in place.
    func submit(
        _ entry: Entry,
        answer: [String: FormValue],
        host: OpenCodeDomain.Host
    ) async -> Submission {
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            return .failed("Re-pair this host to answer questions.")
        }
        do {
            try await service.reply(
                at: host.address,
                credential: credential,
                // The OWNER session — linked forms reply at their
                // source, preserving the actual owner IDs.
                sessionID: entry.ownerSessionID,
                formID: entry.id,
                answer: answer
            )
            remove(entry.id)
            // The answered turn resumes and may raise the next question
            // with the same admission-late timing — re-open the watch.
            reopenWatchAfterAnswer()
            return .accepted
        } catch FormService.ServiceError.alreadySettled {
            remove(entry.id)
            reopenWatchAfterAnswer()
            return .alreadySettled
        } catch FormService.ServiceError.notFound {
            remove(entry.id)
            reopenWatchAfterAnswer()
            return .gone
        } catch FormService.ServiceError.invalidAnswer(let message) {
            // The host rejected the ANSWER, not the form: keep the
            // entry (and the draft it validates) on screen.
            return .failed(message)
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    /// Explicit cancellation (S12): DELETE with the user's optional
    /// message. 204 and 404 both settle the dock entry — cancelling a
    /// form that is already gone is done, not an error to retry.
    func cancel(
        _ entry: Entry,
        message: String?,
        host: OpenCodeDomain.Host
    ) async -> Submission {
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            return .failed("Re-pair this host to cancel this question.")
        }
        do {
            try await service.cancel(
                at: host.address,
                credential: credential,
                sessionID: entry.ownerSessionID,
                formID: entry.id,
                message: message
            )
            remove(entry.id)
            reopenWatchAfterAnswer()
            return .accepted
        } catch FormService.ServiceError.notFound {
            remove(entry.id)
            reopenWatchAfterAnswer()
            return .gone
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    // MARK: - Post-send watch (mirrors S11's R2–R4 hardening)

    /// Starts (or restarts) the bounded post-send dock watch. The host
    /// creates a form only when the agent RAISES it mid-turn — after
    /// `send` has already returned on durable admission — so one
    /// refresh after send routinely runs too early. Until the live
    /// event stream (W16) arrives, the dock polls on this cadence
    /// instead: each tick reconciles through `load` (same generation,
    /// settled-ID, and cancellation guards), and the watch ends early
    /// once the dock gains a request THIS window discovered — a form
    /// that predates the window is not what it is for, and must not
    /// end it (the admitted prompt may still raise its own). A
    /// cancelled caller publishes nothing (review R4).
    func startPostSendWatch(
        host: OpenCodeDomain.Host,
        sessionID: String,
        childSessionIDs: Set<String>,
        attempts: Int = FormLibrary.postSendWatchAttempts,
        intervalNanoseconds: UInt64 = FormLibrary.postSendWatchIntervalNanoseconds
    ) {
        watchTask?.cancel()
        watchContext = (host, sessionID, childSessionIDs, attempts, intervalNanoseconds)
        // Whatever is already on the dock predates this window (an
        // earlier turn's question, a linked child's) — only a form the
        // window itself surfaces ends it.
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
                // The window found what it was opened for — a question
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
    /// starting to poll: a conversation opened onto a question that
    /// predates any send here still settles its turn on answer, and
    /// that next question has the same admission-late timing. Called on
    /// every load so attribution stays current.
    func recordWatchContext(
        host: OpenCodeDomain.Host,
        sessionID: String,
        childSessionIDs: Set<String>,
        attempts: Int = FormLibrary.postSendWatchAttempts,
        intervalNanoseconds: UInt64 = FormLibrary.postSendWatchIntervalNanoseconds
    ) {
        watchContext = (host, sessionID, childSessionIDs, attempts, intervalNanoseconds)
    }

    /// Re-opens the watch after S12 settled (or found settled
    /// elsewhere): the released turn continues and may raise the next
    /// question with the same admission-late timing.
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
