import XCTest
@testable import OpenCodeTransport

/// W09 request-shape tests: builder routes/operation IDs/credentials,
/// the exact reply body (nil message omitted), and permission DTO
/// decoding — required vs optional, save scope, tool source
/// (docs/api-contract.md W09, S11).
final class W09RequestsTests: XCTestCase {
    // MARK: - Builders

    func testSessionListBuilderCarriesRouteAndCredential() {
        let request = W09Requests.list(sessionID: "ses_demo_002", credential: BasicCredential(secret: "t"))
        XCTAssertEqual(request.operationID, "session.permission.list")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.path, "/api/session/ses_demo_002/permission")
        XCTAssertEqual(request.credential, BasicCredential(secret: "t"))
    }

    func testLocationWideListBuilder() {
        let request = W09Requests.listAll()
        XCTAssertEqual(request.operationID, "permission.request.list")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.path, "/api/permission/request")
        XCTAssertNil(request.credential, "callers attach their own credential")
    }

    func testGetBuilderTargetsOneRequest() {
        let request = W09Requests.get(sessionID: "ses_a", requestID: "per_b")
        XCTAssertEqual(request.operationID, "session.permission.get")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.path, "/api/session/ses_a/permission/per_b")
    }

    func testReplyBuilderPostsDecisionOnlyWhenMessageIsNil() throws {
        let request = try W09Requests.reply(
            sessionID: "ses_a", requestID: "per_b", decision: .once,
            credential: BasicCredential(secret: "t")
        )
        XCTAssertEqual(request.operationID, "session.permission.reply")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/api/session/ses_a/permission/per_b/reply")
        XCTAssertEqual(request.credential, BasicCredential(secret: "t"))
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertEqual(body, #"{"decision":"once"}"#, "no message key at all — never null")
    }

    func testReplyCarriesMessageAndAlwaysDecision() throws {
        let request = try W09Requests.reply(
            sessionID: "ses_a", requestID: "per_b", decision: .always, message: "needed for CI"
        )
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertEqual(body, #"{"decision":"always","message":"needed for CI"}"#)
    }

    func testReplyRejectCarriesMessage() throws {
        let request = try W09Requests.reply(
            sessionID: "ses_child", requestID: "per_c", decision: .reject, message: "no"
        )
        XCTAssertEqual(request.path, "/api/session/ses_child/permission/per_c/reply",
                       "linked child entries reply under their OWN owner session")
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertEqual(body, #"{"decision":"reject","message":"no"}"#)
    }

    func testDecisionRawValuesAreTheExactContract() {
        XCTAssertEqual(PermissionDecision.once.rawValue, "once")
        XCTAssertEqual(PermissionDecision.always.rawValue, "always")
        XCTAssertEqual(PermissionDecision.reject.rawValue, "reject")
        XCTAssertThrowsError(try OpenCodeAPI.decoder.decode(
            PermissionDecision.self, from: Data(#""everything""#.utf8)
        )) { error in
            XCTAssertTrue(error is DecodingError, "off-contract decisions never encode")
        }
    }

    // MARK: - DTO decoding

    func testMinimalRequestDecodesRequiredFieldsOnly() throws {
        let json = #"{"id":"per_demo","sessionID":"ses_demo_002","action":"shell","resources":["python3 -m unittest"]}"#
        let request = try OpenCodeAPI.decoder.decode(PermissionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.id, "per_demo")
        XCTAssertEqual(request.sessionID, "ses_demo_002")
        XCTAssertEqual(request.action, "shell")
        XCTAssertEqual(request.resources, ["python3 -m unittest"])
        XCTAssertNil(request.save)
        XCTAssertNil(request.message)
        XCTAssertNil(request.source)
        XCTAssertNil(request.metadata)
        XCTAssertFalse(request.offersSaveScope, "no save scope → no Always action (S11)")
    }

    func testFullRequestDecodesSaveScopeSourceAndMessage() throws {
        let json = """
        {"id":"per_demo","sessionID":"ses_demo_002","action":"shell",
         "resources":["python3 -m unittest"],"save":["python3 -m unittest*"],
         "message":"Run the generated test suite?",
         "source":{"type":"tool","messageID":"msg_1","id":"call_9"},
         "metadata":{"origin":"e2e"}}
        """
        let request = try OpenCodeAPI.decoder.decode(PermissionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.save, ["python3 -m unittest*"])
        XCTAssertTrue(request.offersSaveScope)
        XCTAssertEqual(request.message, "Run the generated test suite?")
        XCTAssertEqual(request.source, PermissionSource(type: "tool", messageID: "msg_1", id: "call_9"))
        XCTAssertTrue(request.source?.isTool ?? false)
        XCTAssertEqual(request.metadata?["origin"]?.stringValue, "e2e")
    }

    func testUnknownSourceTypeIsNotClaimedTool() {
        let source = PermissionSource(type: "mcp", messageID: "msg_1", id: "call_9")
        XCTAssertFalse(source.isTool, "a future source type is not relabelled as a tool")
    }

    func testListResponseReadsSessionAndLocatedEnvelopes() throws {
        let fixture = #"{"data":[{"id":"per_demo","sessionID":"ses_demo_002","action":"shell","resources":["python3 -m unittest"]}]}"#
        let session = try OpenCodeAPI.decoder.decode(
            PermissionListResponse.self, from: Data(fixture.utf8)
        )
        XCTAssertEqual(session.data.map(\.id), ["per_demo"])

        let locatedJSON = #"{"location":{"directory":"/srv/demo/harbour"},"data":[{"id":"per_demo","sessionID":"ses_demo_002","action":"shell","resources":["python3 -m unittest"]}]}"#
        let located = try OpenCodeAPI.decoder.decode(
            PermissionListResponse.self, from: Data(locatedJSON.utf8)
        )
        XCTAssertEqual(located.data.map(\.id), ["per_demo"],
                       "the location wrapper rides alongside data, not inside it")
    }

    func testDetailResponseWrapsOneRequest() throws {
        let json = #"{"data":{"id":"per_demo","sessionID":"ses_demo_002","action":"shell","resources":["python3 -m unittest"]}}"#
        let response = try OpenCodeAPI.decoder.decode(
            PermissionDetailResponse.self, from: Data(json.utf8)
        )
        XCTAssertEqual(response.data.id, "per_demo")
    }
}
