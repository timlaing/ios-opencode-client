import XCTest
@testable import OpenCodeTransport

/// W13 request shapes (docs/api-contract.md W13): the compact builder
/// always carries the REQUIRED JSON body (`{}` minimum) with only the
/// properties provided, and `SessionMessage` decodes the host-reported
/// step tokens at the ENVELOPE level — the `Kind` union is untouched.
final class W13RequestsTests: XCTestCase {
    private func payload(_ request: APIRequest) throws -> [String: Any] {
        try XCTUnwrap(
            request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            },
            "the compact body is REQUIRED even when every property is absent"
        )
    }

    func testCompactBuilderPostsRequiredEmptyBodyToTheSessionRoute() throws {
        let request = try W13Requests.compact(
            sessionID: "ses_a", credential: BasicCredential(secret: "t")
        )
        XCTAssertEqual(request.operationID, "session.compact")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/api/session/ses_a/compact")
        XCTAssertTrue(try payload(request).isEmpty, "`{}` lets the host apply its own defaults")
    }

    func testCompactBodyCarriesOnlyTheProvidedProperties() throws {
        let request = try W13Requests.compact(
            sessionID: "ses_a", id: "msg_c", delivery: .queue
        )
        let body = try payload(request)
        XCTAssertEqual(body["id"] as? String, "msg_c")
        XCTAssertEqual(body["delivery"] as? String, "queue")
        XCTAssertEqual(body.count, 2)
    }

    // MARK: - Envelope-level step tokens

    private func decode(_ json: String) throws -> SessionMessage {
        try JSONDecoder().decode(SessionMessage.self, from: Data(json.utf8))
    }

    func testAssistantMessageDecodesReportedStepTokens() throws {
        let message = try decode(
            #"{"id":"msg_a","type":"assistant","time":{"created":1},"agent":"main","content":[],"tokens":{"input":1200,"output":350,"reasoning":100,"cache":{"read":200,"write":0}}}"#
        )
        XCTAssertEqual(
            message.tokens,
            Session.TokenUsage(input: 1200, output: 350, reasoning: 100, cache: .init(read: 200, write: 0))
        )
        guard case .assistant = message.kind else {
            return XCTFail("the Kind union is untouched by the tokens field")
        }
    }

    func testMessagesWithoutReportedTokensDecodeNil() throws {
        XCTAssertNil(try decode(
            #"{"id":"msg_u","type":"user","time":{"created":1},"text":"hi"}"#
        ).tokens)
        XCTAssertNil(try decode(
            #"{"id":"msg_s","type":"agent-switched","time":{"created":1},"agent":"main"}"#
        ).tokens)
    }

    func testCompactionTransitionCarriesItsReportedTokens() throws {
        // `Session.Message.Compaction.Completed` also reports tokens —
        // the envelope-level decode keeps the newest report visible even
        // when the newest message is a compaction.
        let message = try decode(
            #"{"id":"msg_c","type":"compaction","time":{"created":2},"status":"completed","tokens":{"input":900}}"#
        )
        XCTAssertEqual(message.tokens, Session.TokenUsage(input: 900))
    }

    func testReportedTokensSurviveEncodeRoundTrip() throws {
        let original = try decode(
            #"{"id":"msg_a","type":"assistant","time":{"created":1},"agent":"main","content":[],"tokens":{"input":1200,"output":350}}"#
        )
        let encoded = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["input"] as? Int, 1200)
        XCTAssertEqual(tokens["output"] as? Int, 350)
        XCTAssertEqual(try JSONDecoder().decode(SessionMessage.self, from: encoded), original)
    }

    func testUnknownVariantKeepsItsRawTokensThroughRoundTrip() throws {
        // An unknown variant keeps the FULL raw payload — tokens among
        // it — so nothing the host sent is dropped.
        let message = try decode(
            #"{"id":"msg_x","type":"wave-machine","time":{"created":3},"intensity":9.5,"tokens":{"input":7}}"#
        )
        XCTAssertEqual(message.tokens, Session.TokenUsage(input: 7))
        guard case .unknown(_, let raw) = message.kind else {
            return XCTFail("expected the unknown-variant retention")
        }
        XCTAssertNotNil(raw["tokens"])
        let encoded = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(SessionMessage.self, from: encoded), message)
    }
}
