import XCTest
@testable import OpenCodeTransport

final class ErrorEnvelopeTests: XCTestCase {
    func testBaselineErrorEnvelopeDecodesWithExtraFieldsPreserved() throws {
        let json = """
        {"_tag":"FormInvalidAnswerError","message":"invalid answer","field":"env"}
        """
        let envelope = try OpenCodeAPI.decoder.decode(APIErrorEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.tag, "FormInvalidAnswerError")
        XCTAssertEqual(envelope.message, "invalid answer")
        XCTAssertEqual(envelope.details["field"], "env")
    }

    func testAuthenticationFailuresAreDetected() {
        let unauthorized = TransportError.http(status: 401, envelope: nil)
        let forbidden = TransportError.http(status: 403, envelope: nil)
        let serverError = TransportError.http(status: 500, envelope: nil)
        XCTAssertTrue(unauthorized.isAuthenticationFailure)
        XCTAssertTrue(forbidden.isAuthenticationFailure)
        XCTAssertFalse(serverError.isAuthenticationFailure)
    }

    func testEventDecodingFromFixtureLinesToleratesUnknownKeys() throws {
        // Server-connected frame shape from the pinned contract: unknown future
        // keys on an event must not break decoding.
        let payload = #"{"id":"evt","created":1792231200000,"type":"server.connected","data":{},"futureKey":true}"#
        let event = try XCTUnwrap(OpenCodeEvent.parse(dataPayload: payload))
        XCTAssertEqual(event.type, "server.connected")
        XCTAssertEqual(event.created, 1_792_231_200_000)
        XCTAssertEqual(event.data, .object([:]))
    }
}
