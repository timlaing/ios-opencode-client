import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// S08 transcript model (W04): reads a host's conversation history via
/// `session.message.list` and its active model context via
/// `session.context` (docs/navigation-screens.md S08/S14,
/// docs/api-contract.md W04).
///
/// Paging: the first page is the NEWEST (`order: .descending`, limit 50)
/// and displays reversed (oldest → newest). Older pages walk the opaque
/// `next` cursor; the contract forbids combining cursor + order, so cursor
/// pages drop `order` (enforced in `SessionHistoryService`). Records are
/// merged by ID so overlapping refreshes/pages never duplicate a message
/// on screen.
///
/// Every message stays in the list — bookkeeping variants render as
/// compact transition rows, and unknown variants keep their raw payload
/// rather than silently dropping a gap in the transcript.
@MainActor
@Observable
final class ConversationLibrary {
    typealias CredentialProvider = @MainActor (HostID) -> BasicCredential?

    private let service: SessionHistoryService
    private let promptService: PromptService
    private let sessionService: SessionService
    private var credentialProvider: CredentialProvider?

    /// Transcript in display order: oldest → newest.
    private(set) var messages: [SessionMessage] = []
    /// Active model context (messages since the last compaction) — kept
    /// separate from the full transcript.
    private(set) var activeContext: [SessionMessage] = []
    private(set) var error: String?
    private(set) var contextError: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isLoadingContext = false
    /// Opaque cursor for the next OLDER page; nil when history is
    /// exhausted.
    private(set) var nextCursor: String?
    private(set) var hasMore = false
    /// The session whose transcript is loaded — paging reuses it.
    private(set) var loadedSessionID: String?

    // MARK: - W05 sending, stop, inbox

    private(set) var isSending = false
    /// Red banner: send/stop control failures (draft stays in the field).
    private(set) var bannerError: String?
    /// Gray banner: honest stop outcomes (`false` is NOT an error).
    private(set) var notice: String?
    /// Pending admitted work (S09), newest state from the server.
    private(set) var inboxItems: [InboxItem] = []
    private(set) var inboxError: String?
    private(set) var isLoadingInbox = false
    /// Stable ID of the last UNCONFIRMED submission, keyed to its exact
    /// text AND its attachments AND its host+session context — reused
    /// only for a retry of the same draft in the same place (same files
    /// included), so the server sees the duplicate (409) and
    /// reconciliation finds it. A different session/host/draft always
    /// earns a fresh ID.
    private var pendingSubmission: (hostID: HostID, sessionID: String, messageID: String, text: String, files: [PromptFileAttachment]?)?
    /// Admitted-but-not-yet-delivered projections, SCOPED to the session
    /// that admitted them, kept through refreshes until that session's
    /// transcript contains them or its inbox no longer lists them
    /// (cancelled elsewhere). A projection never rides into another
    /// session's transcript.
    private var projectedPending: [String: (sessionID: String, message: SessionMessage)] = [:]

    // MARK: - W13 usage + manual compaction (S14)

    /// Fresh cumulative session info from `session.get` — `cost`/
    /// `tokens` are SESSION-TOTAL figures, distinct from last-step
    /// context (docs/api-contract.md W13). Until it loads, the panel
    /// shows the list-time snapshot, which is also host-reported.
    private(set) var usageInfo: Session?
    private(set) var usageError: String?
    private(set) var isLoadingUsage = false
    /// Manual compaction (W13): single-flight like `isSending`; a
    /// failure carries its own wording and changes no other state.
    private(set) var isCompacting = false
    private(set) var compactionError: String?

    // MARK: - W16 live streaming overlay + execution status

    struct StreamingMessage: Equatable {
        var text = ""
        var reasoning = ""
        /// Set once the stream's `text.ended` full value arrived. Only
        /// a SETTLED entry may be retired by the list (review W16 r1):
        /// a mid-turn message-list row can carry partial content, and
        /// pruning an unsettled overlay against it would truncate the
        /// live tail to the next delta, restarting per delta. A
        /// reasoning-only turn never settles — its entry is bounded by
        /// the turn's execution terminal (markExecutionFinished) or a
        /// full refresh, never pruned early.
        var isSettled = false
    }

    /// Incremental assistant state keyed by assistantMessageID, fed by
    /// text/reasoning events while the host streams (docs/
    /// api-contract.md W16). The message LIST stays authoritative: a
    /// SETTLED overlay entry is retired once the transcript contains
    /// its row (an unsettled one is kept — the row may be the host's
    /// mid-turn snapshot, not the turn's final text), and a full
    /// refresh (server.connected) clears everything — the volatile
    /// stream has no replay, so anything accumulated on a dead
    /// connection is untrusted.
    private(set) var streaming: [String: StreamingMessage] = [:]

    /// Canonical working state from execution/status events. A
    /// TRANSPORT disconnect never touches it — a dropped stream is not
    /// completion (docs/api-contract.md W16).
    enum ExecutionStatus: Equatable {
        case idle
        case busy
        case retry(attempt: Int?, message: String?)
    }

    private(set) var executionStatus: ExecutionStatus = .idle

    /// Applies one incremental text/reasoning patch. `ended` carries
    /// the full value and REPLACES the accumulated text — the deltas
    /// before it are only the low-latency path to the same truth.
    func applyStream(_ patch: EventReconciler.StreamPatch) {
        guard patch.sessionID == loadedSessionID else { return }
        var entry = streaming[patch.messageID] ?? StreamingMessage()
        switch (patch.kind, patch.change) {
        case (_, .started):
            break
        case (.text, .delta(let delta)):
            entry.text += delta
        case (.text, .ended(let full)):
            entry.text = full
            // The turn's full text arrived: the entry may now be
            // retired by the list's next authoritative read.
            entry.isSettled = true
        case (.reasoning, .delta(let delta)):
            entry.reasoning += delta
        case (.reasoning, .ended(let full)):
            entry.reasoning = full
        }
        streaming[patch.messageID] = entry
    }

    func markExecutionStarted(sessionID: String) {
        guard sessionID == loadedSessionID else { return }
        executionStatus = .busy
    }

    /// An execution terminal event is authoritative: the turn is over,
    /// so the working/retry indicator and the overlay both end here —
    /// regardless of what the volatile stream did afterwards.
    func markExecutionFinished() {
        executionStatus = .idle
        streaming.removeAll()
    }

    func clearAllStreaming() {
        streaming.removeAll()
    }

    func applyStatus(_ status: ExecutionStatus) {
        executionStatus = status
    }

    /// The list owns every row it contains — but only once the turn
    /// said so: pruning an UNSETTLED entry against a mid-turn row
    /// would truncate the live tail to the next delta, restarting it
    /// per delta against the host's stale partial copy (review W16
    /// r1). While unsettled, the view renders the overlay IN PLACE of
    /// that row's text/reasoning instead of duplicating both.
    private func pruneDeliveredStreaming() {
        streaming = streaming.filter { key, entry in
            !(entry.isSettled && messages.contains { $0.id == key })
        }
    }

    init(
        service: SessionHistoryService? = nil,
        promptService: PromptService? = nil,
        sessionService: SessionService? = nil,
        credentialProvider: CredentialProvider? = nil
    ) {
        let makeTransport: @Sendable (URL) -> any OpenCodeTransport = { URLSessionTransport(baseURL: $0) }
        self.service = service ?? SessionHistoryService(makeTransport: makeTransport)
        self.promptService = promptService ?? PromptService(makeTransport: makeTransport)
        self.sessionService = sessionService ?? SessionService(makeTransport: makeTransport)
        self.credentialProvider = credentialProvider
    }

    /// Late-binds credential access to the host library (SwiftUI creates
    /// view state before the environment is available).
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] in hosts?.credential(for: $0) }
    }

    /// Opens a transcript with the newest page, displayed oldest first.
    func open(host: OpenCodeDomain.Host, sessionID: String) async {
        guard !isLoading else { return }
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to read its messages."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.messages(
                at: host.address, credential: credential, sessionID: sessionID
            )
            // Session-switch bookkeeping before the new page lands.
            discardPreviousSessionState(keeping: sessionID)
            messages = Self.ordered(Self.deduped(page.data))
            nextCursor = page.cursor?.next
            hasMore = page.cursor?.next != nil
            loadedSessionID = sessionID
            pruneDeliveredStreaming()
            error = nil
            // A re-open must not erase an admission whose delivery the
            // page does not cover yet.
            carryProjected(sessionID: sessionID)
        } catch {
            if !Self.isSilent(error) { self.error = Self.message(for: error) }
        }
    }

    /// Fetches the next OLDER page via the opaque cursor (no order) and
    /// prepends it to the display list.
    func loadOlder(host: OpenCodeDomain.Host) async {
        guard let sessionID = loadedSessionID else { return }
        guard let cursor = nextCursor, !isLoadingMore, !isLoading else { return }
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to read its messages."
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.messages(
                at: host.address, credential: credential, sessionID: sessionID, cursor: cursor
            )
            let older = Self.ordered(Self.deduped(page.data))
            let existingIDs = Set(messages.map(\.id))
            messages = older.filter { !existingIDs.contains($0.id) } + messages
            nextCursor = page.cursor?.next
            hasMore = page.cursor?.next != nil
        } catch {
            if !Self.isSilent(error) { self.error = Self.message(for: error) }
        }
    }

    /// Re-fetches the newest page and merges it: fresh records replace by
    /// ID, older records are kept, and a server-side deletion is honoured
    /// (anything absent from the newest page and already seen is dropped
    /// only when it sorts INTO that page's range — outside it, it stays).
    func refresh(host: OpenCodeDomain.Host, sessionID: String) async {
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to read its messages."
            return
        }
        do {
            let page = try await service.messages(
                at: host.address, credential: credential, sessionID: sessionID
            )
            // Session-switch bookkeeping before the new page lands.
            discardPreviousSessionState(keeping: sessionID)
            let fresh = Self.ordered(Self.deduped(page.data))
            let freshIDs = Set(fresh.map(\.id))
            // The newest page only overlaps what it covers. Without ANY
            // overlap (first load failed here, another session, or >1 page
            // of arrivals) the loaded transcript cannot be joined
            // honestly — a splice would hide the gap AND leave a cursor
            // that walks from the wrong position, so replace instead.
            let overlaps = messages.contains { freshIDs.contains($0.id) }
            if messages.isEmpty || !overlaps || loadedSessionID != sessionID {
                messages = fresh
                nextCursor = page.cursor?.next
                hasMore = page.cursor?.next != nil
            } else {
                // Overlap guarantees contiguity at the seam. Records the
                // fresh page covers are owned by it (arrivals absorbed,
                // in-range deletions honoured); records BELOW its oldest
                // are unobservable at this depth, so they stay.
                let older = messages.filter { message in
                    guard !freshIDs.contains(message.id) else { return false }
                    return Self.sortKey(message) < Self.sortKey(fresh.first)
                }
                messages = older + fresh
            }
            loadedSessionID = sessionID
            // The fresh page is authoritative: overlay rows it now
            // carries are retired (W16).
            pruneDeliveredStreaming()
            error = nil
            // A projected-but-undelivered admission is NOT in the newest
            // page yet: the merge must not erase it. It survives while
            // the inbox still admits it; once the transcript contains it
            // it's retired to the transcript's ownership.
            await pruneProjected(host: host, sessionID: sessionID, credential: credential)
            carryProjected(sessionID: sessionID)
        } catch {
            if !Self.isSilent(error) { self.error = Self.message(for: error) }
        }
    }

    /// Loads the active model context (messages since the last
    /// compaction) for the S14 panel.
    func loadContext(host: OpenCodeDomain.Host, sessionID: String) async {
        guard !isLoadingContext else { return }
        guard let credential = credentialProvider?(host.id) else {
            contextError = "Re-pair this host to read its context."
            return
        }
        isLoadingContext = true
        defer { isLoadingContext = false }
        do {
            activeContext = Self.ordered(Self.deduped(
                try await service.context(at: host.address, credential: credential, sessionID: sessionID)
            ))
            contextError = nil
        } catch {
            if !Self.isSilent(error) { contextError = Self.message(for: error) }
        }
    }

    // MARK: - Sending, stop, inbox (W05)

    /// Admits one prompt. The app chooses a STABLE message ID up front:
    /// every failure path reconciles against the inbox and transcript by
    /// that ID BEFORE any retry is offered (the app adds no exactly-once
    /// claim). Returns true only when the prompt is durably admitted —
    /// directly or by reconciliation — so callers clear the draft exactly
    /// then and never otherwise.
    func send(
        host: OpenCodeDomain.Host,
        sessionID: String,
        text: String,
        files: [PromptFileAttachment]? = nil,
        delivery: InboxDelivery? = nil
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = (files?.isEmpty ?? true) ? nil : files
        guard !trimmed.isEmpty, !isSending else { return false }
        guard let credential = credentialProvider?(host.id) else {
            bannerError = "Re-pair this host to send messages."
            return false
        }
        isSending = true
        defer { isSending = false }
        // The same draft retries under the SAME stable ID in the SAME
        // host+session — a duplicate then gets 409 and is reconciled.
        // Any other context (different text, attachments, session, or
        // host) earns a fresh ID.
        let messageID: String
        if let pending = pendingSubmission,
           pending.hostID == host.id, pending.sessionID == sessionID,
           pending.text == trimmed, pending.files == attachments {
            messageID = pending.messageID
        } else {
            messageID = Self.stableMessageID()
        }
        pendingSubmission = (host.id, sessionID, messageID, trimmed, attachments)
        do {
            let item = try await promptService.prompt(
                at: host.address, credential: credential, sessionID: sessionID,
                text: trimmed, files: attachments, messageID: messageID, delivery: delivery
            )
            admit(item, sessionID: sessionID)
            pendingSubmission = nil
            bannerError = nil
            notice = nil
            // Authoritative read follows admission — W16 events also
            // reconcile it live (execution/inbox arrivals refresh the
            // same list), but the post-admission read is the barrier.
            await refresh(host: host, sessionID: sessionID)
            return true
        } catch {
            if await reconcileAdmission(host: host, sessionID: sessionID, messageID: messageID, credential: credential) {
                pendingSubmission = nil
                bannerError = nil
                return true
            }
            if !Self.isSilent(error) {
                bannerError = Self.sendErrorMessage(for: error)
            }
            return false
        }
    }

    /// Ordinary Stop (`interrupt?resume=false`). `interrupted == false`
    /// is an honest "nothing was running" outcome, never an error.
    func stop(host: OpenCodeDomain.Host, sessionID: String) async {
        guard let credential = credentialProvider?(host.id) else {
            bannerError = "Re-pair this host to stop execution."
            return
        }
        do {
            let interrupted = try await promptService.interrupt(
                at: host.address, credential: credential, sessionID: sessionID
            )
            notice = interrupted ? "Stopped the active turn." : "Nothing was running."
            bannerError = nil
        } catch {
            if !Self.isSilent(error) { bannerError = Self.stopErrorMessage(for: error) }
        }
    }

    /// Searched by the STABLE message ID after an uncertain submission —
    /// inbox first, then the projected transcript — before a retry is
    /// ever offered (docs/api-contract.md W05).
    private func reconcileAdmission(
        host: OpenCodeDomain.Host, sessionID: String, messageID: String, credential: BasicCredential?
    ) async -> Bool {
        if let items = try? await promptService.inbox(at: host.address, credential: credential, sessionID: sessionID),
           let item = items.first(where: { $0.id == messageID }) {
            admit(item, sessionID: sessionID)
            return true
        }
        await refresh(host: host, sessionID: sessionID)
        if messages.contains(where: { $0.id == messageID }) { return true }
        return false
    }

    /// A committed SESSION SWITCH discards the OLD session's projection
    /// and pending-submission state, while keeping everything that
    /// belongs to the session now being loaded — it may just have been
    /// admitted (`send` before its `open`) and must survive its first
    /// refresh. `loadedSessionID == nil` means nothing committed yet:
    /// all state belongs to the session being loaded and is kept.
    private func discardPreviousSessionState(keeping sessionID: String) {
        guard let loaded = loadedSessionID, loaded != sessionID else { return }
        projectedPending = projectedPending.filter { $0.value.sessionID == sessionID }
        if let pending = pendingSubmission, pending.sessionID != sessionID {
            pendingSubmission = nil
        }
        // The streaming overlay and working state belong to the
        // PREVIOUS session's turn — never carried across (W16).
        streaming.removeAll()
        executionStatus = .idle
    }

    /// Projects an admitted user item into the transcript once; a later
    /// refresh dedupes by the shared ID. The projection is TRACKED under
    /// its session until delivery so an immediate refresh cannot erase
    /// the just-sent message while the server still has it only in the
    /// inbox — and it only ever lands in ITS OWN session's transcript.
    private func admit(_ item: InboxItem, sessionID: String) {
        guard let projected = item.projectedMessage else { return }
        projectedPending[projected.id] = (sessionID, projected)
        // Land it visibly only when it belongs to the transcript on
        // screen (or none has loaded yet).
        guard loadedSessionID == nil || loadedSessionID == sessionID else { return }
        guard !messages.contains(where: { $0.id == projected.id }) else { return }
        messages.append(projected)
    }

    /// Re-attaches admitted-but-undelivered projections of THIS session
    /// after a page merge, retiring the ones its transcript now owns.
    /// Each projection is INSERTED at its server-sort position — the
    /// projection's timestamp comes from server time at admission, but a
    /// clock skew must not strand it out of order until delivery.
    private func carryProjected(sessionID: String) {
        let scoped = projectedPending.filter { $0.value.sessionID == sessionID }
        let delivered = scoped.filter { entry in
            messages.contains { $0.id == entry.value.message.id }
        }.map(\.key)
        delivered.forEach { projectedPending.removeValue(forKey: $0) }
        let missing = scoped.values
            .map(\.message)
            .filter { projection in !messages.contains { $0.id == projection.id } }
            .sorted { $0.time.created < $1.time.created }
        for projection in missing {
            let index = messages.firstIndex { Self.sortKey($0) > Self.sortKey(projection) } ?? messages.endIndex
            messages.insert(projection, at: index)
        }
    }

    /// Drops this session's projections the server no longer admits
    /// (cancelled from the inbox elsewhere). A failed inbox read KEEPS
    /// them — unverifiable is not gone. Other sessions' projections are
    /// never judged against this inbox.
    private func pruneProjected(host: OpenCodeDomain.Host, sessionID: String, credential: BasicCredential?) async {
        guard projectedPending.values.contains(where: { $0.sessionID == sessionID }) else { return }
        guard let admitted = try? await promptService.inbox(at: host.address, credential: credential, sessionID: sessionID) else {
            return
        }
        let admittedIDs = Set(admitted.map(\.id))
        let gone = projectedPending
            .filter { $0.value.sessionID == sessionID && !admittedIDs.contains($0.key) }
            .map(\.key)
        gone.forEach { projectedPending.removeValue(forKey: $0) }
    }

    // MARK: - Inbox (S09)

    func loadInbox(host: OpenCodeDomain.Host, sessionID: String) async {
        guard !isLoadingInbox else { return }
        guard let credential = credentialProvider?(host.id) else {
            inboxError = "Re-pair this host to read pending prompts."
            return
        }
        isLoadingInbox = true
        defer { isLoadingInbox = false }
        do {
            inboxItems = try await promptService.inbox(at: host.address, credential: credential, sessionID: sessionID)
            inboxError = nil
        } catch {
            if !Self.isSilent(error) { inboxError = Self.message(for: error) }
        }
    }

    // MARK: - W13 usage + manual compaction (S14)

    /// S14 (`session.get`): the fresh CUMULATIVE cost/tokens/model for
    /// the usage panel. A failure keeps any previously loaded info and
    /// carries its own error; cancellation is silent.
    func loadUsage(host: OpenCodeDomain.Host, sessionID: String) async {
        guard !isLoadingUsage else { return }
        guard let credential = credentialProvider?(host.id) else {
            usageError = "Re-pair this host to read its usage."
            return
        }
        isLoadingUsage = true
        defer { isLoadingUsage = false }
        do {
            usageInfo = try await sessionService.session(
                at: host.address, credential: credential, sessionID: sessionID
            )
            usageError = nil
        } catch {
            if !Self.isSilent(error) { usageError = Self.usageErrorMessage(for: error) }
        }
    }

    private static func usageErrorMessage(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not load usage (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable right now. Pull to refresh to try again."
        default:
            return "Usage could not be loaded from this host."
        }
    }

    /// W13 manual compaction. The host's response is an ADMISSION only —
    /// it runs at the next step boundary — so a successful request
    /// refreshes the admission-bearing inbox, the active context and the
    /// cumulative totals. The transcript is never trimmed locally: the
    /// compaction transition arrives with the normal history refresh and
    /// the full transcript stays preserved (docs/api-contract.md W13).
    func compact(host: OpenCodeDomain.Host, sessionID: String, delivery: InboxDelivery? = nil) async {
        guard !isCompacting else { return }
        guard let credential = credentialProvider?(host.id) else {
            compactionError = "Re-pair this host to compact its context."
            return
        }
        isCompacting = true
        defer { isCompacting = false }
        do {
            _ = try await sessionService.compact(
                at: host.address, credential: credential, sessionID: sessionID, delivery: delivery
            )
            compactionError = nil
            // Admission, not completion — the copy says exactly that.
            notice = "Compaction requested — it runs at the next step boundary."
            await loadInbox(host: host, sessionID: sessionID)
            await loadContext(host: host, sessionID: sessionID)
            await loadUsage(host: host, sessionID: sessionID)
        } catch {
            if !Self.isSilent(error) { compactionError = Self.compactErrorMessage(for: error) }
        }
    }

    private static func compactErrorMessage(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not accept the compaction request (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable — the compaction request was not sent."
        default:
            return "The compaction request failed."
        }
    }

    func setDelivery(host: OpenCodeDomain.Host, sessionID: String, inboxID: String, delivery: InboxDelivery) async {
        guard let credential = credentialProvider?(host.id) else {
            inboxError = "Re-pair this host to change pending prompts."
            return
        }
        do {
            try await promptService.updateDelivery(
                at: host.address, credential: credential, sessionID: sessionID, inboxID: inboxID, delivery: delivery
            )
            if let index = inboxItems.firstIndex(where: { $0.id == inboxID }) {
                inboxItems[index].delivery = delivery
            }
        } catch {
            if !Self.isSilent(error) { inboxError = Self.message(for: error) }
        }
    }

    func cancelInbox(host: OpenCodeDomain.Host, sessionID: String, inboxID: String) async {
        guard let credential = credentialProvider?(host.id) else {
            inboxError = "Re-pair this host to cancel pending prompts."
            return
        }
        do {
            try await promptService.cancel(
                at: host.address, credential: credential, sessionID: sessionID, inboxID: inboxID
            )
            // The 204 is authority; re-read when possible, else fall back
            // to the local drop (the item is gone or was already gone).
            if let fresh = try? await promptService.inbox(at: host.address, credential: credential, sessionID: sessionID) {
                inboxItems = fresh
            } else {
                inboxItems.removeAll { $0.id == inboxID }
            }
        } catch {
            if !Self.isSilent(error) { inboxError = Self.message(for: error) }
        }
    }

    // MARK: - Transcript helpers

    /// Display order: oldest → newest (server order is newest first).
    private static func ordered(_ page: [SessionMessage]) -> [SessionMessage] {
        Array(page.reversed())
    }

    /// Keeps the FIRST record for each ID in page order.
    private static func deduped(_ page: [SessionMessage]) -> [SessionMessage] {
        var seen: Set<String> = []
        return page.filter { seen.insert($0.id).inserted }
    }

    /// Server sort key (time.created, id) ascending — mirrors the host's
    /// ordering so merge boundaries are honest.
    private static func sortKey(_ message: SessionMessage?) -> (Int64, String) {
        guard let message else { return (.min, "") }
        return (message.time.created, message.id)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not load messages (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable right now. Pull to refresh to try again."
        default:
            return "Messages could not be loaded from this host."
        }
    }

    /// Send/stop failure wording — always honest about the draft.
    private static func sendErrorMessage(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host did not accept the message (HTTP \(status)). Your draft is kept."
        case TransportError.connectionFailed:
            return "Connection lost — your draft is kept. Retrying first re-checks the pending list."
        default:
            return "The message could not be sent. Your draft is kept."
        }
    }

    /// Stop-specific failure wording — never send/draft language.
    private static func stopErrorMessage(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not stop the turn (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable — the turn may still be running."
        default:
            return "The turn could not be stopped."
        }
    }

    /// The app's stable per-prompt ID (`msg_` pattern): the handle every
    /// failure path reconciles admission against.
    private static func stableMessageID() -> String {
        "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Cancellation is routine (view dismissed, request superseded) and
    /// never surfaced as a failure.
    private static func isSilent(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case TransportError.cancelled = error { return true }
        return false
    }
}
