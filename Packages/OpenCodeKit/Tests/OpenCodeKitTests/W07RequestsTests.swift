import XCTest
@testable import OpenCodeTransport

/// W07 transport tests: command/skill decoding (schema-required fields,
/// optional description/autoinvoke), exact routes, and invocation body
/// shapes — command `{name,text}` (text present even when empty) and
/// skill `{id,resume?}` with nothing invented (additionalProperties
/// false; docs/api-contract.md W07).
final class W07RequestsTests: XCTestCase {
    func testCommandInfoDecodesWithNameAsIdentity() throws {
        let command = try JSONDecoder().decode(
            CommandInfo.self,
            from: Data(#"{"name":"review","description":"Synthetic review command"}"#.utf8)
        )
        XCTAssertEqual(command.name, "review")
        XCTAssertEqual(command.id, "review", "name is the invoke identity")
        XCTAssertEqual(command.description, "Synthetic review command")

        let bare = try JSONDecoder().decode(CommandInfo.self, from: Data(#"{"name":"ship"}"#.utf8))
        XCTAssertNil(bare.description, "an absent description stays absent")
    }

    func testSkillInfoDecodesRequiredAndOptionalFields() throws {
        let skill = try JSONDecoder().decode(
            SkillInfo.self,
            from: Data("""
            {"id":"demo-review","name":"Demo review","path":"/srv/demo/.opencode/skills/review.md",
             "content":"Review generated files only.","description":"Reviews files","autoinvoke":false}
            """.utf8)
        )
        XCTAssertEqual(skill.id, "demo-review")
        XCTAssertEqual(skill.path, "/srv/demo/.opencode/skills/review.md")
        XCTAssertEqual(skill.content, "Review generated files only.")
        XCTAssertEqual(skill.description, "Reviews files")
        XCTAssertEqual(skill.autoinvoke, false)

        // Schema-required fields must be enforced on decode.
        XCTAssertThrowsError(
            try JSONDecoder().decode(SkillInfo.self, from: Data(#"{"id":"x","name":"X"}"#.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError, "missing schema-required content must fail decode")
        }
    }

    func testDiscoveryBuildersUseExactRoutes() {
        let commands = W07Requests.listCommands()
        XCTAssertEqual(commands.operationID, "command.list")
        XCTAssertEqual(commands.method, .get)
        XCTAssertEqual(commands.path, "/api/command")

        let skills = W07Requests.listSkills()
        XCTAssertEqual(skills.operationID, "skill.list")
        XCTAssertEqual(skills.method, .get)
        XCTAssertEqual(skills.path, "/api/skill")
    }

    func testInvokeCommandBodyCarriesNameAndTextOnly() throws {
        let request = try W07Requests.invokeCommand(
            sessionID: "ses_a", name: "review", text: "generated files"
        )
        XCTAssertEqual(request.operationID, "session.command")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/api/session/ses_a/command")

        let payload = request.body.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertEqual(payload?["name"] as? String, "review")
        XCTAssertEqual(payload?["text"] as? String, "generated files")
        // No attachment/agent/skill keys are invented — that scope is
        // W08/W06 and additionalProperties is false.
        XCTAssertEqual(Set((payload ?? [:]).keys), ["name", "text"])
    }

    func testInvokeCommandAlwaysSendsTextEvenWhenEmpty() throws {
        let request = try W07Requests.invokeCommand(sessionID: "ses_a", name: "review", text: "")
        let payload = request.body.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertEqual(payload?["text"] as? String, "", "text is schema-required even when empty")
    }

    func testActivateSkillBodyCarriesIDAndOptionalResume() throws {
        let request = try W07Requests.activateSkill(sessionID: "ses_a", id: "demo-review")
        XCTAssertEqual(request.operationID, "experimental.session.skill")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/api/experimental/session/ses_a/skill")
        let payload = request.body.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertEqual(Set((payload ?? [:]).keys), ["id"], "resume is omitted, not sent as null")

        let resumed = try W07Requests.activateSkill(sessionID: "ses_a", id: "demo-review", resume: true)
        let resumedPayload = resumed.body.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertEqual(resumedPayload?["resume"] as? Bool, true)
        XCTAssertEqual(Set((resumedPayload ?? [:]).keys), ["id", "resume"])
    }
}
