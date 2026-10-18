import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W03 service tests against a canned transport: native page/envelope
/// shapes, opaque cursor pass-through, default paging, 204-only
/// mutations, active probing and honest error propagation
/// (docs/api-contract.md W03).
final class SessionServiceTests: XCTestCase {
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

    private func service(_ responses: [String: Result<APIResponse, TransportError>], recorder: Recorder = Recorder()) -> SessionService {
        let transport = FakeTransport(recorder: recorder, responses: responses)
        return SessionService(makeTransport: { _ in transport })
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    private func empty(_ status: Int = 204) -> APIResponse {
        APIResponse(statusCode: status, payload: .empty)
    }

    private func sessionJSON(_ id: String, title: String = "Session", viewed: String = "") -> String {
        #"{"id":"\#(id)","projectID":"project_harbour","title":"\#(title)","cost":0,"tokens":{"input":0,"output":0,"reasoning":0},"time":{"created":1,"updated":2\#(viewed)},"location":{"directory":"/srv/demo/harbour"}}"#
    }

    // MARK: - List and paging

    func testSessionsDecodesPageWithOpaqueCursor() async throws {
        let recorder = Recorder()
        let body = #"{"data":[\#(sessionJSON("ses_a")),\#(sessionJSON("ses_b", title: "Second"))],"cursor":{"previous":"p1","next":"n1"}}"#
        let page = try await service([
            "session.list": .success(json(body)),
        ], recorder: recorder).sessions(at: host, credential: credential, project: "project_harbour")

        XCTAssertEqual(page.data.map(\.id), ["ses_a", "ses_b"])
        XCTAssertEqual(page.cursor?.next, "n1")
        let query = Dictionary(uniqueKeysWithValues: recorder.requests[0].query.map { ($0.key, $0.value) })
        XCTAssertEqual(query["project"], "project_harbour")
        XCTAssertEqual(query["limit"], "50", "default mobile page size is 50")
        XCTAssertEqual(query["order"], "desc", "newest first by default")
    }

    func testSessionsPassesSearchAndCursorThroughOpquely() async throws {
        let recorder = Recorder()
        let body = #"{"data":[],"cursor":{}}"#
        _ = try await service([
            "session.list": .success(json(body)),
        ], recorder: recorder).sessions(
            at: host, credential: credential, directory: "/srv/demo/orbit",
            search: "deployment", limit: 200, order: .ascending, cursor: "opaque-1"
        )
        let query = Dictionary(uniqueKeysWithValues: recorder.requests[0].query.map { ($0.key, $0.value) })
        XCTAssertEqual(query["directory"], "/srv/demo/orbit")
        XCTAssertEqual(query["search"], "deployment", "server title search, not transcript search")
        XCTAssertEqual(query["limit"], "200")
        XCTAssertEqual(query["order"], "asc")
        XCTAssertEqual(query["cursor"], "opaque-1", "cursors are opaque pass-throughs")
    }

    func testSessionsPropagatesTransportFailure() async {
        let service = service(["session.list": .failure(.connectionFailed("down"))])
        do {
            _ = try await service.sessions(at: host, credential: credential)
            XCTFail("expected the failure to surface")
        } catch let TransportError.connectionFailed(message) {
            XCTAssertEqual(message, "down")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Create and read

    func testCreatePostsLocationBoundBodyAndReturnsEnvelope() async throws {
        let recorder = Recorder()
        let body = #"{"data":\#(sessionJSON("ses_new", title: "Telescope"))}"#
        let created = try await service([
            "session.create": .success(json(body)),
        ], recorder: recorder).createSession(
            at: host, credential: credential, directory: "/Telescope", title: "Telescope"
        )

        XCTAssertEqual(created.id, "ses_new")
        let request = recorder.requests[0]
        XCTAssertEqual(request.method, .post)
        let sent = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any]
        XCTAssertEqual((sent?["location"] as? [String: Any])?["directory"] as? String, "/Telescope")
        XCTAssertEqual(sent?["title"] as? String, "Telescope")
    }

    func testSessionReadReturnsFullInfo() async throws {
        let body = #"{"data":\#(sessionJSON("ses_x"))}"#
        let session = try await service([
            "session.get": .success(json(body)),
        ]).session(at: host, credential: credential, sessionID: "ses_x")
        XCTAssertEqual(session.id, "ses_x")
    }

    // MARK: - Mutations (204)

    func testRenameRemoveAndViewAreSuccessfulOnEmpty204() async throws {
        let recorder = Recorder()
        let service = service([
            "session.update": .success(empty()),
            "session.remove": .success(empty()),
            "session.view": .success(empty()),
        ], recorder: recorder)

        try await service.rename(at: host, credential: credential, sessionID: "ses_1", title: "Renamed")
        try await service.remove(at: host, credential: credential, sessionID: "ses_1")
        try await service.markViewed(
            at: host, credential: credential, sessionID: "ses_1", observedIdleEpoch: 42
        )

        XCTAssertEqual(recorder.requests.map(\.operationID), ["session.update", "session.remove", "session.view"])
        XCTAssertEqual(recorder.requests.map(\.method), [.patch, .delete, .post])
        let viewBody = try JSONSerialization.jsonObject(with: try XCTUnwrap(recorder.requests[2].body)) as? [String: Any]
        XCTAssertEqual(viewBody?["idle"] as? Int64 ?? (viewBody?["idle"] as? NSNumber)?.int64Value, Int64(42))
    }

    func testFailedDeleteSurfacesHTTPStatusInsteadOfSucceeding() async {
        let service = service(["session.remove": .failure(.http(status: 500, envelope: nil))])
        do {
            try await service.remove(at: host, credential: credential, sessionID: "ses_1")
            XCTFail("a failed delete must not read as success")
        } catch let TransportError.http(status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Active probing

    func testActiveSessionIDsDecodesRunningSet() async throws {
        let body = #"{"data":{"ses_a":{"type":"running"},"ses_b":{"type":"running"}}}"#
        let active = try await service([
            "session.active": .success(json(body)),
        ]).activeSessionIDs(at: host, credential: credential)
        XCTAssertEqual(active, ["ses_a", "ses_b"])

        let idle = try await service([
            "session.active": .success(json(#"{"data":{}}"#)),
        ]).activeSessionIDs(at: host, credential: credential)
        XCTAssertEqual(idle, [], "absence means not actively drained, not proof of completion")
    }
}
