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
        ConversationLibrary(
            service: SessionHistoryService(makeTransport: { _ in StubTransport(recorder: recorder, handler: handler) }),
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
}
