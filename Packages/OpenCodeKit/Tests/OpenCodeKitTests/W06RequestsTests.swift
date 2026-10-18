import XCTest
@testable import OpenCodeTransport

/// W06 transport tests: `Model.Info`/`Agent.Info` decoding (required
/// fields, string capabilities, forward-compatible status/mode), the
/// location envelope, `Model.Ref` selection identity (never `modelID`),
/// and exact route/body shapes (docs/api-contract.md W06).
final class W06RequestsTests: XCTestCase {
    private let modelJSON = """
    {"id":"demo-code","modelID":"demo-code","providerID":"synthetic",
     "name":"Demo Code (synthetic)",
     "capabilities":{"tools":true,"input":["text","image","pdf"],"output":["text"]},
     "variants":[{"id":"fast"}],
     "time":{"released":0},
     "cost":[{"input":1,"output":2,"cache":{"read":0.1,"write":0.2}}],
     "status":"active","enabled":true,
     "limit":{"context":128000,"output":8192}}
    """

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testModelInfoDecodesRequiredFieldsAndStringCapabilities() throws {
        let model = try decode(ModelInfo.self, modelJSON)

        XCTAssertEqual(model.id, "demo-code")
        XCTAssertEqual(model.providerID, "synthetic")
        XCTAssertEqual(model.capabilities.input, ["text", "image", "pdf"], "input capabilities stay STRINGS")
        XCTAssertEqual(model.variants.map(\.id), ["fast"])
        XCTAssertEqual(model.limit.context, 128000)
        XCTAssertEqual(model.limit.output, 8192)
        XCTAssertNil(model.limit.input, "an absent limit stays absent — never invented")
        XCTAssertEqual(model.cost.first?.cache.read, 0.1)

        // Explicit UI booleans — never the raw array.
        XCTAssertTrue(model.acceptsText)
        XCTAssertTrue(model.acceptsImages)
        XCTAssertTrue(model.acceptsPDFs)
        XCTAssertTrue(model.outputsText)
        XCTAssertTrue(model.isSelectable)
    }

    func testUnknownStatusStaysVisibleAndNeverFailsTheList() throws {
        let json = modelJSON.replacingOccurrences(of: "\"active\"", with: "\"experimental\"")
        let model = try decode(ModelInfo.self, json)
        XCTAssertEqual(model.status, "experimental", "an unknown host status remains visible")
        XCTAssertTrue(model.isSelectable, "an unknown status is not conflated with deprecated")

        let deprecated = try decode(
            ModelInfo.self,
            modelJSON.replacingOccurrences(of: "\"active\"", with: "\"deprecated\"")
        )
        XCTAssertFalse(deprecated.isSelectable, "deprecated models stay visible but unselectable")

        let disabled = try decode(
            ModelInfo.self,
            modelJSON.replacingOccurrences(of: "\"enabled\":true", with: "\"enabled\":false")
        )
        XCTAssertFalse(disabled.isSelectable, "a disabled model is visible but unselectable")
    }

    func testSelectionRefUsesIdAndProviderIDNeverModelID() throws {
        let model = try decode(ModelInfo.self, modelJSON)
        let ref = model.selectionRef(variant: "fast")

        XCTAssertEqual(ref.id, "demo-code")
        XCTAssertEqual(ref.providerID, "synthetic")
        XCTAssertEqual(ref.variant, "fast")

        // The encoded switch body must carry Model.Ref fields only.
        let request = try W06Requests.switchModel(sessionID: "ses_a", model: ref)
        let payload = request.body.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let modelPayload = payload?["model"] as? [String: Any]
        XCTAssertEqual(Set((modelPayload ?? [:]).keys), ["id", "providerID", "variant"],
                       "selection sends Model.Ref — modelID must never appear")
        XCTAssertEqual(modelPayload?["modelID"] as? String, nil)
    }

    func testAgentInfoDecodesAndDeterminesOfferability() throws {
        let primary = try decode(
            AgentInfo.self,
            #"{"id":"build","name":"Build","description":"Dev agent","mode":"primary","hidden":false}"#
        )
        XCTAssertEqual(primary.name, "Build")
        XCTAssertEqual(primary.description, "Dev agent")
        XCTAssertTrue(primary.isOfferedAsPrimary)

        let subagent = try decode(
            AgentInfo.self,
            #"{"id":"reviewer","name":"Reviewer","mode":"subagent","hidden":false}"#
        )
        XCTAssertFalse(subagent.isOfferedAsPrimary, "subagents are W08 attachments, not S10 selections")

        let hidden = try decode(
            AgentInfo.self,
            #"{"id":"secret","name":"Secret","mode":"primary","hidden":true}"#
        )
        XCTAssertFalse(hidden.isOfferedAsPrimary, "hidden agents are never offered")

        let unknown = try decode(
            AgentInfo.self,
            #"{"id":"odd","name":"Odd","mode":"telepath","hidden":false}"#
        )
        XCTAssertEqual(unknown.mode, "telepath", "an unknown mode stays visible")
        XCTAssertTrue(unknown.isOfferedAsPrimary, "unknown modes stay offered — the host is authoritative")
    }

    func testAgentDecodesItsConfiguredModelRef() throws {
        let agent = try decode(
            AgentInfo.self,
            #"{"id":"build","name":"Build","mode":"primary","hidden":false,"model":{"id":"demo-code","providerID":"synthetic"}}"#
        )
        XCTAssertEqual(agent.model?.id, "demo-code")
        XCTAssertEqual(agent.model?.providerID, "synthetic")
    }

    func testLocationEnvelopeWrapsData() throws {
        let envelope = try decode(
            LocationEnvelope<[ModelInfo]>.self,
            #"{"location":{"directory":"/srv/demo"},"data":[\#(modelJSON)]}"#
        )
        XCTAssertEqual(envelope.location.directory, "/srv/demo")
        XCTAssertEqual(envelope.data.map(\.id), ["demo-code"])
    }

    func testInventoryBuildersUseExactRoutes() {
        let models = W06Requests.listModels()
        XCTAssertEqual(models.operationID, "model.list")
        XCTAssertEqual(models.method, .get)
        XCTAssertEqual(models.path, "/api/model")

        let fallback = W06Requests.defaultModel()
        XCTAssertEqual(fallback.operationID, "model.default")
        XCTAssertEqual(fallback.path, "/api/model/default")

        let agents = W06Requests.listAgents()
        XCTAssertEqual(agents.operationID, "agent.list")
        XCTAssertEqual(agents.path, "/api/agent")

        let detail = W06Requests.getAgent(agentID: "build")
        XCTAssertEqual(detail.operationID, "agent.get")
        XCTAssertEqual(detail.path, "/api/agent/build")
    }

    func testSwitchBuildersUsePostAnd204StyleBodies() throws {
        let model = try W06Requests.switchModel(
            sessionID: "ses_a",
            model: Session.ModelRef(id: "demo-code", providerID: "synthetic")
        )
        XCTAssertEqual(model.operationID, "session.switchModel")
        XCTAssertEqual(model.method, .post)
        XCTAssertEqual(model.path, "/api/session/ses_a/model")

        let agent = try W06Requests.switchAgent(sessionID: "ses_a", agent: "build")
        XCTAssertEqual(agent.operationID, "session.switchAgent")
        XCTAssertEqual(agent.method, .post)
        XCTAssertEqual(agent.path, "/api/session/ses_a/agent")
        let payload = agent.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(payload?["agent"] as? String, "build")
        XCTAssertEqual(Set((payload ?? [:]).keys), ["agent"])
    }
}
