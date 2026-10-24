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
final class FormLibrary: PostSendDock {
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
    /// The bounded post-send window this dock drives (shared with the
    /// approval dock — see `PostSendDock`); the runner holds this dock
    /// only weakly.
    let watch = PostSendWatchRunner()

    var hasPending: Bool { !entries.isEmpty }
    var pendingCount: Int { entries.count }
    /// What the watch compares against: this dock's pending IDs.
    var pendingIDs: [String] { entries.map(\.id) }

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
    /// message. 204, 409 (settled elsewhere), and 404 all settle the
    /// dock entry — none of them is an error to retry; only the
    /// distinct outcome tells the sheet which settled state to show.
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
        } catch FormService.ServiceError.alreadySettled {
            // The form was answered/cancelled elsewhere — the host's
            // state is authoritative and the dock entry is done, not
            // left editable under a generic failure.
            remove(entry.id)
            reopenWatchAfterAnswer()
            return .alreadySettled
        } catch FormService.ServiceError.notFound {
            remove(entry.id)
            reopenWatchAfterAnswer()
            return .gone
        } catch {
            return .failed(Self.message(for: error))
        }
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
