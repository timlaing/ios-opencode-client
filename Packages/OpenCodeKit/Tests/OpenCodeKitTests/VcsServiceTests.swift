import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W12 service tests against a canned transport: the four location-
/// wrapped VCS reads, the nullable review base (nil = a distinct state,
/// not a failure), and honest error propagation.
final class VcsServiceTests: XCTestCase {
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
    ) -> VcsService {
        let transport = FakeTransport(recorder: recorder, responses: responses)
        return VcsService(makeTransport: { _ in transport })
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    func testInfoStatusAndDiffAdoptLocationWrappedData() async throws {
        let recorder = Recorder()
        let infoBody = #"{"location":{"directory":"/srv/demo"},"data":{"provider":"git","branch":{"current":"feature","default":"main"}}}"#
        let statusBody = #"{"location":{"directory":"/srv/demo"},"data":[{"file":"a.txt","additions":2,"deletions":0,"status":"added"}]}"#
        let diffBody = #"{"location":{"directory":"/srv/demo"},"data":[{"file":"a.txt","patch":"+a\n+b\n","additions":2,"deletions":0,"status":"added"}]}"#
        let service = service([
            "vcs.get": .success(json(infoBody)),
            "vcs.status": .success(json(statusBody)),
            "vcs.diff": .success(json(diffBody)),
        ], recorder: recorder)

        let info = try await service.info(at: host, credential: credential, directory: "/srv/demo")
        let status = try await service.status(at: host, credential: credential, directory: "/srv/demo")
        let diff = try await service.diff(
            at: host, credential: credential, directory: "/srv/demo", mode: .working
        )

        XCTAssertEqual(info.branch.current, "feature")
        XCTAssertEqual(info.branch.defaultBranch, "main")
        XCTAssertEqual(status, [
            Vcs.FileStatus(file: "a.txt", additions: 2, deletions: 0, status: .added),
        ])
        XCTAssertEqual(diff.first?.patch, "+a\n+b\n")
        XCTAssertEqual(
            recorder.requests.map(\.operationID), ["vcs.get", "vcs.status", "vcs.diff"]
        )
    }

    func testBaseDecodesHostNullAsNilWithoutError() async throws {
        let body = #"{"location":{"directory":"/srv/demo"},"data":null}"#
        let base = try await service([
            "vcs.base": .success(json(body)),
        ]).base(at: host, credential: credential, directory: "/srv/demo")

        XCTAssertNil(
            base,
            "a base-less repository answers nil — a distinct state, never an error"
        )
    }

    func testErrorsPropagateUnchanged() async {
        do {
            _ = try await service([
                "vcs.diff": .failure(.http(status: 503, envelope: nil)),
            ]).diff(at: host, credential: credential, directory: "/srv/demo", mode: .branch)
            XCTFail("expected the host's 503 to propagate")
        } catch let error as TransportError {
            XCTAssertEqual(error, .http(status: 503, envelope: nil))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
