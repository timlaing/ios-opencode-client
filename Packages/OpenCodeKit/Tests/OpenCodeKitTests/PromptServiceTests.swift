import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W05 service tests against a canned transport: prompt admission
/// returns the inbox item (not an answer), reconciliation source reads,
/// 204-only inbox mutations, honest 409 propagation, and interrupt
/// where `false` is an outcome (docs/api-contract.md W05).
final class PromptServiceTests: XCTestCase {
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

    private func service(_ responses: [String: Result<APIResponse, TransportError>], recorder: Recorder = Recorder()) -> PromptService {
        let transport = FakeTransport(recorder: recorder, responses: responses)
        return PromptService(makeTransport: { _ in transport })
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    private func empty(_ status: Int = 204) -> APIResponse {
        APIResponse(statusCode: status, payload: .empty)
    }

    private let admittedJSON = #"{"data":{"id":"msg_stable","sessionID":"ses_a","time":{"created":1000},"type":"user","delivery":"steer","payload":{"text":"hello"}}}"#

    func testPromptReturnsDurablyAdmittedInboxItemWithStableID() async throws {
        let recorder = Recorder()
        let item = try await service([
            "session.prompt": .success(json(admittedJSON)),
        ], recorder: recorder).prompt(
            at: host, credential: credential, sessionID: "ses_a",
            text: "hello", messageID: "msg_stable", delivery: .steer
        )
        XCTAssertEqual(item.id, "msg_stable")
        XCTAssertEqual(item.sessionID, "ses_a")
        XCTAssertNotNil(item.projectedMessage, "admission projects into the transcript by ID")

        let payload = recorder.requests[0].body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(payload?["id"] as? String, "msg_stable", "the reconcilable stable ID rides along")
        XCTAssertEqual(payload?["delivery"] as? String, "steer")
    }

    func testPromptConflictPropagatesForReconciliation() async throws {
        let service = service([
            "session.prompt": .failure(.http(status: 409, envelope: nil)),
        ])
        do {
            _ = try await service.prompt(at: host, credential: credential, sessionID: "ses_a", text: "dup")
            XCTFail("409 must surface — reconciliation decides, never blind retry")
        } catch let error as TransportError {
            guard case .http(let status, _) = error else { return XCTFail("http error expected") }
            XCTAssertEqual(status, 409)
        }
    }

    func testInboxListIsTheReconciliationSource() async throws {
        let body = #"{"data":[{"id":"msg_stable","sessionID":"ses_a","time":{"created":1000},"type":"user","delivery":"steer","payload":{"text":"hello"}}]}"#
        let items = try await service([
            "session.inbox.list": .success(json(body)),
        ]).inbox(at: host, credential: credential, sessionID: "ses_a")
        XCTAssertEqual(items.map(\.id), ["msg_stable"])
    }

    func testInboxMutationsAre204Only() async throws {
        let recorder = Recorder()
        let service = service([
            "session.inbox.update": .success(empty()),
            "session.inbox.cancel": .success(empty()),
        ], recorder: recorder)

        try await service.updateDelivery(at: host, credential: credential, sessionID: "ses_a", inboxID: "msg_1", delivery: .queue)
        try await service.cancel(at: host, credential: credential, sessionID: "ses_a", inboxID: "msg_1")

        XCTAssertEqual(recorder.requests.map(\.operationID), ["session.inbox.update", "session.inbox.cancel"])
        XCTAssertEqual(recorder.requests.map(\.method), [.patch, .delete])
    }

    func testInterruptFalseIsAnOutcomeNotAnError() async throws {
        let idle = try await service([
            "session.interrupt": .success(json(#"{"interrupted":false}"#)),
        ]).interrupt(at: host, credential: credential, sessionID: "ses_a")
        XCTAssertFalse(idle, "nothing running is an honest outcome")

        let stopped = try await service([
            "session.interrupt": .success(json(#"{"interrupted":true}"#)),
        ]).interrupt(at: host, credential: credential, sessionID: "ses_a")
        XCTAssertTrue(stopped)
    }

    func testInterruptFailurePropagates() async throws {
        let service = service([
            "session.interrupt": .failure(.http(status: 500, envelope: nil)),
        ])
        do {
            _ = try await service.interrupt(at: host, credential: credential, sessionID: "ses_a")
            XCTFail("expected a thrown error")
        } catch let error as TransportError {
            guard case .http(let status, _) = error else { return XCTFail("http error expected") }
            XCTAssertEqual(status, 500)
        }
    }
}
