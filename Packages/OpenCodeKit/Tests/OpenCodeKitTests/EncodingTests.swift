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

    func testEncodePathPreservesValidEscapesButStillEncodesRawContent() {
        // A pre-encoded path PARAMETER (one segment that needed
        // escaping, e.g. an MCP server name containing `/`) survives
        // as-is: idempotent per segment, never `%252F`…
        XCTAssertEqual(
            PercentCoding.encodePath("/api/experimental/mcp/org%2Fdocs/connect"),
            "/api/experimental/mcp/org%2Fdocs/connect"
        )
        XCTAssertEqual(PercentCoding.encodePath("/api/mcp/50%25off"), "/api/mcp/50%25off")
        // …raw content is still encoded exactly once…
        XCTAssertEqual(
            PercentCoding.encodePath("/a b/c?d#e"),
            "/a%20b/c%3Fd%23e"
        )
        // …and a `%` that is not a valid escape is raw content (→ %25).
        XCTAssertEqual(PercentCoding.encodePath("/100%"), "/100%25")
        XCTAssertEqual(PercentCoding.encodePath("/%zz"), "/%25zz")
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
