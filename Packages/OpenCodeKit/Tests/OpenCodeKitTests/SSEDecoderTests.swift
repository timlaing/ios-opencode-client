import XCTest
@testable import OpenCodeTransport

/// Validates the SSE decoder against the committed mock-server trace
/// (fixtures/generated/events.sse + events.jsonl) — the same data the
/// contract tests pin (tests/test_mock.py).
final class SSEDecoderTests: XCTestCase {
    private var fixturesURL: URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let fixtures = url.appendingPathComponent("fixtures/generated")
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("events.sse").path) else {
            return nil
        }
        return fixtures
    }

    func testOfflineEventTraceMatchesJSONL() throws {
        guard let fixtures = fixturesURL else {
            throw XCTSkip("fixtures/generated not present (run scripts/build_contracts.py)")
        }
        let sseData = try Data(contentsOf: fixtures.appendingPathComponent("events.sse"))
        let jsonl = try String(contentsOf: fixtures.appendingPathComponent("events.jsonl"), encoding: .utf8)
        let expected: [JSONValue] = try jsonl
            .split(separator: "\n")
            .map { line in
                try OpenCodeAPI.decoder.decode(JSONValue.self, from: Data(line.utf8))
            }

        var decoder = SSEDecoder()
        let messages = decoder.decode(sseData) + decoder.finish()

        let decoded: [JSONValue] = try messages.compactMap { message in
            guard case .event(_, _, let data) = message else { return nil }
            return try OpenCodeAPI.decoder.decode(JSONValue.self, from: Data(data.utf8))
        }
        // Heartbeat comments are decoded but carry no event payload.
        XCTAssertGreaterThan(messages.count, decoded.count, "expected heartbeat frames to be surfaced")
        XCTAssertEqual(decoded, expected)
    }

    func testFramesSplitAcrossArbitraryChunksDecodeIdentically() throws {
        guard let fixtures = fixturesURL else {
            throw XCTSkip("fixtures/generated not present")
        }
        let sseData = try Data(contentsOf: fixtures.appendingPathComponent("events.sse"))

        func decodeChunked(chunkSize: Int) throws -> [OpenCodeEvent] {
            var decoder = SSEDecoder()
            var messages: [SSEMessage] = []
            var index = 0
            while index < sseData.count {
                let end = min(index + chunkSize, sseData.count)
                messages += decoder.decode(sseData.subdata(in: index..<end))
                index = end
            }
            messages += decoder.finish()
            return try messages.compactMap { message in
                guard case .event(_, _, let data) = message else { return nil }
                return try OpenCodeAPI.decoder.decode(OpenCodeEvent.self, from: Data(data.utf8))
            }
        }

        // One byte at a time covers UTF-8 sequences and frame delimiters split
        // at every possible boundary.
        let whole = try decodeChunked(chunkSize: sseData.count)
        let perByte = try decodeChunked(chunkSize: 1)
        let odd = try decodeChunked(chunkSize: 7)
        XCTAssertEqual(perByte, whole)
        XCTAssertEqual(odd, whole)
        XCTAssertFalse(whole.isEmpty)
    }

    func testUnknownEventTypeDecodesGenerically() throws {
        var decoder = SSEDecoder()
        let payload = #"data: {"id":"evt_future","type":"rpc.demo.future","data":{"nested":[1,2,3]}}"# + "\n\n"
        let messages = decoder.decode(Data(payload.utf8))
        guard case .event(_, _, let data) = try XCTUnwrap(messages.first) else {
            return XCTFail("expected an event frame")
        }
        let event = try XCTUnwrap(OpenCodeEvent.parse(dataPayload: data))
        XCTAssertEqual(event.type, "rpc.demo.future")
        XCTAssertEqual(event.data?["nested"], .array([1, 2, 3]))
    }

    func testHeartbeatCommentFramesAreSurfacedForLiveness() {
        var decoder = SSEDecoder()
        let messages = decoder.decode(Data(": heartbeat\n\n".utf8))
        XCTAssertEqual(messages, [.comment(" heartbeat")])
    }

    func testCROnlyLineEndingsDecodeFrames() {
        var decoder = SSEDecoder()
        let messages = decoder.decode(Data("data: first\rdata: second\r\r".utf8))
        // Two `data:` lines in one frame join with "\n" per the SSE format.
        XCTAssertEqual(messages, [.event(id: nil, event: nil, data: "first\nsecond")])
    }

    func testCRLFLineEndingsDecodeFrames() {
        var decoder = SSEDecoder()
        let messages = decoder.decode(Data("data: first\r\n\r\ndata: second\r\n\r\n".utf8))
        XCTAssertEqual(messages, [
            .event(id: nil, event: nil, data: "first"),
            .event(id: nil, event: nil, data: "second"),
        ])
    }

    func testCROnlyFramesSplitAcrossChunksDecodeIdentically() {
        var decoder = SSEDecoder()
        var messages: [SSEMessage] = []
        for byte in Array("data: {\"id\":\"evt_1\"}\r\r".utf8) {
            messages += decoder.decode(Data([byte]))
        }
        XCTAssertEqual(messages, [.event(id: nil, event: nil, data: #"{"id":"evt_1"}"#)])
    }
}
