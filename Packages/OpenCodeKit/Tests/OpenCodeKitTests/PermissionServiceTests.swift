import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W09 approval service tests against a canned transport: list
/// reconciliation payloads, 204-authoritative replies, and the 404 →
/// `notPending` mapping that keeps “answered elsewhere” honest
/// (docs/api-contract.md W09, S11).
final class PermissionServiceTests: XCTestCase {
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

    private func service(
        _ responses: [String: Result<APIResponse, TransportError>],
        recorder: Recorder = Recorder()
    ) -> (PermissionService, Recorder) {
        (PermissionService(makeTransport: { _ in
            FakeTransport(recorder: recorder, responses: responses)
        }), recorder)
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    private func notFound(_ requestID: String) -> TransportError {
        .http(status: 404, envelope: APIErrorEnvelope(
            tag: "PermissionNotFoundError", message: "Permission not found",
            details: ["requestID": .string(requestID)]
        ))
    }

    private let sessionFixture =
        #"{"data":[{"id":"per_demo","sessionID":"ses_demo_002","action":"shell","resources":["python3 -m unittest"],"save":["python3 -m unittest*"]}]}"#

    private let detailFixture =
        #"{"data":{"id":"per_demo","sessionID":"ses_demo_002","action":"shell","resources":["python3 -m unittest"],"save":["python3 -m unittest*"]}}"#

    // MARK: - Lists

    func testSessionListDecodesAndTargetsTheOwnerSession() async throws {
        let (service, recorder) = service([
            "session.permission.list": .success(json(sessionFixture)),
        ])
        let requests = try await service.list(
            at: host, credential: credential, sessionID: "ses_demo_002"
        )
        XCTAssertEqual(requests.map(\.id), ["per_demo"])
        XCTAssertEqual(recorder.requests.first?.path, "/api/session/ses_demo_002/permission")
        XCTAssertEqual(recorder.requests.first?.operationID, "session.permission.list")
        XCTAssertEqual(recorder.requests.first?.credential, credential)
    }

    func testLocationWideListReadsTheLocatedEnvelope() async throws {
        let located = #"{"location":{"directory":"/srv/demo/harbour"},"data":[{"id":"per_c","sessionID":"ses_child","action":"read","resources":["/etc"]}]}"#
        let (service, recorder) = service([
            "permission.request.list": .success(json(located)),
        ])
        let requests = try await service.listAll(at: host, credential: credential)
        XCTAssertEqual(requests.map(\.id), ["per_c"])
        XCTAssertEqual(recorder.requests.first?.path, "/api/permission/request")
    }

    // MARK: - Single read

    func testGetReturnsTheRequest() async throws {
        let (service, _) = service([
            "session.permission.get": .success(json(detailFixture)),
        ])
        let request = try await service.get(
            at: host, credential: credential, sessionID: "ses_demo_002", requestID: "per_demo"
        )
        XCTAssertEqual(request.id, "per_demo")
        XCTAssertTrue(request.offersSaveScope)
    }

    func testGetOnAStaleRequestIsNotPending() async {
        let (service, _) = service([
            "session.permission.get": .failure(notFound("per_demo")),
        ])
        do {
            _ = try await service.get(
                at: host, credential: credential, sessionID: "ses_demo_002", requestID: "per_demo"
            )
            XCTFail("a stale 404 must never decode into a request")
        } catch {
            XCTAssertEqual(error as? PermissionService.ServiceError, .notPending(requestID: "per_demo"))
        }
    }

    // MARK: - Reply

    func testReplyIs204AuthoritativeAndRecordsTheDecision() async throws {
        let (service, recorder) = service([
            "session.permission.reply": .success(APIResponse(statusCode: 204, payload: .empty)),
        ])
        try await service.reply(
            at: host, credential: credential, sessionID: "ses_demo_002",
            requestID: "per_demo", decision: .once
        )
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/api/session/ses_demo_002/permission/per_demo/reply")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.body), as: UTF8.self),
                       #"{"decision":"once"}"#)
    }

    func testReplyToAStaleRequestIsNotPendingNotSuccess() async {
        let (service, _) = service([
            "session.permission.reply": .failure(notFound("per_demo")),
        ])
        do {
            try await service.reply(
                at: host, credential: credential, sessionID: "ses_demo_002",
                requestID: "per_demo", decision: .once
            )
            XCTFail("a stale 404 must never look like a local approval")
        } catch {
            XCTAssertEqual(error as? PermissionService.ServiceError, .notPending(requestID: "per_demo"))
        }
    }

    func testReplyToALinkedChildUsesTheOwnerSession() async throws {
        let (service, recorder) = service([
            "session.permission.reply": .success(APIResponse(statusCode: 204, payload: .empty)),
        ])
        try await service.reply(
            at: host, credential: credential, sessionID: "ses_child",
            requestID: "per_c", decision: .always, message: "CI scope"
        )
        XCTAssertEqual(recorder.requests.first?.path, "/api/session/ses_child/permission/per_c/reply")
    }
}
