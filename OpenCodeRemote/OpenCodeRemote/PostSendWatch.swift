import OpenCodeDomain

/// The post-send watch cadence shared by the admission (form) and
/// answer (approval) send paths: a bounded ~2-minute window per send,
/// polling session status as a best-effort supplement until the live
/// event stream (W16) replaces it. Both docks keep their own entries;
/// the cadence lives here so the two copies cannot drift apart.
enum PostSendWatch {
    nonisolated static let attempts = 30
    nonisolated static let intervalNanoseconds: UInt64 = 4_000_000_000
}

/// The inputs that anchor one post-send watch window: where to look,
/// and how long to keep looking.
struct PostSendWatchRequest {
    let host: OpenCodeDomain.Host
    let sessionID: String
    let childSessionIDs: Set<String>
    var attempts: Int = PostSendWatch.attempts
    var intervalNanoseconds: UInt64 = PostSendWatch.intervalNanoseconds
}

/// A dock the bounded post-send watch can reconcile. The approval
/// (S11) and form (S12) docks both poll a pending list on the same
/// cadence, so the window lives in `PostSendWatchRunner` and each dock
/// supplies only what is genuinely its own: what is pending, and how
/// to refresh it.
@MainActor
protocol PostSendDock: AnyObject {
    /// The dock's currently pending entry IDs.
    var pendingIDs: [String] { get }
    /// The window machinery this dock drives.
    var watch: PostSendWatchRunner { get }
    /// Reconciles this dock with the host — the same generation,
    /// settled-ID and cancellation guards as any other refresh.
    func load(host: OpenCodeDomain.Host, sessionID: String, childSessionIDs: Set<String>) async
}

@MainActor
extension PostSendDock {
    /// Starts (or restarts) the bounded post-send dock watch. The host
    /// creates the entry only when the agent reaches the guarded tool
    /// or raises the form mid-turn — after `send` has already returned
    /// on durable admission — so one refresh after send routinely runs
    /// too early. Each tick reconciles through `load` (same
    /// generation, settled-ID, and cancellation guards), and the
    /// window ends early once the dock gains an entry THIS window
    /// discovered — an entry that predates the window is not what it
    /// is for, and must not end it (the admitted prompt may still
    /// raise its own). Cancellation — a newer watch superseding it,
    /// the view going away — is routine and silent.
    func startPostSendWatch(_ request: PostSendWatchRequest) {
        watch.start(request, on: self)
    }

    /// Ends the watch (view dismissed) and forgets its context: a
    /// reply still in flight when the view went away must not revive
    /// a watch for a dock nobody can see. The view re-records the
    /// context on its next load (appear, pull-to-refresh, or send), so
    /// an answer after coming back still re-opens the watch.
    func stopPostSendWatch() {
        watch.stop()
    }

    /// Records the context an answer re-opens the watch under, WITHOUT
    /// starting to poll: a conversation opened onto an entry that
    /// predates any send here still settles its turn on answer, and
    /// that next entry has the same admission-late timing. Called on
    /// every load so attribution stays current; the request carries
    /// the watch cadence the reopen should reuse (tests shorten it).
    func recordWatchContext(_ request: PostSendWatchRequest) {
        watch.record(request, on: self)
    }

    /// Re-opens the watch after an answer released (or found settled
    /// elsewhere) the turn: the released turn continues and may raise
    /// the next entry with the same admission-late timing.
    func reopenWatchAfterAnswer() {
        watch.reopen()
    }
}

/// One bounded post-send window: sleeps, reconciles the dock, and ends
/// early once the dock gains an entry THIS window discovered. The dock
/// owns the runner and the runner holds the dock only weakly, so a
/// window in flight can never keep a dock (or the view behind it)
/// alive — when the dock goes, the next tick ends the window silently.
@MainActor
final class PostSendWatchRunner {
    /// The window in flight (or last recorded), with the exact request
    /// it polls under — reused when an answer re-opens the window.
    private weak var dock: (any PostSendDock)?
    private var request: PostSendWatchRequest?
    private var task: Task<Void, Never>?

    /// Starts (or restarts) the window for `newDock`.
    func start(_ newRequest: PostSendWatchRequest, on newDock: any PostSendDock) {
        task?.cancel()
        dock = newDock
        request = newRequest
        // Whatever is already on the dock predates this window (an
        // earlier turn's entry, a linked child's) — only an entry the
        // window itself surfaces ends it.
        let preexisting = Set(newDock.pendingIDs)
        task = Task { [weak dock = newDock] in
            for _ in 0..<max(1, newRequest.attempts) {
                do {
                    try await Task.sleep(nanoseconds: newRequest.intervalNanoseconds)
                } catch {
                    return // cancelled — a newer watch or the view went away
                }
                guard let dock, !Task.isCancelled else { return }
                await dock.load(host: newRequest.host, sessionID: newRequest.sessionID,
                           childSessionIDs: newRequest.childSessionIDs)
                // The window found what it was opened for — an entry
                // nobody had seen yet is on the dock; the sheet takes
                // over from here and an answer re-opens the watch.
                if dock.pendingIDs.contains(where: { !preexisting.contains($0) }) { return }
            }
        }
    }

    /// Records a window without polling it: attribution only, so the
    /// next answer can re-open the watch with the same cadence.
    func record(_ newRequest: PostSendWatchRequest, on newDock: any PostSendDock) {
        dock = newDock
        request = newRequest
    }

    /// Ends the window and forgets its context: an answer that
    /// settles later must not revive a watch for a dock nobody can
    /// see.
    func stop() {
        task?.cancel()
        task = nil
        dock = nil
        request = nil
    }

    /// Re-opens the recorded window, re-reading the dock's pending
    /// entries so only what arrives from here on can end it.
    func reopen() {
        guard let request, let dock else { return }
        start(request, on: dock)
    }
}
