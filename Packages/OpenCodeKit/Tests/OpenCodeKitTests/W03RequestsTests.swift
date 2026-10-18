import XCTest
@testable import OpenCodeTransport

/// W03 request-shaping tests: deep query pairs for `session.list`, exact
/// JSON bodies for create/rename/view, path interpolation for
/// `/api/session/{id}`, and the Session decode/`isUnread` rules
/// (docs/api-contract.md W03).
final class W03RequestsTests: XCTestCase {
    private func query(_ request: APIRequest) -> [String: String] {
        var out: [String: String] = [:]
        for pair in request.query { out[pair.key] = pair.value }
        return out
    }

    private func bodyJSON(_ request: APIRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - session.list

    func testListEncodesEveryProvidedFilterAsIndividualQueryPairs() {
        let request = W03Requests.listSessions(
            directory: "/srv/demo/harbour",
            project: "project_harbour",
            search: "deploy target",
            parentID: "null",
            limit: 25,
            order: .ascending,
            cursor: "abc123",
            credential: BasicCredential(secret: "t")
        )
        XCTAssertEqual(request.path, "/api/session")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.operationID, "session.list")
        let query = query(request)
        XCTAssertEqual(query["directory"], "/srv/demo/harbour")
        XCTAssertEqual(query["project"], "project_harbour")
        XCTAssertEqual(query["search"], "deploy target")
        XCTAssertEqual(query["parentID"], "null", "literal null selects root sessions")
        XCTAssertEqual(query["limit"], "25")
        XCTAssertEqual(query["order"], "asc")
        XCTAssertEqual(query["cursor"], "abc123")
    }

    func testListOmitsAbsentFiltersEntirely() {
        let request = W03Requests.listSessions()
        XCTAssertTrue(request.query.isEmpty, "no filter keys are invented")
    }

    // MARK: - create / rename / view bodies

    func testCreateBodyCarriesLocationAndOmitsNilFields() throws {
        let body = SessionCreateBody(
            title: "Deploy review",
            location: Session.LocationRef(directory: "/srv/demo/orbit")
        )
        let request = try W03Requests.createSession(body, credential: nil)
        XCTAssertEqual(request.path, "/api/session")
        XCTAssertEqual(request.contentType, "application/json; charset=utf-8")
        let json = try bodyJSON(request)
        XCTAssertEqual((json["location"] as? [String: Any])?["directory"] as? String, "/srv/demo/orbit")
        XCTAssertEqual(json["title"] as? String, "Deploy review")
        XCTAssertNil(json["id"], "absent optionals are omitted, not null")
        XCTAssertNil(json["agent"])
        XCTAssertNil(json["parentID"])
    }

    func testRenameSendsTitleAlone() throws {
        let request = try W03Requests.updateSession(sessionID: "ses_1", title: "New name")
        XCTAssertEqual(request.path, "/api/session/ses_1")
        XCTAssertEqual(request.method, .patch)
        let json = try bodyJSON(request)
        XCTAssertEqual(json["title"] as? String, "New name", "only the title is patched; metadata preserved")
        XCTAssertEqual(json.count, 1)
    }

    func testViewSendsObservedIdleEpochOnly() throws {
        let request = try W03Requests.viewSession(sessionID: "ses_2", observedIdleEpoch: 1_792_195_205_000)
        XCTAssertEqual(request.path, "/api/session/ses_2/view")
        XCTAssertEqual(request.method, .post)
        let json = try bodyJSON(request)
        XCTAssertEqual(json["idle"] as? Int64 ?? (json["idle"] as? NSNumber)?.int64Value, 1_792_195_205_000)
        XCTAssertEqual(json.count, 1, "phone time or extra fields are never sent")
    }

    func testPathScopedBuildersInterpolateTheSessionID() {
        XCTAssertEqual(W03Requests.getSession(sessionID: "ses_x").path, "/api/session/ses_x")
        XCTAssertEqual(W03Requests.removeSession(sessionID: "ses_y").path, "/api/session/ses_y")
        XCTAssertEqual(W03Requests.removeSession(sessionID: "ses_y").method, .delete)
        XCTAssertEqual(W03Requests.activeSessions().path, "/api/session/active")
    }

    // MARK: - Session decode and unread rules

    func testSessionDecodesRequiredAndOptionalFields() throws {
        let body = """
        {"id":"ses_demo_005","projectID":"project_harbour","title":"Failed execution",\
        "agent":"build","model":{"id":"demo-code","providerID":"synthetic"},\
        "cost":0.0125,"tokens":{"input":1200,"output":350,"reasoning":100,"cache":{"read":200,"write":0}},\
        "time":{"created":1792195204000,"updated":1792195204000,"idle":1792195205000},\
        "outcome":"failed","location":{"directory":"/srv/demo/harbour"}}
        """
        let session = try OpenCodeAPI.decoder.decode(Session.self, from: Data(body.utf8))
        XCTAssertEqual(session.id, "ses_demo_005")
        XCTAssertEqual(session.outcome, "failed")
        XCTAssertEqual(session.model?.providerID, "synthetic")
        XCTAssertEqual(session.cost, 0.0125)
        XCTAssertEqual(session.time?.idle, 1_792_195_205_000)
        XCTAssertNil(session.parentID, "absent fields stay absent")
        XCTAssertEqual(session.location?.directory, "/srv/demo/harbour")
    }

    func testUnreadFollowsViewedVersusUpdatedOnServerEpochs() {
        // Never acknowledged on this device -> unread.
        XCTAssertTrue(Session(id: "a", time: .init(created: 1, updated: 5)).isUnread)
        // Viewed at/after the last update -> read.
        XCTAssertFalse(Session(id: "b", time: .init(created: 1, updated: 5, viewed: 5)).isUnread)
        XCTAssertFalse(Session(id: "c", time: .init(created: 1, updated: 5, viewed: 7)).isUnread)
        // Updated after the last view -> unread again.
        XCTAssertTrue(Session(id: "d", time: .init(created: 1, updated: 9, viewed: 5)).isUnread)
        // No time at all -> unknown, presented as needing attention.
        XCTAssertTrue(Session(id: "e").isUnread)
    }

    func testListResponseDecodesOpaqueCursorWithoutInterpretingIt() throws {
        let body = #"{"data":[{"id":"ses_1","projectID":"p","cost":0,"tokens":{},"time":{},"location":{"directory":"/x"}}],"cursor":{"next":"opaque-token"}}"#
        let page = try OpenCodeAPI.decoder.decode(SessionListResponse.self, from: Data(body.utf8))
        XCTAssertEqual(page.data.map(\.id), ["ses_1"])
        XCTAssertEqual(page.cursor?.next, "opaque-token", "cursor is consumed as an opaque string")
    }
}
