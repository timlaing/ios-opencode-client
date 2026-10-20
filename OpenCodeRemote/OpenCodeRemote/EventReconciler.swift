import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// W16 event reconciliation (docs/api-contract.md W16): maps one
/// `/api/event` frame to what the open conversation must re-read.
///
/// Classification is a PURE function of the event and the OPEN
/// session ID, so every rule is unit-testable without a transport:
///
/// - `server.connected` is the full authoritative refresh — the
///   stream has no replay, so a (re)connection is answered by
///   FETCHING state, never by assuming missed frames arrived.
/// - Session-scoped events are attributed ONLY to the open session:
///   while S08 is on screen the sessions list is not, and an event
///   without a sessionID is never guessed into scope.
/// - Text/reasoning deltas update the incremental overlay directly
///   (keyed by assistantMessageID) — the contract's "incremental
///   text; ended full value replaces accumulated text".
/// - Steps/tools/inbox/permissions/forms and every unknown extension
///   reconcile through the AUTHORITATIVE list reads: success/failure
///   boundaries come from the server's own rows, unknown parts are
///   preserved by the W04 union, and unknown event types are simply
///   ignored (never executed).
/// - `config.updated` refreshes the integrations inventory.
@MainActor
final class EventReconciler {
    enum Action: Equatable {
        case fullRefresh
        case execution(sessionID: String, finished: Bool)
        case transcript(sessionID: String)
        case stream(StreamPatch)
        case status(sessionID: String, status: ConversationLibrary.ExecutionStatus)
        case inbox(sessionID: String)
        case permissions(sessionID: String)
        case forms(sessionID: String)
        case compaction(sessionID: String)
        case usage(sessionID: String)
        case config
        case ignored
    }

    struct StreamPatch: Equatable {
        enum Kind: Equatable { case text, reasoning }
        enum Change: Equatable { case started, delta(String), ended(String) }
        var sessionID: String
        var messageID: String
        /// Which text/reasoning PART of the message this patch
        /// extends (contract: "keyed by message/ordinal"). One
        /// message's content can interleave text and tool parts — a
        /// second text part must never append to, replace, or settle
        /// the first (review W16 r2). Never guessed: an event without
        /// it falls back to the authoritative list read.
        var ordinal: Int
        var kind: Kind
        var change: Change
    }

    /// Debounced trailing refresh for high-frequency families (step
    /// streamed, tool progress): coalesces a burst of frames into one
    /// authoritative message-list read.
    static let transcriptDebounceNanoseconds: UInt64 = 750_000_000

    private let conversation: ConversationLibrary
    private let openSessionID: String
    /// Injectable debounce wait so tests observe the coalescing
    /// without waiting on it.
    private let nap: (UInt64) async -> Void
    private var transcriptDebounce: Task<Void, Never>?

    var refreshTranscript: (() async -> Void)?
    var loadInbox: (() async -> Void)?
    var loadUsage: (() async -> Void)?
    var loadApprovals: (() async -> Void)?
    var loadForms: (() async -> Void)?
    var loadContext: (() async -> Void)?
    var reloadIntegrations: (() async -> Void)?
    /// Reconnect reconciliation of the WORKING state (review W16 r1):
    /// the stream has no replay, so a terminal that landed while the
    /// connection was down left `executionStatus` — and its unpruned
    /// overlay — stale forever. `GET /api/session/active` is the
    /// authority for "is this session still running"; the view injects
    /// the session-scoped read (credential from the paired host).
    var readActiveSessions: (() async throws -> Set<String>)?
    /// W16 S17: the RAW event behind every execution terminal — the
    /// notifier needs the event's own id (stable identity) and type
    /// (canonical outcome), which the Action deliberately does not
    /// carry. Awaited, so the dedup claim lands before any later
    /// delivery of the same identity.
    var onExecutionTerminal: ((OpenCodeEvent) async -> Void)?

    init(
        conversation: ConversationLibrary,
        sessionID: String,
        nap: @escaping (UInt64) async -> Void = {
            try? await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.conversation = conversation
        self.openSessionID = sessionID
        self.nap = nap
    }

    /// Pure event → action mapping. `openSessionID` is the session
    /// whose conversation is on screen; nil matches nothing scoped.
    static func classify(_ event: OpenCodeEvent, openSessionID: String?) -> Action {
        guard let type = event.type else { return .ignored }
        let data = event.data ?? .null

        // Global families: no session attribution at all.
        switch type {
        case "server.connected": return .fullRefresh
        case "config.updated": return .config
        default: break
        }

        guard type.hasPrefix("session.") || type.hasPrefix("permission.") || type.hasPrefix("form.") else {
            return .ignored
        }
        // Never guess a scope: a session-scoped event without its
        // sessionID cannot be attributed to the open conversation.
        guard let sessionID = data["sessionID"]?.stringValue else { return .ignored }
        // Only the open session reconciles while S08 is on screen.
        guard sessionID == openSessionID else { return .ignored }

        switch type {
        case "session.execution.started":
            return .execution(sessionID: sessionID, finished: false)
        case "session.execution.succeeded",
             "session.execution.failed",
             "session.execution.interrupted":
            return .execution(sessionID: sessionID, finished: true)
        case "session.status":
            guard let status = parseStatus(data) else { return .ignored }
            return .status(sessionID: sessionID, status: status)
        case "session.inbox.enqueued",
             "session.inbox.delivered",
             "session.inbox.cancelled",
             "session.inbox.delivery.changed":
            return .inbox(sessionID: sessionID)
        case "permission.asked", "permission.replied":
            return .permissions(sessionID: sessionID)
        case "form.created", "form.replied", "form.cancelled":
            return .forms(sessionID: sessionID)
        case "session.compaction.started",
             "session.compaction.completed",
             "session.compaction.failed":
            return .compaction(sessionID: sessionID)
        case "session.usage.updated":
            return .usage(sessionID: sessionID)
        default: break
        }

        if type.hasPrefix("session.text.") || type.hasPrefix("session.reasoning.") {
            let kind: StreamPatch.Kind = type.hasPrefix("session.text.") ? .text : .reasoning
            let prefix = kind == .text ? "session.text." : "session.reasoning."
            let suffix = String(type.dropFirst(prefix.count))
            // Without the message key the delta cannot be placed —
            // fall back to the authoritative list refresh rather
            // than guessing which row it extends.
            guard let messageID = data["assistantMessageID"]?.stringValue else {
                return .transcript(sessionID: sessionID)
            }
            // Same rule for the ordinal: it is the part's index within
            // the message, and a guessed one would merge or split
            // segments arbitrarily.
            guard let ordinal = data["ordinal"]?.numberValue.flatMap({ Int(exactly: $0) }) else {
                return .transcript(sessionID: sessionID)
            }
            let patch = StreamPatch(
                sessionID: sessionID, messageID: messageID, ordinal: ordinal,
                kind: kind, change: .started
            )
            switch suffix {
            case "started":
                return .stream(patch)
            case "delta":
                return .stream(StreamPatch(
                    sessionID: sessionID, messageID: messageID, ordinal: ordinal, kind: kind,
                    change: .delta(data["delta"]?.stringValue ?? "")
                ))
            case "ended":
                return .stream(StreamPatch(
                    sessionID: sessionID, messageID: messageID, ordinal: ordinal, kind: kind,
                    change: .ended(data["text"]?.stringValue ?? "")
                ))
            default:
                return .transcript(sessionID: sessionID)
            }
        }

        // Steps and tools: the authoritative list carries their
        // boundaries and unknown parts — debounced refresh, never a
        // speculative local rendering.
        if type.hasPrefix("session.step.") || type.hasPrefix("session.tool.") {
            return .transcript(sessionID: sessionID)
        }
        // Unknown session-scoped extensions (future families) are
        // tolerated: ignored here, never executed.
        return .ignored
    }

    /// Tolerant `session.status` parse: idle/busy/retry, with retry's
    /// optional attempt counter and message. An UNKNOWN status maps to
    /// nil — the indicator keeps what it already shows rather than
    /// being guessed into idle or busy.
    private static func parseStatus(_ data: JSONValue) -> ConversationLibrary.ExecutionStatus? {
        switch data["status"]?.stringValue {
        case "idle":
            return .idle
        case "busy":
            return .busy
        case "retry":
            let attempt = data["attempt"]?.numberValue.flatMap { Int(exactly: $0) }
            return .retry(attempt: attempt, message: data["message"]?.stringValue)
        default:
            return nil
        }
    }

    /// Executes one event's action against the open conversation.
    func handle(_ event: OpenCodeEvent) async {
        switch Self.classify(event, openSessionID: openSessionID) {
        case .ignored:
            break
        case .fullRefresh:
            // No replay exists: every (re)connection re-fetches the
            // authoritative state and drops the incremental overlay —
            // anything accumulated from the dead stream is untrusted.
            conversation.clearAllStreaming()
            await refreshTranscript?()
            await loadInbox?()
            await loadApprovals?()
            await loadForms?()
            await reestablishExecutionState()
        case .execution(let sessionID, let finished):
            if finished {
                // The turn is over regardless of any stale overlay or
                // busy status (a dropped stream is NOT completion, but
                // an execution terminal event IS).
                conversation.markExecutionFinished()
                // Live delivery is the ONLY path to a banner (S17) —
                // the notifier gates app-active, dedup and consent.
                await onExecutionTerminal?(event)
            } else {
                conversation.markExecutionStarted(sessionID: sessionID)
            }
            await refreshTranscript?()
        case .transcript:
            scheduleTranscriptRefresh()
        case .stream(let patch):
            conversation.applyStream(patch)
            if case .ended = patch.change {
                // The full value replaced the overlay; fold the row
                // into the list when the burst settles.
                scheduleTranscriptRefresh()
            }
        case .status(_, let status):
            // The working/retry indicator reads executionStatus
            // directly — a status event needs no list read, and a
            // transport disconnect never touches it.
            conversation.applyStatus(status)
        case .inbox:
            await loadInbox?()
        case .permissions:
            await loadApprovals?()
        case .forms:
            await loadForms?()
        case .compaction:
            await refreshTranscript?()
            await loadContext?()
        case .usage:
            await loadUsage?()
        case .config:
            await reloadIntegrations?()
        }
    }

    /// Cancels a pending debounce (view going away) — a dismissed
    /// conversation schedules no further reads.
    func flush() {
        transcriptDebounce?.cancel()
        transcriptDebounce = nil
    }

    /// Reconnect reconciliation for the working indicator (review W16
    /// r1). A missed terminal leaves busy/retry showing forever: the
    /// stream never replays it. The active-session inventory answers —
    /// the open session's ABSENCE means the turn ended while we were
    /// down, so idle is the truth. A failed read keeps the old value:
    /// transport trouble is not evidence of completion (the same rule
    /// as a disconnect never showing it).
    private func reestablishExecutionState() async {
        guard conversation.executionStatus != .idle, let read = readActiveSessions else { return }
        do {
            let active = try await read()
            if !active.contains(openSessionID) {
                conversation.applyStatus(.idle)
            }
        } catch {
            // Honest: keep the old indicator rather than guess from a
            // failed read.
        }
    }

    private func scheduleTranscriptRefresh() {
        // Coalesce into the PENDING window instead of restarting it
        // (review W16 r4): a continuous burst of step/tool frames used
        // to cancel and re-open the wait forever, so tool cards and
        // step boundaries stayed stale for the whole burst. The first
        // frame of a window opens it; later frames join; the window's
        // deadline always arrives.
        guard transcriptDebounce == nil else { return }
        transcriptDebounce = Task { [weak self] in
            guard let self else { return }
            await self.nap(Self.transcriptDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self.transcriptDebounce = nil
            await self.refreshTranscript?()
        }
    }
}
