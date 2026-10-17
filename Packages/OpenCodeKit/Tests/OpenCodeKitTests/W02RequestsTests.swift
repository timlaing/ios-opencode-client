import XCTest
@testable import OpenCodeTransport

/// W02 request encoding tests (docs/api-contract.md encoding rules: deep-
/// object `location[directory]`, raw bytes for the experimental write).
final class W02RequestsTests: XCTestCase {
    private let base = URL(string: "https://192.168.1.20:4096")!

    func testListProjectsIsBareArrayGet() throws {
        let request = W02Requests.listProjects(credential: BasicCredential(secret: "s"))
        XCTAssertEqual(request.operationID, "project.list")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(try request.url(baseURL: base).absoluteString, "https://192.168.1.20:4096/api/project")
        XCTAssertEqual(request.credential?.secret, "s")
    }

    func testResolveLocationUsesDeepObjectDirectoryQuery() throws {
        let request = W02Requests.resolveLocation(directory: "/srv/demo/harbour")
        let url = try request.url(baseURL: base).absoluteString
        XCTAssertEqual(
            url,
            "https://192.168.1.20:4096/api/location?location%5Bdirectory%5D=%2Fsrv%2Fdemo%2Fharbour",
            "deep-object query, never a JSON-string location"
        )
    }

    func testListDirectoryCarriesLocationAndPath() throws {
        let request = W02Requests.listDirectory(directory: "/srv/demo/harbour", path: "src")
        let url = try request.url(baseURL: base).absoluteString
        XCTAssertTrue(url.hasPrefix("https://192.168.1.20:4096/api/fs/list?"))
        XCTAssertTrue(url.contains("location%5Bdirectory%5D=%2Fsrv%2Fdemo%2Fharbour"))
        XCTAssertTrue(url.contains("path=src"))
    }

    func testFindCarriesOptionalTypeAndLimit() throws {
        let request = W02Requests.find(directory: "/srv", query: "main", type: .file, limit: 25)
        let url = try request.url(baseURL: base).absoluteString
        XCTAssertTrue(url.contains("query=main"))
        XCTAssertTrue(url.contains("type=file"))
        XCTAssertTrue(url.contains("limit=25"))
    }

    func testWriteFileIsRawOctetStream() throws {
        let request = W02Requests.writeFile(
            directory: "/srv/demo",
            path: "/srv/demo/new/opencode.jsonc",
            bytes: Data("{}".utf8),
            credential: BasicCredential(secret: "tok")
        )
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.contentType, "application/octet-stream")
        XCTAssertEqual(request.body, Data("{}".utf8))
        let url = try request.url(baseURL: base).absoluteString
        XCTAssertTrue(url.contains("path=%2Fsrv%2Fdemo%2Fnew%2Fopencode.jsonc"))
    }
}
