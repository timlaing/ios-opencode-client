import XCTest
@testable import OpenCodeTransport

/// W04 transport tests: the `Session.Message.Info` TYPE-UNION decode
/// (every pinned-baseline variant), lossless retention of unknown
/// variants and provider tool states, and the request builders
/// (docs/api-contract.md W04).
final class W04RequestsTests: XCTestCase {
    private func decode(_ body: String) throws -> SessionMessage {
        try JSONDecoder().decode(SessionMessage.self, from: Data(body.utf8))
    }

    private func encode(_ message: SessionMessage) throws -> SessionMessage {
        let data = try JSONEncoder().encode(message)
        return try JSONDecoder().decode(SessionMessage.self, from: data)
    }

    // MARK: - Union variants

    func testUserMessageDecodesTextAndAttachments() throws {
        let message = try decode(
            #"{"id":"msg_u","type":"user","time":{"created":1000},"text":"Build the thing","files":[{"data":"aGVsbG8=","mime":"text/plain","name":"notes.txt","description":"specs"}]}"#
        )
        guard case .user(let text, let files) = message.kind else {
            return XCTFail("expected user, got \(message.kind)")
        }
        XCTAssertEqual(message.rawType, "user")
        XCTAssertEqual(text, "Build the thing")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.name, "notes.txt")
        XCTAssertEqual(files.first?.mime, "text/plain")
    }

    func testAssistantDecodesOrderedContentAndToolStates() throws {
        let body = #"""
        {"id":"msg_a","type":"assistant","time":{"created":2000,"streamed":2001,"completed":2002},
         "agent":"build","model":{"id":"gpt-5","providerID":"openai","variant":"Thinking"},
         "content":[
           {"type":"reasoning","text":"thinking hard","time":{"created":2000}},
           {"type":"text","text":"Done **it**."},
           {"type":"tool","id":"tool_1","name":"edit","time":{"created":2001,"completed":2002},
            "state":{"status":"completed","input":{"file":"a.swift"},
                     "content":[{"type":"text","text":"edited"},
                                {"type":"file","uri":"file:///a.swift","mime":"text/swift","name":"a.swift"}]}},
           {"type":"tool","id":"tool_2","name":"bash","state":{"status":"streaming","input":"echo hi"}},
           {"type":"tool","id":"tool_3","name":"read","state":{"status":"running","input":{"cmd":"ls"},"metadata":{"m":"x"}}},
           {"type":"tool","id":"tool_4","name":"boom","state":{"status":"error","input":{"cmd":"ls"},"error":{"message":"kaput"},"content":[{"type":"text","text":"partial"}]}},
           {"type":"tool","id":"tool_5","name":"quantum","state":{"status":"quantum","weird":true}}
         ]}
        """#
        let message = try decode(body)
        guard case .assistant(let agent, let model, let content, let error, let retry) = message.kind else {
            return XCTFail("expected assistant, got \(message.kind)")
        }
        XCTAssertEqual(agent, "build")
        XCTAssertEqual(model?.id, "gpt-5")
        XCTAssertEqual(model?.variant, "Thinking")
        XCTAssertNil(error)
        XCTAssertNil(retry)
        XCTAssertEqual(content.map(\.type), ["reasoning", "text", "tool", "tool", "tool", "tool", "tool"])

        guard case .completed(let input, let toolContent) = content[2].state else {
            return XCTFail("tool_1 should be completed")
        }
        XCTAssertNotNil(input)
        XCTAssertEqual(toolContent.count, 2)
        guard case .file(let uri, let mime, let name) = toolContent[1].kind else {
            return XCTFail("second content should be file")
        }
        XCTAssertEqual(uri, "file:///a.swift")
        XCTAssertEqual(mime, "text/swift")
        XCTAssertEqual(name, "a.swift")

        guard case .streaming(let input) = content[3].state else { return XCTFail("streaming") }
        XCTAssertEqual(input, "echo hi")
        guard case .running(let runningInput, let metadata) = content[4].state else { return XCTFail("running") }
        XCTAssertNotNil(runningInput)
        XCTAssertNotNil(metadata)
        guard case .error(_, let toolError, let partial) = content[5].state else { return XCTFail("error") }
        XCTAssertEqual(toolError.message, "kaput")
        XCTAssertEqual(partial?.count, 1)
        guard case .unknown(let status, let raw) = content[6].state else { return XCTFail("unknown state") }
        XCTAssertEqual(status, "quantum")
        XCTAssertEqual(raw["weird"], .bool(true), "unknown provider state keeps its raw payload")
    }

    func testBookkeepingVariantsDecode() throws {
        let shell = try decode(
            #"{"id":"msg_sh","type":"shell","time":{"created":6},"shellID":"shell_1","command":"ls","status":"completed","exit":0,"output":"a.swift"}"#
        )
        guard case .shell(let shellID, let command, let status, let exit, let output) = shell.kind else {
            return XCTFail("shell")
        }
        XCTAssertEqual([shellID, command, status], ["shell_1", "ls", "completed"])
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(output, "a.swift")

        let synthetic = try decode(
            #"{"id":"msg_sy","type":"synthetic","time":{"created":10},"text":"Switched to plan","description":"agent change"}"#
        )
        guard case .synthetic(let text, let description) = synthetic.kind else { return XCTFail("synthetic") }
        XCTAssertEqual(text, "Switched to plan")
        XCTAssertEqual(description, "agent change")

        let agentSwitch = try decode(
            #"{"id":"msg_ag","type":"agent-switched","time":{"created":7},"agent":"plan","previous":"build"}"#
        )
        guard case .agentSwitched(let agent, let previous) = agentSwitch.kind else { return XCTFail("agent switch") }
        XCTAssertEqual(agent, "plan")
        XCTAssertEqual(previous, "build")

        let modelSwitch = try decode(
            #"{"id":"msg_ms","type":"model-switched","time":{"created":8},"model":{"id":"gpt-5","providerID":"openai"},"previous":null}"#
        )
        guard case .modelSwitched(let model, let previous) = modelSwitch.kind else { return XCTFail("model switch") }
        XCTAssertEqual(model?.id, "gpt-5")
        XCTAssertNil(previous)

        let locationSwitch = try decode(
            #"{"id":"msg_ls","type":"location-switched","time":{"created":9},"location":{"directory":"/srv/demo/other"},"projectID":"project_orbit"}"#
        )
        guard case .locationSwitched(let projectID, _, let directory) = locationSwitch.kind else {
            return XCTFail("location switch")
        }
        XCTAssertEqual(projectID, "project_orbit")
        XCTAssertEqual(directory, "/srv/demo/other")

        let compaction = try decode(
            #"{"id":"msg_cp","type":"compaction","time":{"created":11},"status":"failed","reason":"auto","error":{"name":"ProviderError","message":"kaput"}}"#
        )
        guard case .compaction(let status, let reason, _, let errorMessage) = compaction.kind else {
            return XCTFail("compaction")
        }
        XCTAssertEqual([status, reason ?? "", errorMessage ?? ""], ["failed", "auto", "kaput"])

        let idle = try decode(
            #"{"id":"msg_idle","type":"idle","time":{"created":4},"outcome":"completed"}"#
        )
        guard case .idle(let outcome) = idle.kind else { return XCTFail("idle") }
        XCTAssertEqual(outcome, "completed")
        XCTAssertEqual(idle.time.created, 4)
    }

    func testUnknownVariantRetainsRawPayloadAndRoundTrips() throws {
        let body = #"{"id":"msg_x","type":"wave-machine","time":{"created":3},"intensity":9.5,"tags":["a","b"]}"#
        let message = try decode(body)
        guard case .unknown(let type, let raw) = message.kind else {
            return XCTFail("unknown variant")
        }
        XCTAssertEqual(type, "wave-machine")
        XCTAssertEqual(raw["intensity"], .number(9.5))
        XCTAssertEqual(raw["tags"], .array([.string("a"), .string("b")]))

        let roundTripped = try encode(message)
        XCTAssertEqual(roundTripped, message, "unknown payloads survive an encode/decode cycle intact")
    }

    // MARK: - Builders

    func testListMessagesBuilderCarriesFiltersOpquely() {
        let request = W04Requests.listMessages(
            sessionID: "ses_a", limit: 50, order: .descending, type: "assistant", cursor: "opaque-7",
            credential: BasicCredential(secret: "t")
        )
        XCTAssertEqual(request.operationID, "session.message.list")
        XCTAssertEqual(request.path, "/api/session/ses_a/message")
        let query = Dictionary(uniqueKeysWithValues: request.query.map { ($0.key, $0.value) })
        XCTAssertEqual(query["limit"], "50")
        XCTAssertEqual(query["order"], "desc")
        XCTAssertEqual(query["type"], "assistant")
        XCTAssertEqual(query["cursor"], "opaque-7")
    }

    func testMessageAndContextBuilders() {
        let message = W04Requests.getMessage(sessionID: "ses_a", messageID: "msg_1")
        XCTAssertEqual(message.operationID, "session.message.get")
        XCTAssertEqual(message.path, "/api/session/ses_a/message/msg_1")

        let context = W04Requests.context(sessionID: "ses_a")
        XCTAssertEqual(context.operationID, "session.context")
        XCTAssertEqual(context.path, "/api/session/ses_a/context")
        XCTAssertTrue(context.query.isEmpty)
    }
}
