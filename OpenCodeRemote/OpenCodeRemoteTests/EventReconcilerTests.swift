import XCTest
import OpenCodeDomain
import OpenCodeTransport
@testable import OpenCodeRemote

/// W16 event reconciliation (docs/api-contract.md W16): the PURE
/// classification of every event family, and the executed actions
/// against a loaded conversation (overlay, indicator, refresh calls,
/// debounce coalescing).
@MainActor
final class EventReconcilerTests: XCTestCase {
    private enum Fixtures {
        static func response(_ body: String, status: Int = 200) -> APIResponse {
            APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
        }

        static func user(_ id: String, text: String, created: Int64) -> String {
            #"{"id":"\#(id)","type":"user","time":{"created":\#(created)},"text":"\#(text)"}"#
        }

        static let oneMessagePage =
            #"{"data":[\#(user("msg_1", text: "hello", created: 100))],"cursor":{}}"#
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [APIRequest] = []
        func record(_ request: APIRequest) {
            lock.lock(); recorded.append(request); lock.unlock()
        }
        var requests: [APIRequest] {
            lock.lock(); defer { lock.unlock() }; return recorded
        }
    }

    private struct StubTransport: OpenCodeTransport {
        var recorder: Recorder
        var handler: @Sendable (APIRequest) throws -> APIResponse
        func perform(_ request: APIRequest) async throws -> APIResponse {
            recorder.record(request)
            return try handler(request)
        }
        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private let one = OpenCodeDomain.Host(
        id: HostID(rawValue: "host_one"),
        displayName: "Mock A",
        address: URL(string: "http://host_one.local:4097")!,
        createdAt: Date(timeIntervalSince1970: 0),
        lastVersion: nil
    )

    private func loadedConversation() async -> ConversationLibrary {
        let recorder = Recorder()
        let stub: @Sendable () -> StubTransport = {
            StubTransport(recorder: recorder) { request in
                guard request.operationID == "session.message.list" else {
                    throw TransportError.connectionFailed("unstubbed \(request.operationID)")
                }
                return Fixtures.response(Fixtures.oneMessagePage)
            }
        }
        let library = ConversationLibrary(
            service: SessionHistoryService(makeTransport: { _ in stub() }),
            credentialProvider: { _ in BasicCredential(secret: "t") }
        )
        await library.open(host: one, sessionID: "ses_a")
        precondition(library.loadedSessionID == "ses_a", "harness must load the session")
        return library
    }

    private func event(_ type: String, _ data: [String: JSONValue] = [:]) -> OpenCodeEvent {
        OpenCodeEvent(id: "evt", type: type, data: .object(data))
    }

    private func classify(
        _ event: OpenCodeEvent,
        descendants: Set<String> = []
    ) -> EventReconciler.Action {
        EventReconciler.classify(
            event, openSessionID: "ses_a", descendantSessionIDs: descendants
        )
    }

    // MARK: - Classification (pure)

    func testGlobalFamiliesClassifyWithoutASession() {
        XCTAssertEqual(classify(event("server.connected")), .fullRefresh)
        XCTAssertEqual(classify(event("config.updated")), .config)
        // …and they classify with ANY open session (nil included).
        XCTAssertEqual(EventReconciler.classify(event("server.connected"), openSessionID: nil), .fullRefresh)
    }

    func testExecutionEventsClassifyByTerminality() {
        XCTAssertEqual(
            classify(event("session.execution.started", ["sessionID": .string("ses_a")])),
            .execution(sessionID: "ses_a", finished: false)
        )
        for type in ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"] {
            XCTAssertEqual(
                classify(event(type, ["sessionID": .string("ses_a")])),
                .execution(sessionID: "ses_a", finished: true),
                "\(type) ends the turn"
            )
        }
    }

    func testAnotherSessionsEventsAreIgnoredWhileS08IsOnScreen() {
        XCTAssertEqual(
            classify(event("session.execution.succeeded", ["sessionID": .string("ses_other")])),
            .ignored,
            "S03 is not visible under S08 — no speculative cross-session reads"
        )
        XCTAssertEqual(
            classify(event("session.text.delta", [
                "sessionID": .string("ses_other"), "assistantMessageID": .string("msg_a"), "delta": .string("x"),
            ])),
            .ignored
        )
    }

    func testOnlyTheDockFamiliesCrossIntoTheOpenSessionsSubtree() {
        let descendants: Set<String> = ["ses_child"]
        XCTAssertEqual(
            classify(
                event("permission.asked", [
                    "sessionID": .string("ses_child"), "requestID": .string("per_1"),
                ]),
                descendants: descendants
            ),
            .permissions(sessionID: "ses_child"),
            "a subagent's permission event reloads the open subtree's dock (its own load scope)"
        )
        XCTAssertEqual(
            classify(
                event("form.created", [
                    "sessionID": .string("ses_child"), "formID": .string("frm_1"),
                ]),
                descendants: descendants
            ),
            .forms(sessionID: "ses_child")
        )
        XCTAssertEqual(
            classify(
                event("permission.replied", [
                    "sessionID": .string("ses_child"), "requestID": .string("per_1"),
                ])
            ),
            .ignored,
            "without the subtree lookup nothing crosses sessions (tests default to none)"
        )
        XCTAssertEqual(
            classify(
                event("permission.asked", [
                    "sessionID": .string("ses_other"), "requestID": .string("per_2"),
                ]),
                descendants: descendants
            ),
            .ignored,
            "a session outside the subtree never reaches the dock"
        )
        XCTAssertEqual(
            classify(
                event("session.text.delta", [
                    "sessionID": .string("ses_child"),
                    "assistantMessageID": .string("msg_c"), "ordinal": .number(0),
                    "delta": .string("hi"),
                ]),
                descendants: descendants
            ),
            .ignored,
            "transcript/stream stays open-session — only the docks follow the subtree"
        )
        XCTAssertEqual(
            classify(
                event("session.execution.succeeded", ["sessionID": .string("ses_child")]),
                descendants: descendants
            ),
            .ignored,
            "execution is the open session's own working state (review W16 r5)"
        )
    }

    func testADescendantDockEventReloadsTheDock() async {
        let conversation = await loadedConversation()
        let calls = CallLog()
        let reconciler = self.reconciler(conversation, calls: calls)
        reconciler.descendantSessionIDs = { ["ses_child"] }

        await reconciler.handle(event("permission.asked", [
            "sessionID": .string("ses_child"), "requestID": .string("per_1"),
        ]))
        await reconciler.handle(event("form.created", [
            "sessionID": .string("ses_child"), "formID": .string("frm_1"),
        ]))

        XCTAssertEqual(
            calls.calls, ["approvals", "forms"],
            "the dock closures re-read open + descendants themselves — the event only triggers them"
        )
    }

    func testSessionScopedEventsWithoutASessionIDAreNeverGuessed() {
        XCTAssertEqual(classify(event("session.execution.started")), .ignored)
        XCTAssertEqual(classify(event("session.inbox.enqueued", ["inboxID": .string("inb_1")])), .ignored)
        XCTAssertEqual(classify(event("permission.asked", ["requestID": .string("req_1")])), .ignored)
    }

    func testTextAndReasoningPatchesCarryTheirKeysAndValues() {
        XCTAssertEqual(
            classify(event("session.text.started", [
                "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_a"), "ordinal": .number(0),
            ])),
            .stream(EventReconciler.StreamPatch(
                sessionID: "ses_a", messageID: "msg_a", ordinal: 0, kind: .text, change: .started
            ))
        )
        XCTAssertEqual(
            classify(event("session.text.delta", [
                "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_a"),
                "ordinal": .number(1), "delta": .string("Hel"),
            ])),
            .stream(EventReconciler.StreamPatch(
                sessionID: "ses_a", messageID: "msg_a", ordinal: 1, kind: .text, change: .delta("Hel")
            )),
            "the ordinal rides every patch — a message's parts are independent"
        )
        XCTAssertEqual(
            classify(event("session.text.ended", [
                "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_a"),
                "ordinal": .number(0), "text": .string("Hello."),
            ])),
            .stream(EventReconciler.StreamPatch(
                sessionID: "ses_a", messageID: "msg_a", ordinal: 0, kind: .text, change: .ended("Hello.")
            ))
        )
        XCTAssertEqual(
            classify(event("session.reasoning.delta", [
                "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_a"),
                "ordinal": .number(0), "delta": .string("hmm"),
            ])),
            .stream(EventReconciler.StreamPatch(
                sessionID: "ses_a", messageID: "msg_a", ordinal: 0, kind: .reasoning, change: .delta("hmm")
            ))
        )
    }

    func testUnkeyedTextFallsBackToTheAuthoritativeList() {
        XCTAssertEqual(
            classify(event("session.text.delta", ["sessionID": .string("ses_a"), "delta": .string("x")])),
            .transcript(sessionID: "ses_a"),
            "a delta that cannot be placed is answered by the list, never a guess"
        )
        XCTAssertEqual(
            classify(event("session.text.delta", [
                "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_a"), "delta": .string("x"),
            ])),
            .transcript(sessionID: "ses_a"),
            "without the ordinal the segment cannot be attributed — same rule, same fallback"
        )
    }

    func testStepsToolsInboxPermissionsFormsStatusCompactionAndUsage() {
        XCTAssertEqual(
            classify(event("session.step.streamed", ["sessionID": .string("ses_a")])),
            .transcript(sessionID: "ses_a")
        )
        XCTAssertEqual(
            classify(event("session.tool.success", ["sessionID": .string("ses_a")])),
            .transcript(sessionID: "ses_a")
        )
        XCTAssertEqual(
            classify(event("session.inbox.enqueued", ["sessionID": .string("ses_a")])),
            .inbox(sessionID: "ses_a")
        )
        XCTAssertEqual(
            classify(event("permission.asked", ["sessionID": .string("ses_a")])),
            .permissions(sessionID: "ses_a")
        )
        XCTAssertEqual(
            classify(event("form.created", ["sessionID": .string("ses_a")])),
            .forms(sessionID: "ses_a")
        )
        XCTAssertEqual(
            classify(event("session.compaction.completed", ["sessionID": .string("ses_a")])),
            .compaction(sessionID: "ses_a")
        )
        XCTAssertEqual(
            classify(event("session.usage.updated", ["sessionID": .string("ses_a")])),
            .usage(sessionID: "ses_a")
        )
    }

    func testStatusEventsParseTolerantly() {
        XCTAssertEqual(
            classify(event("session.status", ["sessionID": .string("ses_a"), "status": .string("idle")])),
            .status(sessionID: "ses_a", status: .idle)
        )
        XCTAssertEqual(
            classify(event("session.status", ["sessionID": .string("ses_a"), "status": .string("busy")])),
            .status(sessionID: "ses_a", status: .busy)
        )
        XCTAssertEqual(
            classify(event("session.status", [
                "sessionID": .string("ses_a"), "status": .string("retry"),
                "attempt": .number(2), "message": .string("rate limited"),
            ])),
            .status(sessionID: "ses_a", status: .retry(attempt: 2, message: "rate limited"))
        )
        XCTAssertEqual(
            classify(event("session.status", ["sessionID": .string("ses_a"), "status": .string("vibing")])),
            .ignored,
            "an unknown status keeps the indicator's current value — never guessed into idle"
        )
    }

    func testUnknownExtensionsAreToleratedNotExecuted() {
        XCTAssertEqual(classify(event("session.teleport", ["sessionID": .string("ses_a")])), .ignored)
        XCTAssertEqual(classify(event("rpc.thing.changed", ["data": .string("x")])), .ignored)
        XCTAssertEqual(classify(OpenCodeEvent(id: "evt")), .ignored, "an event without a type is nothing")
    }

    // MARK: - Executed actions

    private func reconciler(
        _ conversation: ConversationLibrary,
        nap: @escaping (UInt64) async -> Void = { _ in },
        calls: CallLog
    ) -> EventReconciler {
        let reconciler = EventReconciler(conversation: conversation, sessionID: "ses_a", nap: nap)
        reconciler.refreshTranscript = { calls.record("transcript") }
        reconciler.loadInbox = { calls.record("inbox") }
        reconciler.loadUsage = { calls.record("usage") }
        reconciler.loadApprovals = { calls.record("approvals") }
        reconciler.loadForms = { calls.record("forms") }
        reconciler.loadContext = { calls.record("context") }
        reconciler.reloadIntegrations = { calls.record("integrations") }
        return reconciler
    }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        func record(_ name: String) {
            lock.lock(); recorded.append(name); lock.unlock()
        }
        var calls: [String] {
            lock.lock(); defer { lock.unlock() }; return recorded
        }
    }

    func testStreamDeltasFeedTheOverlayWithoutAListRead() async {
        let conversation = await loadedConversation()
        let calls = CallLog()
        let reconciler = reconciler(conversation, calls: calls)

        await reconciler.handle(event("session.text.started", [
            "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_live"), "ordinal": .number(0),
        ]))
        await reconciler.handle(event("session.text.delta", [
            "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_live"),
            "ordinal": .number(0), "delta": .string("Hel"),
        ]))
        await reconciler.handle(event("session.reasoning.delta", [
            "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_live"),
            "ordinal": .number(0), "delta": .string("hmm"),
        ]))

        XCTAssertEqual(conversation.streaming["msg_live"]?.text[0]?.content, "Hel")
        XCTAssertEqual(conversation.streaming["msg_live"]?.reasoning[0]?.content, "hmm")
        XCTAssertTrue(calls.calls.isEmpty, "deltas are answered by the overlay alone — no list read per delta")

        await reconciler.handle(event("session.text.ended", [
            "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_live"),
            "ordinal": .number(0), "text": .string("Hello there."),
        ]))
        XCTAssertEqual(
            conversation.streaming["msg_live"]?.text[0]?.content, "Hello there.",
            "the full value REPLACES the deltas"
        )
        XCTAssertEqual(conversation.streaming["msg_live"]?.text[0]?.isSettled, true)
        await waitUntil { calls.calls == ["transcript"] }
    }

    func testASecondTextPartNeverMergesIntoTheSettledFirst() async {
        let conversation = await loadedConversation()
        let calls = CallLog()
        let reconciler = reconciler(conversation, calls: calls)

        // Text part 0 ends (its row's arrival is pending), then the
        // model calls a tool and streams a SECOND part into the same
        // message — the reviewer's multi-segment scenario (review W16
        // r2).
        await reconciler.handle(event("session.text.ended", [
            "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_live"),
            "ordinal": .number(0), "text": .string("First part."),
        ]))
        await reconciler.handle(event("session.text.started", [
            "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_live"), "ordinal": .number(1),
        ]))
        await reconciler.handle(event("session.text.delta", [
            "sessionID": .string("ses_a"), "assistantMessageID": .string("msg_live"),
            "ordinal": .number(1), "delta": .string("Second."),
        ]))

        let entry = conversation.streaming["msg_live"]
        XCTAssertEqual(entry?.text[0]?.content, "First part.", "part 0 keeps its own ended text")
        XCTAssertEqual(entry?.text[0]?.isSettled, true)
        XCTAssertEqual(entry?.text[1]?.content, "Second.", "part 1 accumulates separately")
        XCTAssertEqual(
            entry?.text[1]?.isSettled, false,
            "part 1's started re-opens the entry — it is live again, never prunable"
        )
        XCTAssertTrue(calls.calls.isEmpty, "still no list read: the overlay carries every part")
    }

    func testExecutionTerminalClearsOverlayAndIndicatorAndRefreshes() async {
        let conversation = await loadedConversation()
        conversation.markExecutionStarted(sessionID: "ses_a")
        conversation.applyStatus(.retry(attempt: 1, message: nil))
        conversation.applyStream(EventReconciler.StreamPatch(
            sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .delta("partial")
        ))
        XCTAssertEqual(conversation.executionStatus, .retry(attempt: 1, message: nil))

        let calls = CallLog()
        let reconciler = reconciler(conversation, calls: calls)
        await reconciler.handle(event("session.execution.interrupted", ["sessionID": .string("ses_a")]))

        XCTAssertEqual(conversation.executionStatus, .idle, "the terminal event is the authority")
        XCTAssertTrue(conversation.streaming.isEmpty, "a finished turn leaves no live tail")
        XCTAssertEqual(calls.calls, ["transcript"])
    }

    func testExecutionTerminalsHandTheRawEventToTheNotifierHook() async {
        let conversation = await loadedConversation()
        let calls = CallLog()
        let reconciler = reconciler(conversation, calls: calls)
        reconciler.onExecutionTerminal = { event in
            calls.record("terminal:\(event.type ?? "nil")")
        }

        await reconciler.handle(event("session.execution.started", ["sessionID": .string("ses_a")]))
        XCTAssertEqual(
            calls.calls, ["transcript"],
            "a START is not a banner moment — only the canonical transitions are"
        )

        await reconciler.handle(event("session.execution.failed", ["sessionID": .string("ses_a")]))
        XCTAssertEqual(
            calls.calls,
            ["transcript", "terminal:session.execution.failed", "transcript"],
            "the raw event reaches the notifier BEFORE the authoritative refresh"
        )
    }

    func testFullRefreshReFetchesEverythingAndDistrustsTheOverlay() async {
        let conversation = await loadedConversation()
        conversation.applyStream(EventReconciler.StreamPatch(
            sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .delta("stale")
        ))
        let calls = CallLog()
        let reconciler = reconciler(conversation, calls: calls)

        await reconciler.handle(event("server.connected"))

        XCTAssertTrue(conversation.streaming.isEmpty, "a (re)connect distrusts everything the dead stream accumulated")
        XCTAssertEqual(calls.calls, ["transcript", "inbox", "approvals", "forms"], "authoritative state is fetched, never replayed")
    }

    func testReconnectClearsAStaleIndicatorTheMissedTerminalLeftBehind() async {
        let conversation = await loadedConversation()
        // A retry status arrived live, then the connection dropped and
        // the terminal landed during the gap — no replay will ever
        // deliver it.
        conversation.applyStatus(.retry(attempt: 2, message: "still trying"))
        let calls = CallLog()
        let reconciler = reconciler(conversation, calls: calls)
        reconciler.readActiveSessions = {
            calls.record("active")
            return []
        }

        await reconciler.handle(event("server.connected"))

        XCTAssertEqual(calls.calls, ["transcript", "inbox", "approvals", "forms", "active"])
        XCTAssertEqual(
            conversation.executionStatus, .idle,
            "the open session's absence from the active inventory is the authoritative end of the turn"
        )
    }

    func testReconnectKeepsTheIndicatorWhileTheSessionIsStillRunning() async {
        let conversation = await loadedConversation()
        conversation.applyStatus(.busy)
        let reconciler = reconciler(conversation, calls: CallLog())
        reconciler.readActiveSessions = { ["ses_a"] }

        await reconciler.handle(event("server.connected"))

        XCTAssertEqual(conversation.executionStatus, .busy, "a still-running turn keeps its indicator")
    }

    func testReconnectKeepsTheIndicatorWhenTheActiveReadFails() async {
        let conversation = await loadedConversation()
        conversation.applyStatus(.retry(attempt: 1, message: nil))
        let reconciler = reconciler(conversation, calls: CallLog())
        reconciler.readActiveSessions = { throw TransportError.connectionFailed("dropped") }

        await reconciler.handle(event("server.connected"))

        XCTAssertEqual(
            conversation.executionStatus, .retry(attempt: 1, message: nil),
            "transport trouble is not evidence of completion — never guess idle"
        )
    }

    func testReconnectSkipsTheActiveReadWhileIdle() async {
        let conversation = await loadedConversation()
        let calls = CallLog()
        let reconciler = reconciler(conversation, calls: calls)
        reconciler.readActiveSessions = {
            calls.record("active")
            return []
        }

        await reconciler.handle(event("server.connected"))

        XCTAssertFalse(calls.calls.contains("active"), "an idle indicator is already the truth — no read needed")
    }

    func testABurstKeepsTheOriginalWindowDeadline() async {
        let conversation = await loadedConversation()
        let calls = CallLog()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let reconciler = EventReconciler(
            conversation: conversation,
            sessionID: "ses_a",
            nap: { _ in
                calls.record("nap")
                enteredContinuation.yield()
                for await _ in release { break }
            }
        )
        reconciler.refreshTranscript = { calls.record("transcript") }

        await reconciler.handle(event("session.step.streamed", ["sessionID": .string("ses_a")]))
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next() // the window is open (nap #1)

        // Frames arriving mid-window JOIN it instead of restarting it —
        // otherwise a continuous burst pushes the refresh away forever
        // and tool cards stay stale for the whole burst (review W16 r4).
        await reconciler.handle(event("session.step.streamed", ["sessionID": .string("ses_a")]))
        await reconciler.handle(event("session.tool.progress", ["sessionID": .string("ses_a")]))
        await reconciler.handle(event("session.tool.progress", ["sessionID": .string("ses_a")]))
        XCTAssertEqual(
            calls.calls.filter { $0 == "nap" }.count, 1,
            "later frames join the pending window — never restart it"
        )

        releaseContinuation.yield()
        await waitUntil { calls.calls == ["nap", "transcript"] }

        // The window closed; the next frame opens a NEW one — a burst
        // stays bounded at one refresh per window, not zero.
        await reconciler.handle(event("session.tool.progress", ["sessionID": .string("ses_a")]))
        _ = await enteredIterator.next() // nap #2
        releaseContinuation.yield()
        await waitUntil { calls.calls == ["nap", "transcript", "nap", "transcript"] }
    }

    func testDockAndInventoryFamiliesRouteToTheirReads() async {
        let conversation = await loadedConversation()
        let calls = CallLog()
        let reconciler = reconciler(conversation, calls: calls)

        await reconciler.handle(event("permission.replied", ["sessionID": .string("ses_a")]))
        await reconciler.handle(event("form.created", ["sessionID": .string("ses_a")]))
        await reconciler.handle(event("session.inbox.delivered", ["sessionID": .string("ses_a")]))
        await reconciler.handle(event("session.usage.updated", ["sessionID": .string("ses_a")]))
        await reconciler.handle(event("session.compaction.completed", ["sessionID": .string("ses_a")]))
        await reconciler.handle(event("config.updated"))

        XCTAssertEqual(calls.calls, ["approvals", "forms", "inbox", "usage", "transcript", "context", "integrations"])
    }

    func testStatusEventsSetTheIndicatorWithoutAListRead() async {
        let conversation = await loadedConversation()
        let calls = CallLog()
        let reconciler = reconciler(conversation, calls: calls)

        await reconciler.handle(event("session.status", [
            "sessionID": .string("ses_a"), "status": .string("retry"),
            "attempt": .number(3), "message": .string("still trying"),
        ]))

        XCTAssertEqual(conversation.executionStatus, .retry(attempt: 3, message: "still trying"))
        XCTAssertTrue(calls.calls.isEmpty, "the indicator reads executionStatus directly")
    }

    func testHighFrequencyFamiliesCoalesceIntoOneRefresh() async {
        let conversation = await loadedConversation()
        let calls = CallLog()
        // A real (short) nap: the trailing debounce is observable.
        let reconciler = reconciler(conversation, nap: { try? await Task.sleep(nanoseconds: $0) }, calls: calls)

        for _ in 0..<5 {
            await reconciler.handle(event("session.tool.progress", ["sessionID": .string("ses_a")]))
        }
        await waitUntil { calls.calls.count == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(calls.calls, ["transcript"], "a burst of tool frames is ONE authoritative read")
    }

    func testFlushDropsAPendingDebouncedRefresh() async {
        let conversation = await loadedConversation()
        let calls = CallLog()
        let reconciler = reconciler(conversation, nap: { try? await Task.sleep(nanoseconds: $0) }, calls: calls)

        await reconciler.handle(event("session.step.streamed", ["sessionID": .string("ses_a")]))
        reconciler.flush()

        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(calls.calls.isEmpty, "a dismissed conversation schedules no further reads")
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // Generous budget: the suite runs in parallel workers, so
        // a loaded sim can stretch any single poll loop.
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not reached in time", file: file, line: line)
    }
}
