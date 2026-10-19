import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W08 preparation tests against a canned transport: the web
/// inline/staging rule, honest `paths.tmp` handling, and staging through
/// `experimental.fs.write` with the host's resolved path escaped into a
/// `file:` URI (docs/api-contract.md W08).
final class AttachmentServiceTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [APIRequest] = []
        func record(_ request: APIRequest) { lock.lock(); recorded.append(request); lock.unlock() }
        var requests: [APIRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    private struct FakeTransport: OpenCodeTransport {
        let recorder: Recorder
        var responses: [String: Result<APIResponse, TransportError>] = [:]
        /// Request-driven response: builds the reply from what was actually
        /// SENT, so an assertion can compare the two. A canned fixture can
        /// drift from the request (it did: `UUID-1` vs a fresh UUID) and then
        /// proves only its own constant.
        var respond: (@Sendable (APIRequest) -> APIResponse)?

        func perform(_ request: APIRequest) async throws -> APIResponse {
            recorder.record(request)
            if let respond { return respond(request) }
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

    private func stager(
        _ responses: [String: Result<APIResponse, TransportError>] = [:],
        recorder: Recorder = Recorder(),
        respond: (@Sendable (APIRequest) -> APIResponse)? = nil
    ) -> AttachmentStager {
        AttachmentStager(makeTransport: { _ in
            FakeTransport(recorder: recorder, responses: responses, respond: respond)
        })
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    // MARK: - Routing rule

    func testInlineRuleFollowsTypeAndThreshold() {
        let limit = AttachmentRouter.inlineThresholdBytes

        XCTAssertTrue(AttachmentRouter.shouldInline(mimeType: "image/png", byteCount: 1_000))
        XCTAssertTrue(AttachmentRouter.shouldInline(mimeType: "application/pdf", byteCount: limit),
                      "exactly at the threshold is still inline")
        XCTAssertFalse(AttachmentRouter.shouldInline(mimeType: "image/png", byteCount: limit + 1),
                       "over the threshold goes to the host")
        XCTAssertFalse(AttachmentRouter.shouldInline(mimeType: "application/zip", byteCount: 10),
                       "other types always stage regardless of size")
        XCTAssertFalse(AttachmentRouter.shouldInline(mimeType: "text/plain", byteCount: 10))
        XCTAssertTrue(AttachmentRouter.shouldInline(mimeType: "IMAGE/PNG", byteCount: 10),
                      "MIME matching is case-insensitive")
    }

    func testDataURIFormat() {
        XCTAssertEqual(
            AttachmentRouter.dataURI(mimeType: "image/png", bytes: Data([0x01, 0x02])),
            "data:image/png;base64,AQI="
        )
    }

    func testFileURIEscapesEveryPathComponent() {
        XCTAssertEqual(
            AttachmentRouter.fileURI(hostAbsolutePath: "/tmp/opencode-mock/uploads/u1/a.png"),
            "file:///tmp/opencode-mock/uploads/u1/a.png"
        )
        XCTAssertEqual(
            AttachmentRouter.fileURI(hostAbsolutePath: "/tmp/my file #1 100%.png"),
            "file:///tmp/my%20file%20%231%20100%25.png",
            "spaces, # and a literal % are all percent-encoded"
        )
        XCTAssertEqual(
            AttachmentRouter.fileURI(hostAbsolutePath: "/tmp/naïve café.png"),
            "file:///tmp/na%C3%AFve%20caf%C3%A9.png",
            "non-ASCII is UTF-8 percent-encoded"
        )
    }

    // MARK: - server.info → paths.tmp

    func testTmpDirectoryDecodesFromServerInfo() async throws {
        let service = stager([
            "server.info": .success(json(#"{"version":"2.0.25","pid":0,"urls":[],"paths":{"tmp":"/tmp/opencode-mock"}}"#)),
        ])

        let tmp = try await service.tmpDirectory(at: host, credential: credential)
        XCTAssertEqual(tmp, "/tmp/opencode-mock")
    }

    func testHostWithoutPathsFailsHonestly() async throws {
        let service = stager([
            "server.info": .success(json(#"{"version":"2.0.25","pid":0,"urls":[]}"#)),
        ])

        do {
            _ = try await service.tmpDirectory(at: host, credential: credential)
            XCTFail("a host with no paths.tmp must not stage")
        } catch {
            XCTAssertEqual(error as? StagingError, .noTmpDirectory,
                           "staging is unavailable — never a guessed directory")
        }
    }

    func testServerInfoFailurePropagates() async {
        let service = stager([
            "server.info": .failure(.http(status: 401, envelope: nil)),
        ])

        do {
            _ = try await service.tmpDirectory(at: host, credential: credential)
            XCTFail("401 must propagate")
        } catch let TransportError.http(status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Staging

    func testStageWritesToUniqueUploadDirectoryAndReturnsEscapedURI() async throws {
        let recorder = Recorder()
        // The host echoes the path it was REQUESTED to write (fs.write
        // returns the resolved path): the URI assertion then compares the
        // result with what was actually sent — a canned fixture path would
        // only ever prove the fixture's own constant.
        let service = stager(recorder: recorder) { request in
            let path = request.query.first(where: { $0.key == "path" })?.value ?? ""
            let body = #"{"location":{"directory":"/tmp/opencode-mock"},"data":{"path":"\#(path)"}}"#
            return APIResponse(statusCode: 200, payload: .json(Data(body.utf8)))
        }

        let uri = try await service.stage(
            at: host,
            credential: credential,
            tmpDirectory: "/tmp/opencode-mock",
            filename: "report final.pdf",
            bytes: Data([0x25, 0x50, 0x44, 0x46])
        )

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.operationID, "experimental.fs.write")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.contentType, "application/octet-stream")
        XCTAssertEqual(request.body, Data([0x25, 0x50, 0x44, 0x46]))
        XCTAssertEqual(request.query.first(where: { $0.key == "location[directory]" })?.value,
                       "/tmp/opencode-mock", "the location is the EXISTING tmp directory")
        let path = try XCTUnwrap(request.query.first(where: { $0.key == "path" })?.value)
        XCTAssertTrue(path.hasPrefix("/tmp/opencode-mock/uploads/"),
                      "bytes land under <tmp>/uploads/<UUID>/")
        XCTAssertTrue(path.hasSuffix("/report final.pdf"), "the filename is the final path component")
        let components = path.components(separatedBy: "/")
        XCTAssertNotNil(UUID(uuidString: components[components.count - 2]),
                        "the upload directory is a fresh UUID")
        XCTAssertTrue(uri.hasSuffix("/report%20final.pdf"), "the space is escaped in the URI")
        XCTAssertEqual(uri.removingPercentEncoding, "file://\(path)",
                       "the URI identifies the path the host was asked to write — escaped, never an iOS sandbox URL")
    }

    func testStageReplacesSlashesInTheFilename() async throws {
        let recorder = Recorder()
        let service = stager(recorder: recorder) { request in
            let path = request.query.first(where: { $0.key == "path" })?.value ?? ""
            let body = #"{"location":{"directory":"/tmp/opencode-mock"},"data":{"path":"\#(path)"}}"#
            return APIResponse(statusCode: 200, payload: .json(Data(body.utf8)))
        }

        let uri = try await service.stage(
            at: host, credential: credential,
            tmpDirectory: "/tmp/opencode-mock",
            filename: "../a/b.png",
            bytes: Data([0x01])
        )
        let path = try XCTUnwrap(recorder.requests.first?.query.first(where: { $0.key == "path" })?.value)
        XCTAssertFalse(path.contains("../"), "a filename cannot climb out of the upload directory")
        XCTAssertTrue(path.hasSuffix("/.._a_b.png"), "each slash becomes an underscore in place")
        XCTAssertEqual(uri.removingPercentEncoding, "file://\(path)",
                       "the URI identifies the sanitized path the host was asked to write")
    }

    func testStageFailurePropagates() async {
        let service = stager([
            "experimental.fs.write": .failure(.http(status: 500, envelope: nil)),
        ])

        do {
            _ = try await service.stage(
                at: host, credential: credential,
                tmpDirectory: "/tmp/opencode-mock",
                filename: "a.png", bytes: Data([0x01])
            )
            XCTFail("500 must propagate as a stage failure")
        } catch let TransportError.http(status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
