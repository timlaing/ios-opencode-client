import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W02 service tests against a canned transport: native response shapes
/// (bare arrays, direct objects, location-wrapped lists), the New Project
/// write-then-resolve sequence, and client-side folder-name validation
/// (docs/api-contract.md W02, docs/navigation-screens.md S04–S06).
final class ProjectServiceTests: XCTestCase {
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

    private func service(_ responses: [String: Result<APIResponse, TransportError>], recorder: Recorder = Recorder()) -> ProjectService {
        let transport = FakeTransport(recorder: recorder, responses: responses)
        return ProjectService(makeTransport: { _ in transport })
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    // MARK: - Inventory and resolution

    func testProjectsDecodesBareArrayResponse() async throws {
        let body = #"[{"id":"project_harbour","canonical":"/srv/demo/harbour","name":"Harbour Demo","time":{"created":1,"updated":2,"active":3}},{"id":"project_orbit","canonical":"/srv/demo/orbit","name":"Orbit Demo"}]"#
        let projects = try await service([
            "project.list": .success(json(body)),
        ]).projects(at: host, credential: credential)

        XCTAssertEqual(projects.map(\.id), ["project_harbour", "project_orbit"])
        XCTAssertEqual(projects.first?.name, "Harbour Demo")
        XCTAssertEqual(projects.first?.time?.updated, 2)
        XCTAssertNil(projects.last?.vcs, "absent optional metadata stays absent")
    }

    func testResolveLocationDecodesProjectIdentity() async throws {
        let body = #"{"directory":"/srv/demo/harbour","project":{"id":"project_harbour","directory":"/srv/demo/harbour","canonical":"/srv/demo/harbour"}}"#
        let resolved = try await service([
            "location.get": .success(json(body)),
        ]).resolveLocation(at: host, credential: credential, directory: "/srv/demo/harbour")

        XCTAssertEqual(resolved.directory, "/srv/demo/harbour")
        XCTAssertEqual(resolved.project.id, "project_harbour")
    }

    func testListDirectoryReturnsRelativeEntries() async throws {
        let recorder = Recorder()
        let body = #"{"location":{"directory":"/srv/demo/harbour"},"data":[{"path":"src","type":"directory"},{"path":"README.md","type":"file"}]}"#
        let entries = try await service([
            "fs.list": .success(json(body)),
        ], recorder: recorder).listDirectory(at: host, credential: credential, directory: "/srv/demo/harbour", path: ".")

        XCTAssertEqual(entries, [
            FileSystemEntry(path: "src", type: .directory),
            FileSystemEntry(path: "README.md", type: .file),
        ])
        XCTAssertEqual(recorder.requests.first?.operationID, "fs.list")
    }

    func testFindPassesThroughEntries() async throws {
        let body = #"{"location":{"directory":"/srv/demo"},"data":[{"path":"main.py","type":"file"}]}"#
        let entries = try await service([
            "fs.find": .success(json(body)),
        ]).find(at: host, credential: credential, directory: "/srv/demo", query: "main", type: .file)
        XCTAssertEqual(entries, [FileSystemEntry(path: "main.py", type: .file)])
    }

    // MARK: - W11 fs.read (S13 file viewer)

    func testReadFileReturnsOctetStreamBytesAndETag() async throws {
        let recorder = Recorder()
        let content = Data("# Hello\n".utf8)
        let response = APIResponse(
            statusCode: 200,
            headers: ["ETag": "\"abc123\""],
            payload: .bytes(content)
        )
        let file = try await service([
            "fs.read": .success(response),
        ], recorder: recorder).readFile(at: host, credential: credential, directory: "/srv/demo", path: "README.md")

        XCTAssertEqual(file.bytes, content, "200 is octet-stream — decoded as raw bytes, never JSON")
        XCTAssertEqual(file.etag, "\"abc123\"", "the server's ETag is surfaced for If-None-Match revalidation")

        let request = recorder.requests.first
        XCTAssertEqual(request?.operationID, "fs.read")
        XCTAssertEqual(request?.method, .get)
        XCTAssertEqual(request?.path, "/api/fs/read/README.md")
        XCTAssertEqual(request?.query, [QueryPair(key: "location[directory]", value: "/srv/demo")])
    }

    func testReadFileEscapesPathSegments() async throws {
        let recorder = Recorder()
        let response = APIResponse(statusCode: 200, payload: .bytes(Data()))
        _ = try await service([
            "fs.read": .success(response),
        ], recorder: recorder).readFile(at: host, credential: credential, directory: "/srv/demo", path: "src/my file.py")

        // `path` is stored raw; each segment is percent-encoded when the URL
        // is built, so a space can never be mistaken for a separator.
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.path, "/api/fs/read/src/my file.py")
        XCTAssertEqual(request.query, [QueryPair(key: "location[directory]", value: "/srv/demo")])
        let url = try request.url(baseURL: host).absoluteString
        XCTAssertTrue(url.contains("/api/fs/read/src/my%20file.py"), url)
    }

    func testReadFilePartial206ParsesContentRangeTotalAndKeepsETag() async throws {
        let recorder = Recorder()
        let slice = Data("alpha\nbeta".utf8)
        let response = APIResponse(
            statusCode: 206,
            headers: ["ETag": "W/\"v1\"", "Content-Range": "bytes 0-9/4096"],
            payload: .bytes(slice)
        )
        let file = try await service([
            "fs.read": .success(response),
        ], recorder: recorder).readFile(
            at: host, credential: credential,
            directory: "/srv/demo", path: "big.txt",
            range: "bytes=0-9"
        )

        XCTAssertEqual(file.bytes, slice, "the slice is the body, never re-decoded")
        XCTAssertTrue(file.isPartial, "206 means a prefix — the preview must ask for more")
        XCTAssertEqual(file.totalByteCount, 4096, "Content-Range's total is the only size a range reveals")
        XCTAssertEqual(file.etag, "W/\"v1\"", "revalidation survives partial reads")
        XCTAssertEqual(recorder.requests.first?.headers["Range"], "bytes=0-9", "the Range rides on the request")
    }

    func testReadFileWholeFile200IsCompleteWithoutContentRange() async throws {
        let response = APIResponse(
            statusCode: 200,
            headers: ["ETag": "\"abc123\""],
            payload: .bytes(Data("the whole file".utf8))
        )
        let file = try await service([
            "fs.read": .success(response),
        ]).readFile(at: host, credential: credential, directory: "/srv/demo", path: "small.txt")

        XCTAssertFalse(file.isPartial, "a 200 is the whole file even if a Range was asked for")
        XCTAssertNil(file.totalByteCount, "no Content-Range on a 200 — the payload itself is the size")
        XCTAssertEqual(file.bytes, Data("the whole file".utf8))
    }

    func testReadFileEmptyBodyIsAnEmptyFileNotAnError() async throws {
        let response = APIResponse(statusCode: 200, payload: .empty)
        let file = try await service([
            "fs.read": .success(response),
        ]).readFile(at: host, credential: credential, directory: "/srv/demo", path: "empty.txt")

        XCTAssertEqual(file.bytes, Data(), "an empty file is zero bytes, not a failure")
        XCTAssertFalse(file.isPartial)
    }

    func testTotalByteCountParserAcceptsExactAndStarFormsOnly() {
        XCTAssertEqual(ProjectService.totalByteCount(fromContentRange: "bytes 0-9/4096"), 4096)
        XCTAssertEqual(ProjectService.totalByteCount(fromContentRange: "bytes */4096"), 4096)
        XCTAssertNil(ProjectService.totalByteCount(fromContentRange: "bytes 0-9/*"),
                     "an unknown total stays unknown — never a guess")
        XCTAssertNil(ProjectService.totalByteCount(fromContentRange: "garbage"))
        XCTAssertNil(ProjectService.totalByteCount(fromContentRange: nil))
    }

    // MARK: - New Project (write then re-resolve)

    func testCreateProjectWritesConfigThenResolvesNewDirectory() async throws {
        let recorder = Recorder()
        let writeBody = #"{"location":{"directory":"/srv/demo"},"data":{"path":"/srv/demo/Telescope/opencode.jsonc"}}"#
        let resolveBody = #"{"directory":"/srv/demo/Telescope","project":{"id":"project_telescope","directory":"/srv/demo/Telescope","canonical":"/srv/demo/Telescope"}}"#
        let resolved = try await service([
            "fs.list": .success(json(#"{"location":{"directory":"/srv/demo"},"data":[]}"#)),
            "experimental.fs.write": .success(json(writeBody)),
            "location.get": .success(json(resolveBody)),
        ], recorder: recorder).createProject(at: host, credential: credential, parentDirectory: "/srv/demo", name: "  Telescope  ")

        XCTAssertEqual(resolved.project.id, "project_telescope")
        XCTAssertEqual(recorder.requests.map(\.operationID), ["fs.list", "experimental.fs.write", "location.get"],
                       "check the target first, then config, then the server-verified re-resolve")
        XCTAssertEqual(recorder.requests[0].query,
                       [QueryPair(key: "location[directory]", value: "/srv/demo"), QueryPair(key: "path", value: ".")],
                       "the check lists the parent itself")

        let write = recorder.requests[1]
        XCTAssertEqual(write.body, Data("{}".utf8), "an empty valid JSONC object")
        XCTAssertTrue(write.query.contains(QueryPair(key: "path", value: "/srv/demo/Telescope/opencode.jsonc")))
        XCTAssertEqual(recorder.requests[2].query.first,
                       QueryPair(key: "location[directory]", value: "/srv/demo/Telescope"),
                       "re-resolve uses the target directory")
    }

    func testCreateProjectRejectsInvalidNamesBeforeAnyRequest() async throws {
        let recorder = Recorder()
        let service = service([:], recorder: recorder)
        for invalid in ["", "   ", ".", "..", "a/b", "a\\b", "na\u{0007}me"] {
            do {
                _ = try await service.createProject(at: host, credential: credential, parentDirectory: "/srv/demo", name: invalid)
                XCTFail("expected rejection for \(invalid)")
            } catch let error as FolderName.ValidationError {
                XCTAssertNotNil(error)
            }
        }
        XCTAssertTrue(recorder.requests.isEmpty, "invalid names never reach the host")
    }

    func testCreateProjectAtRootKeepsSlashAsLocation() async throws {
        let recorder = Recorder()
        let writeBody = #"{"location":{"directory":"/"},"data":{"path":"/Telescope/opencode.jsonc"}}"#
        let resolveBody = #"{"directory":"/Telescope","project":{"id":"p","directory":"/Telescope","canonical":"/Telescope"}}"#
        let resolved = try await service([
            "fs.list": .success(json(#"{"location":{"directory":"/"},"data":[]}"#)),
            "experimental.fs.write": .success(json(writeBody)),
            "location.get": .success(json(resolveBody)),
        ], recorder: recorder).createProject(at: host, credential: credential, parentDirectory: "/", name: "Telescope")

        XCTAssertEqual(resolved.directory, "/Telescope")
        XCTAssertEqual(
            recorder.requests[1].query.first,
            QueryPair(key: "location[directory]", value: "/"),
            "root parent must stay \"/\", never the empty string"
        )
        XCTAssertEqual(
            recorder.requests[1].query.last,
            QueryPair(key: "path", value: "/Telescope/opencode.jsonc"),
            "no double slash when joining at the root"
        )
        XCTAssertEqual(
            recorder.requests[2].query.first,
            QueryPair(key: "location[directory]", value: "/Telescope")
        )
    }

    func testCreateProjectRejectsExistingTargetBeforeAnyWrite() async throws {
        let recorder = Recorder()
        let listBody = #"{"location":{"directory":"/srv/demo"},"data":[{"path":"Telescope","type":"directory"}]}"#
        let writeBody = #"{"location":{"directory":"/srv/demo"},"data":{"path":"/srv/demo/Telescope/opencode.jsonc"}}"#
        let service = service([
            "fs.list": .success(json(listBody)),
            "experimental.fs.write": .success(json(writeBody)), // never reached
        ], recorder: recorder)

        do {
            _ = try await service.createProject(
                at: host, credential: credential, parentDirectory: "/srv/demo", name: "  Telescope  "
            )
            XCTFail("an existing target must be rejected before any write")
        } catch let error as ProjectService.CreateProjectError {
            XCTAssertEqual(error, .alreadyExists("/srv/demo/Telescope"),
                           "the conflict names the exact target the write would have hit")
        }

        XCTAssertEqual(recorder.requests.map(\.operationID), ["fs.list"],
                       "an existing project's opencode.jsonc is never replaced with {}")
    }

    func testFolderNameAcceptsOrdinaryUnicode() throws {
        XCTAssertEqual(try FolderName.validate("  Café ünïcode  "), "Café ünïcode")
        XCTAssertEqual(try FolderName.validate("プロジェクト"), "プロジェクト")
    }
}
