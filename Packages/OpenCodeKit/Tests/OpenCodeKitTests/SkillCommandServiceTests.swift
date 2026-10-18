import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W07 service tests against a canned transport: location-wrapped
/// discovery, 204-authoritative invocations, and honest failure
/// propagation (docs/api-contract.md W07).
final class SkillCommandServiceTests: XCTestCase {
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

    private func service(_ responses: [String: Result<APIResponse, TransportError>], recorder: Recorder = Recorder()) -> SkillCommandService {
        let transport = FakeTransport(recorder: recorder, responses: responses)
        return SkillCommandService(makeTransport: { _ in transport })
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    private func empty(_ status: Int = 204) -> APIResponse {
        APIResponse(statusCode: status, payload: .empty)
    }

    private let commandsJSON = #"{"location":{"directory":"/srv/demo"},"data":[{"name":"review","description":"Synthetic review command"}]}"#
    private let skillsJSON = #"{"location":{"directory":"/srv/demo"},"data":[{"id":"demo-review","name":"Demo review","path":"/srv/demo/.opencode/skills/review.md","content":"Review generated files only."}]}"#

    func testDiscoveryDecodesFromLocationWrappedResponses() async throws {
        let service = service([
            "command.list": .success(json(commandsJSON)),
            "skill.list": .success(json(skillsJSON)),
        ])

        let commands = try await service.commands(at: host, credential: credential)
        XCTAssertEqual(commands.map(\.id), ["review"])
        XCTAssertEqual(commands.first?.description, "Synthetic review command")

        let skills = try await service.skills(at: host, credential: credential)
        XCTAssertEqual(skills.map(\.id), ["demo-review"])
        XCTAssertNil(skills.first?.autoinvoke, "an absent field stays absent")
    }

    func testInvocationsAre204AuthoritativeAndPropagateFailures() async throws {
        let recorder = Recorder()
        let ok = service([
            "session.command": .success(empty()),
            "experimental.session.skill": .success(empty()),
        ], recorder: recorder)

        try await ok.invokeCommand(at: host, credential: credential, sessionID: "ses_a", name: "review", text: "")
        try await ok.activateSkill(at: host, credential: credential, sessionID: "ses_a", id: "demo-review")

        XCTAssertEqual(
            recorder.requests.map(\.operationID),
            ["session.command", "experimental.session.skill"]
        )
        XCTAssertEqual(recorder.requests.map(\.method), [.post, .post])

        let failing = service([
            "session.command": .failure(.http(status: 404, envelope: nil)),
            "experimental.session.skill": .failure(.http(status: 404, envelope: nil)),
        ])

        do {
            try await failing.invokeCommand(at: host, credential: credential, sessionID: "ses_a", name: "nope", text: "")
            XCTFail("an unknown command must surface — nothing ran")
        } catch let error as TransportError {
            guard case .http(let status, _) = error else { return XCTFail("http error expected") }
            XCTAssertEqual(status, 404)
        }

        do {
            try await failing.activateSkill(at: host, credential: credential, sessionID: "ses_a", id: "missing")
            XCTFail("an unknown skill must surface — nothing was activated")
        } catch let error as TransportError {
            guard case .http(let status, _) = error else { return XCTFail("http error expected") }
            XCTAssertEqual(status, 404)
        }
    }
}
