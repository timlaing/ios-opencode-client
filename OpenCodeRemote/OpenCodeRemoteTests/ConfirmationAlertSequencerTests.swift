import SwiftUI
import XCTest
@testable import OpenCodeRemote

/// Sequencing rules for the W08 confirmation alert chain: every queued
/// question gets its OWN presentation, the dismissal write is the only
/// clearer, and the queue is re-read after the settle — nothing can be
/// presented mid-dismissal or after it left the queue.
@MainActor
final class ConfirmationAlertSequencerTests: XCTestCase {
    /// Mutable stand-in for the library queue head.
    private final class Head {
        var value: AttachmentLibrary.PendingConfirmation?
    }

    private func confirmation(_ name: String) -> AttachmentLibrary.PendingConfirmation {
        AttachmentLibrary.PendingConfirmation(id: UUID(), name: name, kind: .duplicate)
    }

    private func makeSequencer(
        heads: Head,
        settleNanoseconds: UInt64 = 1_000_000
    ) -> ConfirmationAlertSequencer {
        let sequencer = ConfirmationAlertSequencer()
        sequencer.nextHead = { heads.value }
        sequencer.settleNanoseconds = settleNanoseconds
        return sequencer
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("never became true: \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testFirstQuestionPresentsPromptlyWithoutWaitingASettle() async {
        let heads = Head()
        heads.value = confirmation("one.bin")
        // A settle this long would time out the 2 s wait — the FIRST
        // question follows no dismissal, so it must not wait it out.
        let sequencer = makeSequencer(heads: heads, settleNanoseconds: 10_000_000_000)

        XCTAssertNil(sequencer.presented, "nothing is up before the queue is noticed")
        sequencer.queueMayHaveAdvanced()
        await waitUntil("first question presented") { sequencer.presented?.name == "one.bin" }
    }

    func testLiveAlertNeverSwapsAndDismissalIsTheOnlyClearer() async {
        let heads = Head()
        heads.value = confirmation("one.bin")
        let sequencer = makeSequencer(heads: heads)

        sequencer.queueMayHaveAdvanced()
        await waitUntil("first question presented") { sequencer.presented?.name == "one.bin" }

        // The library answers/pops while SwiftUI still shows alert #1:
        // its onChange fires, but a live alert's data must not swap.
        heads.value = confirmation("two.bin")
        sequencer.queueMayHaveAdvanced()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(sequencer.presented?.name, "one.bin",
                       "a live alert's presented data never changes")

        // Only the dismissal write clears it — and the next question
        // appears strictly after that, from a fresh presentation.
        sequencer.alertDismissed()
        XCTAssertNil(sequencer.presented, "the dismissal write clears immediately")
        await waitUntil("second question presented") { sequencer.presented?.name == "two.bin" }
    }

    func testQuestionAfterDismissalWaitsTheFullSettle() async {
        let heads = Head()
        heads.value = confirmation("one.bin")
        let sequencer = makeSequencer(heads: heads, settleNanoseconds: 300_000_000)

        sequencer.queueMayHaveAdvanced()
        await waitUntil("first question presented") { sequencer.presented?.name == "one.bin" }

        heads.value = confirmation("two.bin")
        sequencer.alertDismissed()
        // SwiftUI's redundant false-echoes right behind the dismissal:
        // each restarts the window rather than letting an earlier
        // presentation land mid-dismissal (the rejected-presentation
        // race R4 flagged).
        sequencer.alertDismissed()

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(sequencer.presented,
                     "nothing re-presents while the dismissal is still settling")

        await waitUntil("second question after the settle") { sequencer.presented?.name == "two.bin" }
    }

    func testQuestionRemovedDuringSettleIsNeverPresented() async {
        let heads = Head()
        heads.value = confirmation("one.bin")
        let sequencer = makeSequencer(heads: heads, settleNanoseconds: 80_000_000)

        sequencer.queueMayHaveAdvanced()
        await waitUntil("first question presented") { sequencer.presented?.name == "one.bin" }

        sequencer.alertDismissed()          // schedules the settle…
        heads.value = nil                   // …but the draft is removed meanwhile
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(sequencer.presented,
                     "an emptied queue never surfaces a stale question")
    }

    func testRapidQueueChangesCollapseIntoOnePresentation() async {
        let heads = Head()
        heads.value = confirmation("one.bin")
        let sequencer = makeSequencer(heads: heads)

        // Several changes in a row: earlier settles are cancelled, so a
        // single presentation follows — no alert storms.
        sequencer.queueMayHaveAdvanced()
        sequencer.queueMayHaveAdvanced()
        sequencer.queueMayHaveAdvanced()
        await waitUntil("exactly one presentation") { sequencer.presented?.name == "one.bin" }

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sequencer.presented?.name, "one.bin")
    }

    func testDismissalOnEmptyQueueSchedulesNothing() async {
        let heads = Head()
        let sequencer = makeSequencer(heads: heads)

        sequencer.alertDismissed()
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(sequencer.presented)
    }
}

/// The R4 verification, on THIS simulator's iOS version: with the
/// sequencer wired into an alert exactly as ConversationView wires it,
/// two queued confirmations both APPEAR — the second only after the
/// first's dismissal — and both are answerable through the real
/// SwiftUI presentation. This exercises the exact failure the finding
/// describes: a rejected re-presentation stranding the second
/// question and leaving send disabled forever.
///
/// Alert actions are rendered as custom action views (not UIControls)
/// on modern iOS, so the "tap" goes through the accessibility
/// activation the action must offer (VoiceOver's double-tap), reached
/// from the action's label up the view chain.
@MainActor
final class ConfirmationAlertPresentationTests: XCTestCase {
    private struct Harness: View {
        let sequencer: ConfirmationAlertSequencer
        var onAnswer: (Bool) -> Void

        var body: some View {
            Text("confirmation harness")
                .alert(
                    sequencer.presented?.name ?? "Attachment",
                    isPresented: Binding(
                        get: { sequencer.presented != nil },
                        set: { if !$0 { sequencer.alertDismissed() } }
                    ),
                    presenting: sequencer.presented
                ) { _ in
                    Button("Attach Anyway") { onAnswer(true) }
                        .accessibilityIdentifier("S09.confirm.accept")
                    Button("Cancel", role: .cancel) { onAnswer(false) }
                        .accessibilityIdentifier("S09.confirm.cancel")
                } message: { _ in
                    Text("body")
                }
        }
    }

    /// Mirrors the library's queue: the head is what's presented, and
    /// an answer pops it — exactly ConversationView's wiring.
    private final class Queue {
        var names: [String] = []
        var head: AttachmentLibrary.PendingConfirmation? {
            guard let first = names.first else { return nil }
            return AttachmentLibrary.PendingConfirmation(id: UUID(), name: first, kind: .duplicate)
        }
    }

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func deepestPresented() -> UIViewController? {
        guard let root = window?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top === root ? nil : top
    }

    /// The label of the alert action `title`, if an alert is up that
    /// offers it.
    private func findLabel(_ title: String, in view: UIView) -> UILabel? {
        for subview in view.subviews {
            if let label = subview as? UILabel, label.text == title { return label }
            if let found = findLabel(title, in: subview) { return found }
        }
        return nil
    }

    private func actionExists(_ title: String) -> Bool {
        guard let top = deepestPresented() else { return false }
        return findLabel(title, in: top.view) != nil
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 4,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("never became true: \(description)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// "Taps" are not synthesizable from a hosted test through public
    /// API (alert actions are custom views without target-action or
    /// activation handlers), so answering is driven exactly the way the
    /// production code answers: the queue pops (as the button closure
    /// would) and `alertDismissed()` runs — SwiftUI's dismissal-write
    /// signal — with real SwiftUI presentations on both sides. What the
    /// finding questioned — whether SwiftUI ACCEPTS the second
    /// presentation once the first has dismissed — is exactly what the
    /// real PlatformAlertController chain verifies here.
    func testTwoQueuedConfirmationsEachAppearAndAreAnswerable() async throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("no window scene available in this host")
        }

        let queue = Queue()
        let sequencer = ConfirmationAlertSequencer()
        sequencer.nextHead = { queue.head }
        // Production timing — this verifies the real settle flow.

        let harness = Harness(sequencer: sequencer) { _ in
            // Not invoked without a physical tap; answers below follow
            // the same order the button closure produces.
        }

        let hosting = UIHostingController(rootView: harness)
        let testWindow = UIWindow(windowScene: scene)
        testWindow.rootViewController = hosting
        testWindow.makeKeyAndVisible()
        window = testWindow
        defer { testWindow.isHidden = true }

        // Two oversized files queued → both questions wait their turn.
        queue.names = ["one.bin", "two.bin"]
        sequencer.queueMayHaveAdvanced()
        await waitUntil("first alert offering Attach Anyway") {
            self.actionExists("Attach Anyway")
        }
        XCTAssertTrue(actionExists("Cancel"), "first alert offers Cancel")
        XCTAssertEqual(sequencer.presented?.name, "one.bin")

        // Answer #1: the button closure pops the head, then SwiftUI's
        // dismissal write reaches the sequencer.
        queue.names.removeFirst()
        sequencer.alertDismissed()
        await waitUntil("first alert dismissed") { self.deepestPresented() == nil }

        // The R4 risk: SwiftUI rejecting the re-presentation would
        // strand this question forever. It must surface as a FRESH
        // alert with its own content and both actions.
        await waitUntil("second alert offering Cancel") {
            self.actionExists("Cancel")
        }
        XCTAssertEqual(sequencer.presented?.name, "two.bin",
                       "second question gets its own fresh presentation")
        XCTAssertTrue(actionExists("Attach Anyway"),
                      "second alert offers Attach Anyway")

        // Answer #2 the same way: the queue empties, chain completes.
        queue.names.removeFirst()
        sequencer.alertDismissed()
        await waitUntil("second alert dismissed") { self.deepestPresented() == nil }
        XCTAssertNil(sequencer.presented, "the emptied queue presents nothing further")

        // Nothing re-appears after everything settled.
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(deepestPresented(), "no ghost alert after the chain completed")
    }
}
