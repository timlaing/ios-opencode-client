import XCTest
@testable import OpenCodeTransport

/// W05 transport tests: the `Session.Inbox.Info` union decode, prompt
/// body shape with the app's stable message ID, delivery/interrupt
/// builders (docs/api-contract.md W05).
final class W05RequestsTests: XCTestCase {
    private func decode(_ body: String) throws -> InboxItem {
        try JSONDecoder().decode(InboxItem.self, from: Data(body.utf8))
    }

    // MARK: - Inbox union

    func testUserInboxItemDecodesAndProjectsIntoTranscriptMessage() throws {
        let item = try decode(
            #"{"id":"msg_u","sessionID":"ses_a","time":{"created":1000},"type":"user","delivery":"steer","payload":{"text":"Ship it","files":[{"data":"aGVsbG8=","mime":"text/plain","name":"notes.txt"}]}}"#
        )
        XCTAssertEqual(item.id, "msg_u")
        XCTAssertEqual(item.sessionID, "ses_a")
        XCTAssertEqual(item.delivery, .steer)
        guard case .user(let text, let files, _) = item.kind else {
            return XCTFail("expected user inbox item")
        }
        XCTAssertEqual(text, "Ship it")
        XCTAssertEqual(files.first?.name, "notes.txt")

        let projected = try XCTUnwrap(item.projectedMessage)
        XCTAssertEqual(projected.id, "msg_u", "projection keeps the stable ID for dedupe")
        XCTAssertEqual(projected.time.created, 1000)
        guard case .user(let projectedText, _) = projected.kind else {
            return XCTFail("projection should be a transcript user message")
        }
        XCTAssertEqual(projectedText, "Ship it")
    }

    func testSyntheticCompactionAndMoveVariantsDecode() throws {
        let synthetic = try decode(
            #"{"id":"msg_s","sessionID":"ses_a","time":{"created":1},"type":"synthetic","delivery":"queue","payload":{"text":"queued note","description":"note"}}"#
        )
        guard case .synthetic(let text, let description) = synthetic.kind else {
            return XCTFail("synthetic")
        }
        XCTAssertEqual([text, description ?? "", synthetic.delivery.rawValue], ["queued note", "note", "queue"])

        let compaction = try decode(
            #"{"id":"msg_c","sessionID":"ses_a","time":{"created":2},"type":"compaction","delivery":"steer","payload":{"reason":"auto"}}"#
        )
        guard case .compaction(let payload) = compaction.kind else { return XCTFail("compaction") }
        XCTAssertEqual(payload["reason"]?.stringValue, "auto", "anyOf payload stays lossless")

        let move = try decode(
            #"{"id":"msg_m","sessionID":"ses_a","time":{"created":3},"type":"move","delivery":"steer","payload":{"projectID":"project_orbit","location":{"directory":"/srv/demo/other"}}}"#
        )
        guard case .move(let projectID, _, let directory) = move.kind else { return XCTFail("move") }
        XCTAssertEqual(projectID, "project_orbit")
        XCTAssertEqual(directory, "/srv/demo/other")
    }

    func testUnknownInboxVariantIsRetainedNotDropped() throws {
        let item = try decode(
            #"{"id":"msg_x","sessionID":"ses_a","time":{"created":4},"type":"teleport","delivery":"queue","payload":{"beams":2}}"#
        )
        XCTAssertEqual(item.rawType, "teleport", "an unknown pending item stays visible (cancellable)")
        XCTAssertNil(item.projectedMessage, "only user items project into the transcript")
        guard case .unknown(let type, let payload) = item.kind else {
            return XCTFail("never claimed as a known kind")
        }
        XCTAssertEqual(type, "teleport")
        XCTAssertEqual(payload?["beams"], .number(2))
    }

    func testUnknownInboxVariantWithoutPayloadKeepsType() throws {
        let item = try decode(
            #"{"id":"msg_y","sessionID":"ses_a","time":{"created":5},"type":"pulse","delivery":"queue"}"#
        )
        guard case .unknown(let type, let payload) = item.kind else {
            return XCTFail("never claimed as a known kind")
        }
        XCTAssertEqual(type, "pulse")
        XCTAssertNil(payload)
    }

    func testInboxItemRoundTripsThroughEncode() throws {
        let original = try decode(
            #"{"id":"msg_u","sessionID":"ses_a","time":{"created":1000},"type":"user","delivery":"queue","payload":{"text":"Ship it","metadata":{"k":"v"}}}"#
        )
        let data = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(InboxItem.self, from: data)
        XCTAssertEqual(roundTripped, original)
    }

    // MARK: - Prompt body

    func testPromptBodyCarriesStableIDTextAndDelivery() throws {
        let body = PromptBody(id: "msg_stable", text: "Do the thing", delivery: .queue, resume: true)
        let data = try JSONEncoder().encode(body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "msg_stable")
        XCTAssertEqual(object["text"] as? String, "Do the thing")
        XCTAssertEqual(object["delivery"] as? String, "queue")
        XCTAssertEqual(object["resume"] as? Bool, true)
    }

    // MARK: - Builders

    func testPromptBuilderPostsJSONBody() throws {
        let request = try W05Requests.prompt(
            sessionID: "ses_a",
            body: PromptBody(id: "msg_1", text: "hi", delivery: .steer),
            credential: BasicCredential(secret: "t")
        )
        XCTAssertEqual(request.operationID, "session.prompt")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/api/session/ses_a/prompt")
        let payload = try XCTUnwrap(request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(payload["id"] as? String, "msg_1")
        XCTAssertEqual(payload["text"] as? String, "hi")
    }

    func testInboxBuildersUseExactRoutes() {
        let list = W05Requests.listInbox(sessionID: "ses_a")
        XCTAssertEqual(list.operationID, "session.inbox.list")
        XCTAssertEqual(list.method, .get)
        XCTAssertEqual(list.path, "/api/session/ses_a/inbox")

        let cancel = W05Requests.cancelInbox(sessionID: "ses_a", inboxID: "msg_1")
        XCTAssertEqual(cancel.operationID, "session.inbox.cancel")
        XCTAssertEqual(cancel.method, .delete)
        XCTAssertEqual(cancel.path, "/api/session/ses_a/inbox/msg_1")

        let update = try? W05Requests.updateInbox(sessionID: "ses_a", inboxID: "msg_1", delivery: .queue)
        XCTAssertEqual(update?.operationID, "session.inbox.update")
        XCTAssertEqual(update?.method, .patch)
        XCTAssertEqual(update?.path, "/api/session/ses_a/inbox/msg_1")
    }

    func testOrdinaryStopUsesResumeFalse() {
        let request = W05Requests.interrupt(sessionID: "ses_a")
        XCTAssertEqual(request.operationID, "session.interrupt")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/api/session/ses_a/interrupt")
        XCTAssertEqual(request.query.first?.key, "resume")
        XCTAssertEqual(request.query.first?.value, "false", "the ordinary Stop never resumes/steers")
    }
}
