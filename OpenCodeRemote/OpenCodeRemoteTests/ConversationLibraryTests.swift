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
        handler: @escaping @Sendable (APIRequest) throws -> APIResponse,
        credentials: [String: BasicCredential?] = ["host_one": BasicCredential(secret: "t")]
    ) -> ConversationLibrary {
        let stub: @Sendable () -> StubTransport = { StubTransport(recorder: recorder, handler: handler) }
        return ConversationLibrary(
            service: SessionHistoryService(makeTransport: { _ in stub() }),
            promptService: PromptService(makeTransport: { _ in stub() }),
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
}
