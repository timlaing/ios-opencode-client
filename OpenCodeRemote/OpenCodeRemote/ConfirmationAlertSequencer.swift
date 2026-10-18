import Foundation
import Observation

/// Which queued confirmation is on screen (the W08 alert chain feeding
/// S11-adjacent decisions).
///
/// SwiftUI ignores changes to an alert's presented data while the alert
/// is on screen, and its `isPresented` write of `false` only signals
/// that dismissal STARTED — not that it completed. Each question
/// therefore gets its own presentation cycle:
///
/// - `alertDismissed()` (the binding's false-write) is the ONLY thing
///   that clears `presented` — the buttons never touch it, so a
///   dismissal write can never race an answer.
/// - The next queue head is presented only after the dismissal has
///   fully SETTLED, and the queue is RE-READ at that point — a
///   question removed or answered meanwhile is never presented.
///
/// The settle window must outlast SwiftUI's dismissal to completion.
/// Measured on iOS 27 (hosted `ConfirmationAlertPresentationTests`):
/// the alert is visually gone ~400 ms after the write, but its
/// `PlatformAlertController` only leaves the presented chain at
/// ~800 ms. Re-presenting before that (an earlier 500 ms window) made
/// SwiftUI reject the new presentation and emit further `false`
/// echoes — an endless present/clear oscillation. Every false-write
/// restarts the window (debounce), so even late echoes from a
/// dismissal are absorbed before the next question appears.
///
/// `queueMayHaveAdvanced()` covers the FIRST question, which follows
/// no dismissal: it presents on the next runloop turn instead of
/// waiting out a settle. While an alert is live the guard
/// (`presented != nil`) keeps it from swapping data mid-presentation.
@MainActor
@Observable
final class ConfirmationAlertSequencer {
    /// The confirmation currently on screen: the alert presents from
    /// this. Nil means nothing is (or should be) up.
    private(set) var presented: AttachmentLibrary.PendingConfirmation?

    /// Reads the queue's CURRENT head — re-read at settle time, because
    /// the queue may have changed while the dismissal settled.
    var nextHead: (() -> AttachmentLibrary.PendingConfirmation?)?

    /// Grace between SwiftUI's dismissal write and the next
    /// presentation; must outlast dismissal to completion (~800 ms
    /// measured, 1.2 s covers device/load slack). Injectable so tests
    /// run without the delay.
    var settleNanoseconds: UInt64 = 1_200_000_000

    /// False only while a dismissal's settle window is running — the
    /// gate between "present promptly" (nothing was up) and "present
    /// after the window" (an alert is coming down).
    private var settledReady = true

    private var settleTask: Task<Void, Never>?

    /// A question became available (or possibly changed): present it if
    /// nothing is on screen.
    func queueMayHaveAdvanced() {
        scheduleSettledPresentation()
    }

    /// SwiftUI's dismissal write (`isPresented` → false). The only
    /// clearer of `presented`; opens a settle window before the next
    /// question may present (any further echoes restart it).
    func alertDismissed() {
        presented = nil
        settledReady = false
        scheduleSettledPresentation()
    }

    private func scheduleSettledPresentation() {
        settleTask?.cancel()
        let delay = settledReady ? 0 : settleNanoseconds
        settleTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                settledReady = true
            }
            // Re-validate at wake: an alert may have appeared from a
            // newer schedule, or the head may be gone entirely.
            guard presented == nil, let head = nextHead?() else { return }
            presented = head
        }
    }
}
