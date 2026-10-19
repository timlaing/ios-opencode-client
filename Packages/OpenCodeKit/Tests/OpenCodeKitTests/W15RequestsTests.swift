import XCTest
@testable import OpenCodeTransport

/// W15 request shapes (docs/api-contract.md W14/W15): the three MCP
/// runtime-control builders (each carrying the baseline-declared
/// optional `location`), the location-wrapped inventory decode, and
/// the `Mcp.Status` object discriminant — unknown kinds keep their raw
/// string and never fail the decode (house rule for DECODED values
/// hosts may evolve).
final class W15RequestsTests: XCTestCase {
    func testBuilderRoutesAndMethods() {
        for (request, operationID, method, path) in [
            (W15Requests.mcpList(), "mcp.list", HTTPMethod.get, "/api/mcp"),
            (
                W15Requests.mcpConnect(server: "demo-docs"),
                "experimental.mcp.connect", HTTPMethod.post,
                "/api/experimental/mcp/demo-docs/connect"
            ),
            (
                W15Requests.mcpDisconnect(server: "demo-docs"),
                "experimental.mcp.disconnect", HTTPMethod.post,
                "/api/experimental/mcp/demo-docs/disconnect"
            ),
        ] {
            XCTAssertEqual(request.operationID, operationID)
            XCTAssertEqual(request.method, method)
            XCTAssertEqual(request.path, path)
            XCTAssertTrue(request.query.isEmpty, "no location asked for, no query sent")
            XCTAssertNil(request.body, "runtime controls never carry a configuration body")
        }
    }

    /// All three routes DECLARE the optional deep-object `location`
    /// in the pinned snapshot — scope them to the session's directory
    /// and send no query when unscoped.
    func testEveryBuilderScopesTheLocationWhenGiven() {
        let location = [QueryPair(key: "location[directory]", value: "/srv/demo")]
        XCTAssertEqual(W15Requests.mcpList(directory: "/srv/demo").query, location)
        XCTAssertEqual(
            W15Requests.mcpConnect(server: "demo-docs", directory: "/srv/demo").query,
            location
        )
        XCTAssertEqual(
            W15Requests.mcpDisconnect(server: "demo-docs", directory: "/srv/demo").query,
            location
        )
        XCTAssertTrue(W15Requests.mcpList().query.isEmpty)
        XCTAssertTrue(W15Requests.mcpConnect(server: "demo-docs").query.isEmpty)
        XCTAssertTrue(W15Requests.mcpDisconnect(server: "demo-docs").query.isEmpty)
    }

    private func decodeList(_ json: String) throws -> LocationEnvelope<[McpServer]> {
        try JSONDecoder().decode(LocationEnvelope.self, from: Data(json.utf8))
    }

    func testInventoryDecodesThroughTheLocationEnvelope() throws {
        let envelope = try decodeList(
            #"{"location":{"directory":"/srv/demo"},"data":[{"name":"demo-docs","status":{"status":"connected"},"integrationID":"int_1"},{"name":"demo-auth","status":{"status":"needs_auth","error":"Synthetic sign-in required"}}]}"#
        )
        XCTAssertEqual(envelope.location.directory, "/srv/demo")
        XCTAssertEqual(envelope.data.count, 2)

        let connected = envelope.data[0]
        XCTAssertEqual(connected.name, "demo-docs")
        XCTAssertEqual(connected.id, "demo-docs")
        XCTAssertEqual(connected.status.kind, .connected)
        XCTAssertTrue(connected.status.isKnown)
        XCTAssertEqual(connected.integrationID, "int_1")

        let auth = envelope.data[1]
        XCTAssertEqual(auth.status.kind, .needsAuth)
        XCTAssertEqual(auth.status.error, "Synthetic sign-in required")
        XCTAssertNil(auth.integrationID, "the integration identity stays optional")
    }

    func testFailedStatusKeepsItsErrorAndUnknownStatusStaysVisible() throws {
        let envelope = try decodeList(
            #"{"location":{"directory":"/srv/demo"},"data":[{"name":"a","status":{"status":"failed","error":"spawn ENOENT"}},{"name":"b","status":{"status":"teleported","error":"newer host"}}]}"#
        )
        XCTAssertEqual(envelope.data[0].status.kind, .failed)
        XCTAssertEqual(envelope.data[0].status.error, "spawn ENOENT")

        // A status this baseline does not enumerate keeps its row and
        // its raw string — the decode never fails, never maps it onto
        // a known kind (house rule).
        let unknown = envelope.data[1]
        XCTAssertNil(unknown.status.kind)
        XCTAssertFalse(unknown.status.isKnown)
        XCTAssertEqual(unknown.status.rawKind, "teleported")
        XCTAssertEqual(unknown.status.error, "newer host")

        // …and survives an encode round-trip verbatim.
        let encoded = try JSONEncoder().encode(envelope.data[1])
        let redecoded = try JSONDecoder().decode(McpServer.self, from: encoded)
        XCTAssertEqual(redecoded, unknown)
    }
}
