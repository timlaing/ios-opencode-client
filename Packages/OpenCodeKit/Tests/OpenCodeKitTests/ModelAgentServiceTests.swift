import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W06 service tests against a canned transport: location-wrapped
/// inventories, "no default" as honest absence (503 → nil), and session
/// switches that are 204-authoritative with honest failure propagation
/// (docs/api-contract.md W06).
final class ModelAgentServiceTests: XCTestCase {
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

    private func service(_ responses: [String: Result<APIResponse, TransportError>], recorder: Recorder = Recorder()) -> ModelAgentService {
        let transport = FakeTransport(recorder: recorder, responses: responses)
        return ModelAgentService(makeTransport: { _ in transport })
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    private func empty(_ status: Int = 204) -> APIResponse {
        APIResponse(statusCode: status, payload: .empty)
    }

    private let modelJSON = #"{"id":"demo-code","modelID":"demo-code","providerID":"synthetic","name":"Demo Code","capabilities":{"tools":true,"input":["text","image"],"output":["text"]},"variants":[],"time":{"released":0},"cost":[],"status":"active","enabled":true,"limit":{"context":128000,"output":8192}}"#

    private let agentJSON = #"{"id":"build","name":"Build","description":"Dev agent","mode":"primary","hidden":false}"#

    func testInventoriesDecodeFromLocationWrappedResponses() async throws {
        let models = try await service([
            "model.list": .success(json(#"{"location":{"directory":"/srv/demo"},"data":[\#(modelJSON)]}"#)),
            "agent.list": .success(json(#"{"location":{"directory":"/srv/demo"},"data":[\#(agentJSON)]}"#)),
        ])
        let agentDetail = try await service([
            "agent.get": .success(json(#"{"location":{"directory":"/srv/demo"},"data":\#(agentJSON)}"#)),
        ])

        let listedModels = try await models.models(at: host, credential: credential)
        XCTAssertEqual(listedModels.map(\.id), ["demo-code"])
        XCTAssertTrue(listedModels[0].acceptsImages)

        let listedAgents = try await models.agents(at: host, credential: credential)
        XCTAssertEqual(listedAgents.map(\.id), ["build"])
        XCTAssertTrue(listedAgents[0].isOfferedAsPrimary)

        let detail = try await agentDetail.agent(id: "build", at: host, credential: credential)
        XCTAssertEqual(detail.description, "Dev agent")
    }

    func testDefaultModelUnavailableIsAbsenceNotFailure() async throws {
        let missing = try await service([
            "model.default": .failure(.http(status: 503, envelope: nil)),
        ]).defaultModel(at: host, credential: credential)
        XCTAssertNil(missing, "503 = no default configured — honest absence, not an error")

        let present = try await service([
            "model.default": .success(json(#"{"location":{"directory":"/srv/demo"},"data":\#(modelJSON)}"#)),
        ]).defaultModel(at: host, credential: credential)
        XCTAssertEqual(present?.id, "demo-code")

        let unauthorized = service([
            "model.default": .failure(.http(status: 401, envelope: nil)),
        ])
        do {
            _ = try await unauthorized.defaultModel(at: host, credential: credential)
            XCTFail("401 must propagate — only 503 means 'no default'")
        } catch let error as TransportError {
            guard case .http(let status, _) = error else { return XCTFail("http error expected") }
            XCTAssertEqual(status, 401)
        }
    }

    func testSwitchesAre204AuthoritativeAndPropagateFailures() async throws {
        let recorder = Recorder()
        let ok = service([
            "session.switchModel": .success(empty()),
            "session.switchAgent": .success(empty()),
        ], recorder: recorder)

        try await ok.switchModel(
            at: host, credential: credential, sessionID: "ses_a",
            to: Session.ModelRef(id: "demo-code", providerID: "synthetic")
        )
        try await ok.switchAgent(at: host, credential: credential, sessionID: "ses_a", agent: "build")

        XCTAssertEqual(recorder.requests.map(\.operationID), ["session.switchModel", "session.switchAgent"])
        XCTAssertEqual(recorder.requests.map(\.method), [.post, .post])

        let failing = service([
            "session.switchModel": .failure(.http(status: 400, envelope: nil)),
        ])
        do {
            try await failing.switchModel(
                at: host, credential: credential, sessionID: "ses_a",
                to: Session.ModelRef(id: "nope", providerID: "synthetic")
            )
            XCTFail("a rejected switch must surface — local selection is never claimed first")
        } catch let error as TransportError {
            guard case .http(let status, _) = error else { return XCTFail("http error expected") }
            XCTAssertEqual(status, 400)
        }
    }
}
