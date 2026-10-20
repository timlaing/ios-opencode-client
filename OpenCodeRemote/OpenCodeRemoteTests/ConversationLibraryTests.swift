import XCTest
import OpenCodeDomain
import OpenCodeTransport
@testable import OpenCodeRemote

/// S08 transcript tests (docs/navigation-screens.md S08/S14,
/// docs/api-contract.md W04): newest-page load displayed oldest-first,
/// opaque-cursor "load older" paging that never recombines order, honest
/// bookkeeping-variant retention, active-context reads, and honest error
/// propagation.
@MainActor
final class ConversationLibraryTests: XCTestCase {
    /// Non-isolated fixtures: transport handlers run off the main actor.
    private enum Fixtures {
        static func response(_ body: String, status: Int = 200) -> APIResponse {
            APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
        }

        static let emptyPage = #"{"data":[],"cursor":{}}"#

        /// A user message (the pinned baseline's `Session.Message.User`).
        static func user(_ id: String, text: String, created: Int64) -> String {
            #"{"id":"\#(id)","type":"user","time":{"created":\#(created)},"text":"\#(text)"}"#
        }

        /// An assistant message row — the list's own row for a turn
        /// the W16 live overlay has been tracking.
        static func assistant(_ id: String, created: Int64) -> String {
            #"{"id":"\#(id)","type":"assistant","time":{"created":\#(created)},"agent":"main","model":{"id":"m","providerID":"p"},"content":[]}"#
        }

        /// A bookkeeping transition row — retained, never dropped.
        static func agentSwitched(_ id: String, agent: String, created: Int64) -> String {
            #"{"id":"\#(id)","type":"agent-switched","time":{"created":\#(created)},"agent":"\#(agent)"}"#
        }

        /// An unknown variant whose raw payload must survive.
        static func unknown(_ id: String, created: Int64) -> String {
            #"{"id":"\#(id)","type":"wave-machine","time":{"created":\#(created)},"intensity":9.5}"#
        }

        /// One history page; `order` documents the request order so tests
        /// can assert cursor pages never re-send it.
        static func page(_ messages: [String], next: String? = nil, previous: String? = nil) -> String {
            var cursor = ""
            var pairs: [String] = []
            if let next { pairs.append(#""next":"\#(next)""#) }
            if let previous { pairs.append(#""previous":"\#(previous)""#) }
            if !pairs.isEmpty { cursor = #", "cursor":{\#(pairs.joined(separator: ","))}"# }
            return #"{"data":[\#(messages.joined(separator: ","))]\#(cursor)}"#
        }

        static let contextJSON = #"{"data":[\#(user("msg_ctx", text: "context", created: 50))]}"#

        /// A `Session.Inbox.User` as session.prompt admits it.
        static func inboxUser(id: String, text: String, created: Int64, delivery: String = "steer") -> String {
            #"{"id":"\#(id)","sessionID":"ses_a","time":{"created":\#(created)},"type":"user","delivery":"\#(delivery)","payload":{"text":"\#(text)"}}"#
        }

        /// A `Session` envelope with CUMULATIVE cost/tokens (W13 usage).
        static let sessionUsage = #"{"data":{"id":"ses_a","title":"Demo","cost":1.25,"tokens":{"input":10,"output":5}}}"#

        /// The `Session.Inbox.Compaction` admission `session.compact` returns.
        static let compactionAdmission = #"{"data":{"id":"msg_compact","sessionID":"ses_a","time":{"created":900},"type":"compaction","payload":{},"delivery":"steer"}}"#

        /// An inbox listing containing the compaction admission.
        static let inboxWithCompaction = #"{"data":[{"id":"msg_compact","sessionID":"ses_a","time":{"created":900},"type":"compaction","payload":{},"delivery":"steer"}]}"#

        static func query(_ request: APIRequest) -> [String: String] {
            Dictionary(uniqueKeysWithValues: request.query.map { ($0.key, $0.value) })
        }
    }

    /// Captured-var mutation is not allowed in `@Sendable` handlers.
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

    /// A one-shot flip for handlers that must behave differently across
    /// awaited calls (`Recorder` documents why captured mutation is out).
    private final class Flip: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool {
            lock.lock(); defer { lock.unlock() }
            let wasFirst = !done
            done = true
            return wasFirst
        }
    }

    private struct StubTransport: OpenCodeTransport {
        var recorder: Recorder
        /// Async so a test can GATE a call mid-flight (order two
        /// overlapping loads without sleeps — the ApprovalLibrary
        /// pattern); sync handlers still convert.
        var handler: @Sendable (APIRequest) async throws -> APIResponse

        func perform(_ request: APIRequest) async throws -> APIResponse {
            recorder.record(request)
            return try await handler(request)
        }

        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func host(_ id: String, name: String) -> OpenCodeDomain.Host {
        OpenCodeDomain.Host(
            id: HostID(rawValue: id),
            displayName: name,
            address: URL(string: "http://\(id).local:4097")!,
            createdAt: Date(timeIntervalSince1970: 0),
            lastVersion: nil
        )
    }

    private func conversation(
        recorder: Recorder,
        handler: @escaping @Sendable (APIRequest) async throws -> APIResponse,
        credentials: [String: BasicCredential?] = ["host_one": BasicCredential(secret: "t")]
    ) -> ConversationLibrary {
        let stub: @Sendable () -> StubTransport = { StubTransport(recorder: recorder, handler: handler) }
        return ConversationLibrary(
            service: SessionHistoryService(makeTransport: { _ in stub() }),
            promptService: PromptService(makeTransport: { _ in stub() }),
            sessionService: SessionService(makeTransport: { _ in stub() }),
            credentialProvider: { id in credentials[id.rawValue] ?? nil }
        )
    }

    private let one = OpenCodeDomain.Host(
        id: HostID(rawValue: "host_one"),
        displayName: "Mock A",
        address: URL(string: "http://host_one.local:4097")!,
        createdAt: Date(timeIntervalSince1970: 0),
        lastVersion: nil
    )

    // MARK: - Opening a transcript

    func testOpenLoadsNewestPageAndDisplaysOldestFirst() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            guard request.operationID == "session.message.list" else {
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
            // Server sends NEWEST first (order=desc).
            return Fixtures.response(Fixtures.page([
                Fixtures.user("msg_2", text: "second", created: 200),
                Fixtures.user("msg_1", text: "first", created: 100),
            ], next: "cursor_older"))
        }

        await library.open(host: one, sessionID: "ses_a")

        XCTAssertNil(library.error)
        XCTAssertEqual(library.messages.map(\.id), ["msg_1", "msg_2"], "display order is oldest first")
        XCTAssertEqual(library.messages.map(\.time.created), [100, 200])
        XCTAssertTrue(library.hasMore)
        XCTAssertEqual(library.nextCursor, "cursor_older")
        XCTAssertEqual(library.loadedSessionID, "ses_a")

        let query = Fixtures.query(recorder.requests[0])
        XCTAssertEqual(query["order"], "desc", "the first page is the NEWEST")
        XCTAssertEqual(query["limit"], "50")
        XCTAssertNil(query["cursor"])
    }

    func testOpenPreservesBookkeepingAndUnknownVariants() async throws {
        let library = conversation(recorder: Recorder()) { _ in
            // First page is NEWEST first (order=desc).
            Fixtures.response(Fixtures.page([
                Fixtures.unknown("msg_x", created: 160),
                Fixtures.agentSwitched("msg_sw", agent: "plan", created: 150),
                Fixtures.user("msg_1", text: "hi", created: 100),
            ]))
        }

        await library.open(host: one, sessionID: "ses_a")

        XCTAssertEqual(library.messages.map(\.rawType), ["user", "agent-switched", "wave-machine"])
        guard let last = library.messages.last, case .unknown(let type, let raw) = last.kind else {
            return XCTFail("unknown variant must survive the decode")
        }
        XCTAssertEqual(type, "wave-machine")
        XCTAssertEqual(raw["intensity"], .number(9.5), "unknown payloads keep their raw fields")
    }

    func testOpenSurfacesHonestError() async throws {
        let library = conversation(recorder: Recorder()) { _ in
            throw TransportError.http(status: 500, envelope: nil)
        }

        await library.open(host: one, sessionID: "ses_a")

        XCTAssertTrue(library.messages.isEmpty)
        XCTAssertNotNil(library.error)
        XCTAssertFalse(library.hasMore)
        XCTAssertNil(library.loadedSessionID)
    }

    func testOpenWithoutCredentialFailsClosed() async throws {
        let library = conversation(recorder: Recorder(), handler: { _ in Fixtures.response(Fixtures.emptyPage) }, credentials: [:])

        await library.open(host: one, sessionID: "ses_a")

        XCTAssertNotNil(library.error, "no credential is an honest failure, not silent success")
        XCTAssertTrue(library.messages.isEmpty)
    }

    // MARK: - Paging and refresh

    func testLoadOlderPrependsViaCursorWithoutOrder() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            let query = Fixtures.query(request)
            if query["cursor"] == "cursor_older" {
                // The cursor page walks FURTHER back in time.
                return Fixtures.response(Fixtures.page([
                    Fixtures.user("msg_0", text: "oldest", created: 50),
                ]))
            }
            return Fixtures.response(Fixtures.page([
                Fixtures.user("msg_2", text: "second", created: 200),
                Fixtures.user("msg_1", text: "first", created: 100),
            ], next: "cursor_older"))
        }
        await library.open(host: one, sessionID: "ses_a")

        await library.loadOlder(host: one)

        XCTAssertEqual(
            library.messages.map(\.id), ["msg_0", "msg_1", "msg_2"],
            "older records prepend, display order stays oldest first"
        )
        XCTAssertFalse(library.hasMore, "exhausted cursor ends paging")
        XCTAssertNil(library.nextCursor)

        let cursorQuery = Fixtures.query(recorder.requests[1])
        XCTAssertEqual(cursorQuery["cursor"], "cursor_older", "opaque cursor passes through")
        XCTAssertNil(cursorQuery["order"], "cursor pages never recombine order")
        XCTAssertNil(cursorQuery["limit"], "cursor pages never restate the page size")
    }

    func testLoadOlderDedupesOverlappingRecords() async throws {
        let library = conversation(recorder: Recorder()) { request in
            let query = Fixtures.query(request)
            if query["cursor"] != nil {
                // Overlaps msg_1 with the already-loaded newest page.
                return Fixtures.response(Fixtures.page([
                    Fixtures.user("msg_1", text: "first", created: 100),
                    Fixtures.user("msg_0", text: "oldest", created: 50),
                ]))
            }
            return Fixtures.response(Fixtures.page([
                Fixtures.user("msg_2", text: "second", created: 200),
                Fixtures.user("msg_1", text: "first", created: 100),
            ], next: "cursor_older"))
        }
        await library.open(host: one, sessionID: "ses_a")

        await library.loadOlder(host: one)

        XCTAssertEqual(
            library.messages.map(\.id), ["msg_0", "msg_1", "msg_2"],
            "an overlapping record is never duplicated across pages"
        )
    }

    func testLoadOlderWithoutCursorIsANoOp() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { _ in
            Fixtures.response(Fixtures.page([Fixtures.user("msg_1", text: "hi", created: 100)]))
        }
        await library.open(host: one, sessionID: "ses_a")

        await library.loadOlder(host: one)

        XCTAssertEqual(recorder.requests.count, 1, "no cursor means no request is issued")
        XCTAssertEqual(library.messages.map(\.id), ["msg_1"])
    }

    func testRefreshAbsorbsNewMessagesAndDropsServerSideDeletions() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            let query = Fixtures.query(request)
            if query["cursor"] == "cursor_older" {
                return Fixtures.response(Fixtures.page([Fixtures.user("msg_0", text: "oldest", created: 50)]))
            }
            // Request 1 = open, 2 = loadOlder, 3 = refresh (page-1 again).
            if recorder.requests.count >= 3 {
                // After refresh: one newer message arrived, msg_2 was
                // deleted server-side.
                return Fixtures.response(Fixtures.page([
                    Fixtures.user("msg_3", text: "newest", created: 300),
                    Fixtures.user("msg_1", text: "first", created: 100),
                ]))
            }
            return Fixtures.response(Fixtures.page([
                Fixtures.user("msg_2", text: "second", created: 200),
                Fixtures.user("msg_1", text: "first", created: 100),
            ], next: "cursor_older"))
        }
        await library.open(host: one, sessionID: "ses_a")
        await library.loadOlder(host: one)
        XCTAssertEqual(library.messages.map(\.id), ["msg_0", "msg_1", "msg_2"])

        await library.refresh(host: one, sessionID: "ses_a")

        XCTAssertEqual(
            library.messages.map(\.id), ["msg_0", "msg_1", "msg_3"],
            "newest page absorbs arrivals, keeps older history, honours deletions"
        )
    }

    func testRefreshAfterFailedOpenRestoresPagingState() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            // Request 1 = open (fails), 2 = refresh (succeeds).
            if recorder.requests.count == 1 {
                throw TransportError.http(status: 503, envelope: nil)
            }
            return Fixtures.response(Fixtures.page([
                Fixtures.user("msg_5", text: "newest", created: 500),
                Fixtures.user("msg_4", text: "older", created: 400),
            ], next: "cursor_from_refresh"))
        }
        await library.open(host: one, sessionID: "ses_a")
        XCTAssertNotNil(library.error, "precondition: the first open failed")

        await library.refresh(host: one, sessionID: "ses_a")

        XCTAssertNil(library.error)
        XCTAssertEqual(library.messages.map(\.id), ["msg_4", "msg_5"])
        XCTAssertEqual(library.loadedSessionID, "ses_a", "refresh establishes the session it loaded")
        XCTAssertTrue(library.hasMore, "paging state comes from the replacing page")
        XCTAssertEqual(library.nextCursor, "cursor_from_refresh")
    }

    func testRefreshWithoutOverlapReplacesTranscriptAndCursor() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            let query = Fixtures.query(request)
            if query["cursor"] == "cursor_gap" {
                XCTFail("the stale cursor must not survive a wholesale replacement")
                return Fixtures.response(Fixtures.page([]))
            }
            if query["cursor"] == "cursor_fresh" {
                return Fixtures.response(Fixtures.page([
                    Fixtures.user("msg_7", text: "reached from fresh cursor", created: 700),
                ]))
            }
            // Request 1 = open (msg_1), 2 = refresh: >1 page of arrivals,
            // so NO id overlaps the loaded transcript.
            if recorder.requests.count == 1 {
                return Fixtures.response(Fixtures.page([
                    Fixtures.user("msg_1", text: "first", created: 100),
                ], next: "cursor_gap"))
            }
            return Fixtures.response(Fixtures.page([
                Fixtures.user("msg_9", text: "brand new", created: 900),
                Fixtures.user("msg_8", text: "also new", created: 800),
            ], next: "cursor_fresh"))
        }
        await library.open(host: one, sessionID: "ses_a")
        await library.refresh(host: one, sessionID: "ses_a")

        XCTAssertEqual(
            library.messages.map(\.id), ["msg_8", "msg_9"],
            "an unbridgeable gap replaces rather than splicing a hidden hole"
        )
        XCTAssertEqual(library.nextCursor, "cursor_fresh", "paging restarts from the replacing page")
        XCTAssertTrue(library.hasMore)

        await library.loadOlder(host: one)
        XCTAssertEqual(
            library.messages.map(\.id), ["msg_7", "msg_8", "msg_9"],
            "older paging walks down from the replacing page's cursor"
        )
    }

    // MARK: - Active context (S14)

    func testLoadContextFetchesMessagesSinceCompaction() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            guard request.operationID == "session.context" else {
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
            return Fixtures.response(Fixtures.contextJSON)
        }

        await library.loadContext(host: one, sessionID: "ses_a")

        XCTAssertNil(library.contextError)
        XCTAssertEqual(library.activeContext.map(\.id), ["msg_ctx"])
        XCTAssertEqual(recorder.requests.map(\.operationID), ["session.context"])
    }

    func testLoadContextSurfacesHonestError() async throws {
        let library = conversation(recorder: Recorder()) { _ in
            throw TransportError.connectionFailed("offline")
        }

        await library.loadContext(host: one, sessionID: "ses_a")

        XCTAssertNotNil(library.contextError)
        XCTAssertTrue(library.activeContext.isEmpty)
    }

    // MARK: - Sending (W05)

    func testSendAdmitsProjectsMessageAndRefreshes() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            switch request.operationID {
            case "session.prompt":
                return Fixtures.response(#"{"data":\#(Fixtures.inboxUser(id: "msg_stable", text: "hello", created: 1000))}"#)
            case "session.message.list":
                // Post-admission authoritative read: projected message is
                // now server-side; merge must not duplicate it.
                return Fixtures.response(Fixtures.page([
                    Fixtures.user("msg_stable", text: "hello", created: 1000),
                ]))
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        let admitted = await library.send(host: one, sessionID: "ses_a", text: "  hello  ")

        XCTAssertTrue(admitted)
        XCTAssertNil(library.bannerError)
        XCTAssertEqual(library.messages.map(\.id), ["msg_stable"], "admitted item projects once; refresh dedupes by ID")

        let promptRequest = try XCTUnwrap(recorder.requests.first { $0.operationID == "session.prompt" })
        let payload = promptRequest.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(
            (payload?["id"] as? String)?.hasPrefix("msg_"), true,
            "a stable reconcilable msg_ ID rides every prompt"
        )
        XCTAssertEqual(payload?["text"] as? String, "hello", "whitespace trimmed")
        XCTAssertTrue(
            recorder.requests.contains { $0.operationID == "session.message.list" },
            "admission is followed by an authoritative read"
        )
    }

    func testSendConflictReconcilesThroughInboxByStableID() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            switch request.operationID {
            case "session.prompt":
                // Already admitted (its ID exists in inbox or transcript).
                throw TransportError.http(status: 409, envelope: nil)
            case "session.inbox.list":
                // The reconciliation answer uses the SAME stable ID the
                // app sent — recovered from the recorded prompt body.
                let payload = recorder.requests.first?.body
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let stableID = (payload?["id"] as? String) ?? "msg_unknown"
                return Fixtures.response(
                    #"{"data":[\#(Fixtures.inboxUser(id: stableID, text: "hello", created: 1000))]}"#
                )
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        let admitted = await library.send(host: one, sessionID: "ses_a", text: "hello")

        XCTAssertTrue(admitted, "409 is reconciled by stable ID, never blindly retried")
        XCTAssertNil(library.bannerError)
        XCTAssertEqual(library.messages.count, 1, "the reconciled admission projects exactly once")
    }

    func testSendFailureNotReconcilableSurfacesErrorAndKeepsDraft() async throws {
        let library = conversation(recorder: Recorder()) { request in
            switch request.operationID {
            case "session.prompt":
                throw TransportError.connectionFailed("offline")
            case "session.inbox.list":
                return Fixtures.response(#"{"data":[]}"#)
            case "session.message.list":
                return Fixtures.response(Fixtures.page([]))
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        let admitted = await library.send(host: one, sessionID: "ses_a", text: "hello")

        XCTAssertFalse(admitted, "only durable admission may clear the draft")
        XCTAssertNotNil(library.bannerError, "an unreconciled failure is surfaced honestly")
        XCTAssertTrue(library.messages.isEmpty, "nothing is fabricated into the transcript")
    }

    func testSendWithoutCredentialFailsClosed() async throws {
        let library = conversation(recorder: Recorder(), handler: { _ in Fixtures.response(#"{"data":[]}"#) }, credentials: [:])

        let admitted = await library.send(host: one, sessionID: "ses_a", text: "hello")

        XCTAssertFalse(admitted)
        XCTAssertNotNil(library.bannerError)
    }

    // MARK: - Stop (W05)

    func testStopOutcomesAreHonest() async throws {
        func library(interrupted: Bool) -> ConversationLibrary {
            conversation(recorder: Recorder()) { request in
                guard request.operationID == "session.interrupt" else {
                    throw TransportError.connectionFailed("unstubbed \(request.operationID)")
                }
                return Fixtures.response(#"{"interrupted":\#(interrupted)}"#)
            }
        }

        let running = library(interrupted: true)
        await running.stop(host: one, sessionID: "ses_a")
        XCTAssertEqual(running.notice, "Stopped the active turn.")
        XCTAssertNil(running.bannerError, "a successful stop is not an error")

        let idle = library(interrupted: false)
        await idle.stop(host: one, sessionID: "ses_a")
        XCTAssertEqual(idle.notice, "Nothing was running.", "`interrupted:false` is an outcome, not a failure")
        XCTAssertNil(idle.bannerError)
    }

    // MARK: - Sending retry + projection survival (R1 regressions)

    func testRetryOfSameDraftReusesStableMessageID() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            switch request.operationID {
            case "session.prompt":
                // First attempt: admitted server-side, but the response
                // is lost. The retry must reuse the SAME stable ID.
                let promptCount = recorder.requests.filter { $0.operationID == "session.prompt" }.count
                if promptCount == 1 {
                    throw TransportError.connectionFailed("dropped after admission")
                }
                let payload = recorder.requests.first { $0.operationID == "session.prompt" }?.body
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let stableID = (payload?["id"] as? String) ?? "msg_unknown"
                return Fixtures.response(#"{"data":\#(Fixtures.inboxUser(id: stableID, text: "hello", created: 1000))}"#)
            case "session.inbox.list":
                // #1 (attempt 1 reconciliation): nothing found. #2 (prune
                // during attempt 2's refresh): the retry IS admitted.
                let listCount = recorder.requests.filter { $0.operationID == "session.inbox.list" }.count
                if listCount == 1 { return Fixtures.response(#"{"data":[]}"#) }
                let payload = recorder.requests.first { $0.operationID == "session.prompt" }?.body
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let stableID = (payload?["id"] as? String) ?? "msg_unknown"
                return Fixtures.response(#"{"data":[\#(Fixtures.inboxUser(id: stableID, text: "hello", created: 1000))]}"#)
            case "session.message.list":
                return Fixtures.response(Fixtures.page([]))
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        let first = await library.send(host: one, sessionID: "ses_a", text: "hello")
        XCTAssertFalse(first, "precondition: attempt 1 could not be reconciled")

        let retry = await library.send(host: one, sessionID: "ses_a", text: "hello")
        XCTAssertTrue(retry)

        let promptBodies = recorder.requests.filter { $0.operationID == "session.prompt" }
            .compactMap { $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        XCTAssertEqual(promptBodies.count, 2)
        XCTAssertEqual(
            promptBodies[0]["id"] as? String, promptBodies[1]["id"] as? String,
            "retrying the SAME draft reuses the stable ID so the server can 409-detect the duplicate"
        )
        XCTAssertEqual(library.messages.map(\.id).first, promptBodies[1]["id"] as? String)
    }

    func testProjectedMessageSurvivesRefreshUntilInboxNoLongerAdmitsIt() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            switch request.operationID {
            case "session.prompt":
                return Fixtures.response(#"{"data":\#(Fixtures.inboxUser(id: "msg_p", text: "pending", created: 1000))}"#)
            case "session.message.list":
                // Delivery never happens — the transcript stays empty.
                return Fixtures.response(Fixtures.page([]))
            case "session.inbox.list":
                // #1: still admitted (kept). #2: cancelled elsewhere (gone).
                let listCount = recorder.requests.filter { $0.operationID == "session.inbox.list" }.count
                let item = Fixtures.inboxUser(id: "msg_p", text: "pending", created: 1000)
                return Fixtures.response(listCount == 1 ? #"{"data":[\#(item)]}"# : #"{"data":[]}"#)
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        let admitted = await library.send(host: one, sessionID: "ses_a", text: "pending")
        XCTAssertTrue(admitted)
        XCTAssertEqual(
            library.messages.map(\.id), ["msg_p"],
            "the just-sent message survives the immediate refresh while delivery is pending"
        )

        await library.refresh(host: one, sessionID: "ses_a")
        XCTAssertTrue(
            library.messages.isEmpty,
            "a projection whose inbox item is gone (cancelled elsewhere) is dropped"
        )
    }

    func testStopFailureUsesStopSpecificWording() async throws {
        let library = conversation(recorder: Recorder()) { _ in
            throw TransportError.http(status: 500, envelope: nil)
        }

        await library.stop(host: one, sessionID: "ses_a")

        XCTAssertEqual(
            library.bannerError, "The host could not stop the turn (HTTP 500).",
            "stop failures never reuse send/draft wording"
        )
    }

    func testSessionSwitchResetsPendingIDAndProjections() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            func promptID() -> String {
                let payload = recorder.requests.last { $0.operationID == "session.prompt" }?.body
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                return (payload?["id"] as? String) ?? "msg_unknown"
            }
            switch request.operationID {
            case "session.prompt":
                // Attempt 1 loses the response; attempt 2 is admitted.
                let promptCount = recorder.requests.filter { $0.operationID == "session.prompt" }.count
                if promptCount == 1 {
                    throw TransportError.connectionFailed("dropped after admission")
                }
                return Fixtures.response(#"{"data":\#(Fixtures.inboxUser(id: promptID(), text: "hello", created: 1000))}"#)
            case "session.inbox.list":
                // Attempt-1 reconciliation cannot verify (read fails);
                // later reads admit only the CURRENT prompt's ID.
                let promptCount = recorder.requests.filter { $0.operationID == "session.prompt" }.count
                if promptCount == 1 { throw TransportError.connectionFailed("inbox unreachable") }
                return Fixtures.response(#"{"data":[\#(Fixtures.inboxUser(id: promptID(), text: "hello", created: 1000))]}"#)
            case "session.message.list":
                return Fixtures.response(Fixtures.page([]))
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        // Session A: an unreconciled failed send leaves a pending ID.
        let failed = await library.send(host: one, sessionID: "ses_a", text: "hello")
        XCTAssertFalse(failed)

        // Switch to session B: the pending ID of A must not leak.
        await library.open(host: one, sessionID: "ses_b")
        XCTAssertTrue(library.messages.isEmpty)

        let sent = await library.send(host: one, sessionID: "ses_b", text: "hello")
        XCTAssertTrue(sent)

        let promptIDs = recorder.requests.filter { $0.operationID == "session.prompt" }
            .compactMap { $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["id"] as? String }
        XCTAssertEqual(promptIDs.count, 2)
        XCTAssertNotEqual(promptIDs[0], promptIDs[1], "a different session never reuses another session's stable ID")
        XCTAssertEqual(library.messages.map(\.id), [promptIDs[1]])

        // Reopening session A must not carry session B's projection in.
        await library.open(host: one, sessionID: "ses_a")
        XCTAssertTrue(library.messages.isEmpty, "projections never cross sessions")
    }

    func testProjectionNeverRidesIntoADifferentSessionsTranscript() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            switch request.operationID {
            case "session.prompt":
                return Fixtures.response(#"{"data":\#(Fixtures.inboxUser(id: "msg_x", text: "hello", created: 1000))}"#)
            case "session.message.list":
                // The send's follow-up refresh FAILS (loadedSessionID
                // stays nil); the later open of session B succeeds.
                let count = recorder.requests.filter { $0.operationID == "session.message.list" }.count
                if count == 1 { throw TransportError.connectionFailed("refresh lost") }
                return Fixtures.response(Fixtures.page([]))
            case "session.inbox.list":
                let item = Fixtures.inboxUser(id: "msg_x", text: "hello", created: 1000)
                return Fixtures.response(#"{"data":[\#(item)]}"#)
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        // Admit into session A with NO transcript loaded yet, and the
        // follow-up refresh fails — loadedSessionID stays nil.
        let admitted = await library.send(host: one, sessionID: "ses_a", text: "hello")
        XCTAssertTrue(admitted)
        XCTAssertNotNil(library.error, "the failed refresh is surfaced honestly")

        // Opening session B must not inherit session A's projection.
        await library.open(host: one, sessionID: "ses_b")
        XCTAssertTrue(library.messages.isEmpty, "a projection never rides into another session's transcript")
    }

    func testSendIntoNotYetLoadedSessionKeepsItsProjectionThroughRefresh() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            switch request.operationID {
            case "session.prompt":
                return Fixtures.response(#"{"data":\#(Fixtures.inboxUser(id: "msg_y", text: "to B", created: 1000))}"#)
            case "session.message.list":
                // Both sessions' pages are empty — B's prompt is still
                // pending delivery in the inbox only.
                return Fixtures.response(Fixtures.page([]))
            case "session.inbox.list":
                let item = Fixtures.inboxUser(id: "msg_y", text: "to B", created: 1000)
                return Fixtures.response(#"{"data":[\#(item)]}"#)
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        // Session A is the loaded transcript.
        await library.open(host: one, sessionID: "ses_a")
        XCTAssertTrue(library.messages.isEmpty)

        // Admit into session B (not yet loaded): the projection is
        // tracked for B, and the follow-up refresh's session-switch
        // bookkeeping must discard only A's state — not B's fresh
        // projection.
        let admitted = await library.send(host: one, sessionID: "ses_b", text: "to B")
        XCTAssertTrue(admitted)
        XCTAssertEqual(
            library.messages.map(\.id), ["msg_y"],
            "the admitted prompt remains pending in session B's transcript through its first refresh"
        )
    }

    // MARK: - Inbox (S09)

    func testInboxLifecycleLoadDeliverCancel() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            switch request.operationID {
            case "session.inbox.list":
                let listCount = recorder.requests.filter { $0.operationID == "session.inbox.list" }.count
                if listCount == 1 {
                    let a = Fixtures.inboxUser(id: "msg_a", text: "first", created: 1000)
                    let b = Fixtures.inboxUser(id: "msg_b", text: "second", created: 2000, delivery: "queue")
                    return Fixtures.response(#"{"data":[\#(a),\#(b)]}"#)
                }
                // Subsequent reads reflect the server's state after the
                // 204 mutations (msg_a steered→queued, msg_b cancelled).
                return Fixtures.response(
                    #"{"data":[\#(Fixtures.inboxUser(id: "msg_a", text: "first", created: 1000, delivery: "queue"))]}"#
                )
            case "session.inbox.update", "session.inbox.cancel":
                return Fixtures.response("{}", status: 204)
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.loadInbox(host: one, sessionID: "ses_a")
        XCTAssertNil(library.inboxError)
        XCTAssertEqual(library.inboxItems.map(\.id), ["msg_a", "msg_b"])
        XCTAssertEqual(library.inboxItems.first?.delivery, .steer)

        await library.setDelivery(host: one, sessionID: "ses_a", inboxID: "msg_a", delivery: .queue)
        XCTAssertNil(library.inboxError)
        XCTAssertEqual(library.inboxItems.first?.delivery, .queue, "204 confirms the delivery change locally")

        await library.cancelInbox(host: one, sessionID: "ses_a", inboxID: "msg_b")
        XCTAssertNil(library.inboxError)
        XCTAssertEqual(
            library.inboxItems.map(\.id), ["msg_a"],
            "cancel verifies against a fresh authoritative read"
        )
        XCTAssertEqual(
            recorder.requests.map(\.operationID),
            ["session.inbox.list", "session.inbox.update", "session.inbox.cancel", "session.inbox.list"]
        )
    }

    // MARK: - W13 usage + manual compaction (S14)

    func testLoadUsageSurfacesFreshCumulativeCostAndTokens() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            guard request.operationID == "session.get" else {
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
            return Fixtures.response(Fixtures.sessionUsage)
        }

        await library.loadUsage(host: one, sessionID: "ses_a")

        XCTAssertNil(library.usageError)
        XCTAssertEqual(library.usageInfo?.cost, 1.25)
        XCTAssertEqual(library.usageInfo?.tokens, Session.TokenUsage(input: 10, output: 5))
        XCTAssertFalse(library.isLoadingUsage)
        XCTAssertEqual(recorder.requests.map(\.operationID), ["session.get"])
    }

    func testLoadUsageFailureKeepsPreviousInfoAndReportsError() async throws {
        let recorder = Recorder()
        let flip = Flip()
        let library = conversation(recorder: recorder) { request in
            guard request.operationID == "session.get" else {
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
            if flip.first() {
                return Fixtures.response(Fixtures.sessionUsage)
            }
            throw TransportError.http(status: 500, envelope: nil)
        }

        await library.loadUsage(host: one, sessionID: "ses_a")
        XCTAssertNil(library.usageError)

        await library.loadUsage(host: one, sessionID: "ses_a")
        XCTAssertEqual(library.usageError, "The host could not load usage (HTTP 500).")
        XCTAssertEqual(
            library.usageInfo?.cost, 1.25,
            "a failure never erases the last reported totals"
        )
    }

    func testLoadUsageWithoutCredentialReportsRePairAndSendsNoRequest() async {
        let recorder = Recorder()
        let library = conversation(recorder: recorder, handler: { _ in
            XCTFail("no request may be sent without a credential")
            return Fixtures.response("{}")
        }, credentials: [:])

        await library.loadUsage(host: one, sessionID: "ses_a")

        XCTAssertEqual(library.usageError, "Re-pair this host to read its usage.")
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testCompactAdmissionIsNotCompletionAndRefreshesObservableState() async throws {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            switch request.operationID {
            case "session.compact":
                return Fixtures.response(Fixtures.compactionAdmission)
            case "session.inbox.list":
                return Fixtures.response(Fixtures.inboxWithCompaction)
            case "session.context":
                return Fixtures.response(Fixtures.contextJSON)
            case "session.get":
                return Fixtures.response(Fixtures.sessionUsage)
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.compact(host: one, sessionID: "ses_a")

        XCTAssertNil(library.compactionError)
        XCTAssertFalse(library.isCompacting)
        XCTAssertEqual(library.notice, "Compaction requested — it runs at the next step boundary.")
        // The admission refreshes what is observable — the ADMITTED item
        // and fresh context/usage — while no completion claim is made
        // and the transcript is never trimmed locally.
        XCTAssertEqual(library.inboxItems.map(\.id), ["msg_compact"])
        XCTAssertEqual(library.usageInfo?.cost, 1.25)
        XCTAssertTrue(library.messages.isEmpty, "an admission derives nothing about the transcript")

        let compact = try XCTUnwrap(recorder.requests.first { $0.operationID == "session.compact" })
        XCTAssertEqual(compact.method, .post)
        XCTAssertEqual(compact.path, "/api/session/ses_a/compact")
        XCTAssertEqual(
            recorder.requests.map(\.operationID),
            ["session.compact", "session.inbox.list", "session.context", "session.get"]
        )
    }

    func testCompactFailureSurfacesErrorAndClaimsNoAdmission() async {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            guard request.operationID == "session.compact" else {
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
            throw TransportError.http(status: 500, envelope: nil)
        }

        await library.compact(host: one, sessionID: "ses_a")

        XCTAssertEqual(library.compactionError, "The host could not accept the compaction request (HTTP 500).")
        XCTAssertNil(library.notice, "a failed request claims no admission")
        XCTAssertFalse(library.isCompacting)
        XCTAssertEqual(
            recorder.requests.map(\.operationID), ["session.compact"],
            "no refresh cascade follows a failure"
        )
    }

    func testCompactWithoutCredentialIsRejected() async {
        let recorder = Recorder()
        let library = conversation(recorder: recorder, handler: { _ in
            XCTFail("no request may be sent without a credential")
            return Fixtures.response("{}")
        }, credentials: [:])

        await library.compact(host: one, sessionID: "ses_a")

        XCTAssertEqual(library.compactionError, "Re-pair this host to compact its context.")
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    // MARK: - W16 streaming overlay + execution status

    func testApplyStreamAccumulatesPerKindAndReplacesOnEnded() async {
        let library = conversation(recorder: Recorder()) { _ in
            Fixtures.response(Fixtures.emptyPage)
        }
        await library.open(host: one, sessionID: "ses_a")

        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .started))
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .delta("Hel")))
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .delta("lo")))
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .reasoning, change: .delta("hmm")))

        XCTAssertEqual(library.streaming["msg_live"]?.text[0]?.content, "Hello")
        XCTAssertEqual(library.streaming["msg_live"]?.reasoning[0]?.content, "hmm")

        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .ended("Hello there.")))

        XCTAssertEqual(
            library.streaming["msg_live"]?.text[0]?.content, "Hello there.",
            "the ended full value REPLACES the accumulated deltas"
        )
        XCTAssertEqual(library.streaming["msg_live"]?.text[0]?.isSettled, true)
    }

    func testApplyStreamKeepsPartsIndependentPerOrdinal() async {
        let library = conversation(recorder: Recorder()) { _ in
            Fixtures.response(Fixtures.emptyPage)
        }
        await library.open(host: one, sessionID: "ses_a")

        // Text part 0 ends, then a second text part starts in the
        // SAME message (text -> tool -> text, review W16 r2).
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .ended("First.")))
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 1, kind: .text, change: .delta("Second")))

        XCTAssertEqual(library.streaming["msg_live"]?.text[0]?.content, "First.", "part 0's ended text is never appended to")
        XCTAssertEqual(library.streaming["msg_live"]?.text[0]?.isSettled, true)
        XCTAssertEqual(library.streaming["msg_live"]?.text[1]?.content, "Second", "part 1 accumulates on its own key")

        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 1, kind: .text, change: .ended("Second part.")))

        XCTAssertEqual(
            library.streaming["msg_live"]?.text[0]?.content, "First.",
            "part 1's ended REPLACES only part 1 — part 0 does not vanish"
        )
        XCTAssertEqual(library.streaming["msg_live"]?.text[1]?.content, "Second part.")
        XCTAssertEqual(library.streaming["msg_live"]?.text[1]?.isSettled, true)
    }

    func testARestartedPartStreamsFromScratch() async {
        let library = conversation(recorder: Recorder()) { _ in
            Fixtures.response(Fixtures.emptyPage)
        }
        await library.open(host: one, sessionID: "ses_a")

        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .ended("Hello there.")))
        // The stream restarts the SAME part after its ended (review
        // W16 r4).
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .started))
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .delta("Hel")))

        XCTAssertEqual(
            library.streaming["msg_live"]?.text[0]?.content, "Hel",
            "a restarted part streams from the beginning — deltas never append to the previous ended value"
        )
        XCTAssertEqual(library.streaming["msg_live"]?.text[0]?.isSettled, false, "and it is live again")
    }

    func testApplyStreamNeverCrossesSessions() async {
        let library = conversation(recorder: Recorder()) { _ in
            Fixtures.response(Fixtures.emptyPage)
        }
        await library.open(host: one, sessionID: "ses_a")

        library.applyStream(.init(sessionID: "ses_other", messageID: "msg_live", ordinal: 0, kind: .text, change: .delta("x")))

        XCTAssertTrue(library.streaming.isEmpty, "another session's stream never renders under this transcript")
    }

    func testRefreshNeverPrunesALiveOverlayEntryEvenWhenTheListCarriesItsRow() async {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            guard request.operationID == "session.message.list" else {
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
            // The host returns the IN-PROGRESS row: its content is the
            // mid-turn snapshot, not the turn's final text.
            return Fixtures.response(Fixtures.page([
                Fixtures.assistant("msg_live", created: 300),
                Fixtures.user("msg_1", text: "hello", created: 100),
            ]))
        }
        await library.open(host: one, sessionID: "ses_a")
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .delta("partial")))

        await library.refresh(host: one, sessionID: "ses_a")

        XCTAssertNotNil(
            library.streaming["msg_live"],
            "a live entry survives the row's arrival — pruning against a mid-turn row would truncate the tail to the next delta, restarting per delta (review W16 r1)"
        )

        // The turn's full text arrives: only now is the entry settled
        // enough for the list to retire it.
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .ended("Hello there.")))
        await library.refresh(host: one, sessionID: "ses_a")

        XCTAssertTrue(library.streaming.isEmpty, "a SETTLED entry the list carries is retired")
        XCTAssertEqual(library.messages.map(\.id), ["msg_1", "msg_live"])
    }

    func testAPageRequestedBeforeTheSettleNeverRetiresTheEntry() async {
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let midTurn = Fixtures.response(Fixtures.page([
            Fixtures.assistant("msg_live", created: 300),
            Fixtures.user("msg_1", text: "hello", created: 100),
        ]))
        let firstCall = Flip()
        let gatedCall = Flip()
        let library = conversation(recorder: Recorder()) { request in
            guard request.operationID == "session.message.list" else {
                return Fixtures.response(Fixtures.emptyPage)
            }
            if firstCall.first() {
                // open: a transcript with a placeholder row.
                return Fixtures.response(Fixtures.page([
                    Fixtures.assistant("msg_live", created: 300),
                    Fixtures.user("msg_1", text: "hello", created: 100),
                ]))
            }
            if gatedCall.first() {
                // refresh A: REQUESTED first, lands last.
                enteredContinuation.yield()
                for await _ in release { break }
                return midTurn
            }
            // refresh B: requested after the settle.
            return Fixtures.response(Fixtures.page([
                Fixtures.assistant("msg_live", created: 300),
                Fixtures.user("msg_1", text: "hello", created: 100),
            ]))
        }

        await library.open(host: one, sessionID: "ses_a")

        let gated = Task { [one] in
            await library.refresh(host: one, sessionID: "ses_a")
        }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next() // refresh A's page request is in flight

        // The part settles NOW: refresh A's page was requested BEFORE
        // this instant, so it is the host's mid-turn row (review W16
        // r4).
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .ended("Hello there.")))

        releaseContinuation.yield()
        await gated.value

        XCTAssertNotNil(
            library.streaming["msg_live"],
            "a page requested before the settle carries the mid-turn row — it can never retire the entry"
        )

        await library.refresh(host: one, sessionID: "ses_a")

        XCTAssertNil(library.streaming["msg_live"], "the post-settle page retires it")
        XCTAssertEqual(library.messages.map(\.id), ["msg_1", "msg_live"])
    }

    func testSessionSwitchClearsTheOverlayAndWorkingState() async {
        let recorder = Recorder()
        let library = conversation(recorder: recorder) { request in
            guard request.operationID == "session.message.list" else {
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
            return Fixtures.response(Fixtures.emptyPage)
        }
        await library.open(host: one, sessionID: "ses_a")
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .delta("x")))
        library.markExecutionStarted(sessionID: "ses_a")

        await library.open(host: one, sessionID: "ses_b")

        XCTAssertTrue(library.streaming.isEmpty, "the live tail never rides into another session")
        XCTAssertEqual(library.executionStatus, .idle, "nor does the working state")
    }

    func testMarkExecutionFinishedEndsTailAndIndicator() async {
        let library = conversation(recorder: Recorder()) { _ in
            Fixtures.response(Fixtures.emptyPage)
        }
        await library.open(host: one, sessionID: "ses_a")
        library.applyStatus(.retry(attempt: 2, message: "rate limited"))
        library.applyStream(.init(sessionID: "ses_a", messageID: "msg_live", ordinal: 0, kind: .text, change: .delta("x")))

        library.markExecutionFinished()

        XCTAssertEqual(library.executionStatus, .idle, "the terminal event ends retry too")
        XCTAssertTrue(library.streaming.isEmpty)
    }

    // MARK: - Refresh supersession (review W16 r3, minor)

    func testStaleRefreshCannotOverwriteANewerOne() async {
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let stalePage = Fixtures.response(Fixtures.page([
            Fixtures.user("msg_stale", text: "stale", created: 100),
        ]))
        let freshPage = Fixtures.response(Fixtures.page([
            Fixtures.user("msg_fresh", text: "fresh", created: 200),
        ]))
        let gate = Flip()
        let library = conversation(recorder: Recorder()) { request in
            guard request.operationID == "session.message.list" else {
                return Fixtures.response(Fixtures.emptyPage)
            }
            guard gate.first() else { return freshPage }
            // Hold the FIRST refresh mid-flight with its stale payload
            // already decided; the newer refresh runs and lands while
            // it waits (no sleeps to order the two calls).
            enteredContinuation.yield()
            for await _ in release { break }
            return stalePage
        }

        let stale = Task { [one] in
            await library.refresh(host: one, sessionID: "ses_a")
        }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()
        await library.refresh(host: one, sessionID: "ses_a")
        releaseContinuation.yield()
        await stale.value

        XCTAssertEqual(
            library.messages.map(\.id), ["msg_fresh"],
            "a superseded refresh finishing late writes nothing — W16 fires refreshes from many sources and the transport orders no responses (review W16 r3)"
        )
    }
}
