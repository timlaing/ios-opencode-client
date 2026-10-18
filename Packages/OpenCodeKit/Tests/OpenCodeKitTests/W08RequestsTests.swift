import XCTest
@testable import OpenCodeTransport

/// W08 request-shape tests: the request-side `PromptInput.FileAttachment`
/// DTO's exact keys, `files` in the prompt body (nil omitted so W05
/// payloads stay byte-identical), and the staged-info builder
/// (docs/api-contract.md W08).
final class W08RequestsTests: XCTestCase {
    private func promptPayload(_ body: PromptBody) throws -> [String: Any] {
        let request = try W05Requests.prompt(sessionID: "ses_a", body: body)
        return try XCTUnwrap(
            request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        )
    }

    func testFullAttachmentSendsOnlySchemaKeys() throws {
        let full = PromptFileAttachment(
            uri: "data:image/png;base64,AA==",
            name: "diagram.png",
            description: "Architecture sketch",
            mention: true
        )
        let payload = try promptPayload(PromptBody(id: "msg_1", text: "Explain this", files: [full]))
        let files = try XCTUnwrap(payload["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(Set(files[0].keys), ["uri", "name", "description", "mention"])
        XCTAssertEqual(files[0]["uri"] as? String, "data:image/png;base64,AA==")
        XCTAssertEqual(files[0]["mention"] as? Bool, true)
    }

    func testMinimalAttachmentOmitsUnsetKeys() throws {
        let attachment = PromptFileAttachment(uri: "file:///tmp/uploads/u1/a.png", name: "a.png")
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any]
        )
        XCTAssertEqual(Set(payload.keys), ["uri", "name"], "description/mention are omitted, never null")
    }

    func testPromptBodyWithFilesCarriesExactKeys() throws {
        let attachment = PromptFileAttachment(uri: "file:///tmp/u1/a.png", name: "a.png")
        let payload = try promptPayload(PromptBody(id: "msg_1", text: "Explain this image", files: [attachment]))
        XCTAssertEqual(Set(payload.keys), ["id", "text", "files"])
        let files = try XCTUnwrap(payload["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0]["uri"] as? String, "file:///tmp/u1/a.png")
        XCTAssertEqual(files[0]["name"] as? String, "a.png")
    }

    func testTextOnlyPromptBodyOmitsFilesEntirely() throws {
        let payload = try promptPayload(PromptBody(id: "msg_1", text: "hi"))
        XCTAssertEqual(Set(payload.keys), ["id", "text"], "no attachments, no files key — W05 unchanged")
    }

    func testInfoBuilderUsesThePairedCredential() {
        let info = W08Requests.info(credential: BasicCredential(secret: "t"))
        XCTAssertEqual(info.operationID, "server.info")
        XCTAssertEqual(info.method, .get)
        XCTAssertEqual(info.path, "/api/info")
        XCTAssertEqual(info.credential, BasicCredential(secret: "t"))

        XCTAssertNil(W08Requests.info().credential,
                     "a nil credential is passed as nil, never an empty Basic header")
    }
}
