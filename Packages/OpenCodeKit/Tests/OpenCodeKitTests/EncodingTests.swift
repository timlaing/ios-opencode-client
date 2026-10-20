import XCTest
@testable import OpenCodeTransport

/// Contract encoding rules (docs/api-contract.md): percent-encode path segments
/// and query parameters independently; do not treat `#`, `?`, spaces, Unicode,
/// or reserved characters as syntax.
final class EncodingTests: XCTestCase {
    func testPathSegmentsAreEncodedIndependently() throws {
        let base = try XCTUnwrap(URL(string: "https://host.example:4097"))
        let request = APIRequest(
            operationID: "fs.read",
            method: .get,
            path: "/api/fs/read/src/a b.py"
        )
        XCTAssertEqual(
            try request.url(baseURL: base).absoluteString,
            "https://host.example:4097/api/fs/read/src/a%20b.py"
        )
    }

    func testSyntaxCharactersAndUnicodeArePercentEncoded() throws {
        XCTAssertEqual(PercentCoding.encode("#fragment?query"), "%23fragment%3Fquery")
        XCTAssertEqual(PercentCoding.encode("Ö"), "%C3%96")
        XCTAssertEqual(PercentCoding.encode("分解"), "%E5%88%86%E8%A7%A3")
        XCTAssertEqual(PercentCoding.encode("🚀"), "%F0%9F%9A%80")
        XCTAssertEqual(PercentCoding.encode("unreserved-._~ABC123"), "unreserved-._~ABC123")
    }

    func testPathSegmentsAreEncodedExactlyOnceNeverGuessedAsEscapes() throws {
        // A raw `%` is content, not a hint: a file literally named
        // `a%20b.txt` routes as `a%2520b.txt` — the host decodes it
        // back to the real name (api-contract.md Line 14; a heuristic
        // escape-preserving encoder would wrongly request
        // `report final.pdf` instead).
        XCTAssertEqual(
            PercentCoding.encodePath("/api/fs/read/a%20b.txt"),
            "/api/fs/read/a%2520b.txt"
        )
        let base = try XCTUnwrap(URL(string: "https://host.example"))
        let raw = APIRequest(
            operationID: "fs.read",
            method: .get,
            path: "/api/fs/read/a%20b.txt"
        )
        XCTAssertEqual(
            try raw.url(baseURL: base).absoluteString,
            "https://host.example/api/fs/read/a%2520b.txt"
        )
        // The ONE explicit pre-encoded form bypasses the encoder
        // instead of guessing from content (W15 MCP server names).
        let preEncoded = APIRequest(
            operationID: "experimental.mcp.connect",
            method: .post,
            path: "/api/experimental/mcp/org%2Fdocs/connect",
            pathIsPreEncoded: true
        )
        XCTAssertEqual(
            try preEncoded.url(baseURL: base).absoluteString,
            "https://host.example/api/experimental/mcp/org%2Fdocs/connect"
        )
    }

    func testDeepObjectLocationQueryEncoding() throws {
        let base = try XCTUnwrap(URL(string: "https://host.example:4097"))
        let request = APIRequest(
            operationID: "project.list",
            method: .get,
            path: "/api/project",
            query: [QueryPair(key: "location[directory]", value: "/abs/pro ject")]
        )
        XCTAssertEqual(
            try request.url(baseURL: base).absoluteString,
            "https://host.example:4097/api/project?location%5Bdirectory%5D=%2Fabs%2Fpro%20ject"
        )
    }

    func testReservedQueryValueCharactersAreEncoded() {
        XCTAssertEqual(QueryPair(key: "q", value: "a&b=c+d").encoded, "q=a%26b%3Dc%2Bd")
    }

    func testBasicAuthorizationHeader() {
        // opencode:mock-password — the documented mock handshake (W01).
        let credential = BasicCredential(secret: "mock-password")
        XCTAssertEqual(credential.authorizationHeaderValue, "Basic b3BlbmNvZGU6bW9jay1wYXNzd29yZA==")
    }
}
