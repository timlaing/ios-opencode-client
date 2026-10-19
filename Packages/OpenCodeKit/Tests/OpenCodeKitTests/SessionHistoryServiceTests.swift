import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W04 service tests against a canned transport: first-page defaults
/// (limit 50, newest first), cursor pages that never combine order+limit,
/// the preserved `type` filter, single-message reads, active-context
/// reads and honest error propagation (docs/api-contract.md W04).
final class SessionHistoryServiceTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [APIRequest] = []
        func record(_ request: APIRequest) { lock.lock(); recorded.append(request); lock.unlock() }
        var requests: [APIRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    private struct FakeTransport: OpenCodeTransport {
        let recorder: Recorder
        var responses: [String: Result<APIResponse, TransportError>] = [:]

        func perform(_ request: APIRequest) async throws -> APIResponse {
            recorder.record(request)
            guard let result = responses[request.operationID] else {
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
            switch result {
            case .success(let response): return response
            case .failure(let error): throw error
            }
        }

        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private let host = URL(string: "http://localhost:4097")!
    private let credential = BasicCredential(secret: "token")

    private func service(_ responses: [String: Result<APIResponse, TransportError>], recorder: Recorder = Recorder()) -> SessionHistoryService {
        let transport = FakeTransport(recorder: recorder, responses: responses)
        return SessionHistoryService(makeTransport: { _ in transport })
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    private let userJSON = #"{"id":"msg_u","type":"user","time":{"created":1000},"text":"Hello"}"#

    func testMessagesFirstPageUsesMobileDefaultsAndDecodesUnion() async throws {
        let recorder = Recorder()
        let body = #"{"data":[\#(userJSON),{"id":"msg_idle","type":"idle","time":{"created":2000},"outcome":"completed"}],"cursor":{"previous":"p1"}}"#
        let page = try await service([
            "session.message.list": .success(json(body)),
        ], recorder: recorder).messages(at: host, credential: credential, sessionID: "ses_a")

        XCTAssertEqual(page.data.map(\.id), ["msg_u", "msg_idle"])
        XCTAssertEqual(page.cursor?.previous, "p1")
        let query = Dictionary(uniqueKeysWithValues: recorder.requests[0].query.map { ($0.key, $0.value) })
        XCTAssertEqual(query["limit"], "50", "default mobile page size is 50")
        XCTAssertEqual(query["order"], "desc", "newest first by default")
    }

    func testCursorPageDropsOrderAndLimitButKeepsTypeFilter() async throws {
        let recorder = Recorder()
        let body = #"{"data":[\#(userJSON)],"cursor":{}}"#
        _ = try await service([
            "session.message.list": .success(json(body)),
        ], recorder: recorder).messages(
            at: host, credential: credential, sessionID: "ses_a",
            order: .descending, type: "assistant", cursor: "opaque-3"
        )
        let query = Dictionary(uniqueKeysWithValues: recorder.requests[0].query.map { ($0.key, $0.value) })
        XCTAssertEqual(query["cursor"], "opaque-3")
        XCTAssertEqual(query["type"], "assistant", "the first-page type filter survives paging")
        XCTAssertNil(query["order"], "cursor pages never combine cursor and order")
        XCTAssertNil(query["limit"], "cursor pages never restate the page size")
    }

    func testSingleMessageAndContextReads() async throws {
        let recorder = Recorder()
        let service = service([
            "session.message.get": .success(json(#"{"data":\#(userJSON)}"#)),
            "session.context": .success(json(#"{"data":[\#(userJSON)]}"#)),
        ], recorder: recorder)

        let message = try await service.message(at: host, credential: credential, sessionID: "ses_a", messageID: "msg_u")
        XCTAssertEqual(message.id, "msg_u")

        let context = try await service.context(at: host, credential: credential, sessionID: "ses_a")
        XCTAssertEqual(context.map(\.id), ["msg_u"])

        XCTAssertEqual(recorder.requests.map(\.operationID), ["session.message.get", "session.context"])
    }

    func testDiffRequestsTurnRangeAndDecodesFiles() async throws {
        let recorder = Recorder()
        let body = #"{"data":[{"file":"src/main.py","patch":"@@ -1 +1 @@\n-print(\"Hello\")\n+print(\"Hello, world!\")\n","additions":1,"deletions":1,"status":"modified"}]}"#
        let files = try await service([
            "session.diff": .success(json(body)),
        ], recorder: recorder).diff(
            at: host, credential: credential, sessionID: "ses_a",
            from: "msg_a", context: "3"
        )

        XCTAssertEqual(recorder.requests.map(\.operationID), ["session.diff"])
        XCTAssertEqual(recorder.requests[0].path, "/api/session/ses_a/diff")
        let query = Dictionary(
            uniqueKeysWithValues: recorder.requests[0].query.map { ($0.key, $0.value) }
        )
        XCTAssertEqual(
            query, ["from": "msg_a", "context": "3"],
            "to stays omitted so the range ends with the from turn alone"
        )
        XCTAssertEqual(files.first?.file, "src/main.py")
        XCTAssertEqual(files.first?.status, .modified)
        XCTAssertEqual(files.first?.additions, 1)
    }

    func testErrorsPropagateUnchanged() async throws {
        let service = service([
            "session.message.list": .failure(.http(status: 404, envelope: nil)),
        ])
        do {
            _ = try await service.messages(at: host, credential: credential, sessionID: "ses_gone")
            XCTFail("expected a thrown error")
        } catch let error as TransportError {
            guard case .http(let status, _) = error else {
                return XCTFail("expected http error, got \(error)")
            }
            XCTAssertEqual(status, 404)
        }
    }
}
