import Foundation

/// `PromptInput.FileAttachment` — the REQUEST shape for one attachment on
/// `session.prompt`: `{uri,name?,description?,mention?}` (docs/api-contract.md
/// W08). `uri` is a `data:` URI for inline content or a properly escaped
/// `file:` URI for host-staged content. This is deliberately NOT the
/// projected user-message `Prompt.FileAttachment` (`data` base64 / `mime` /
/// `source`, used when READING a transcript) — the two shapes must never
/// share a DTO.
public struct PromptFileAttachment: Codable, Equatable, Sendable {
    public var uri: String
    public var name: String?
    public var description: String?
    public var mention: Bool?

    public init(
        uri: String,
        name: String? = nil,
        description: String? = nil,
        mention: Bool? = nil
    ) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mention = mention
    }
}

/// W08 request builders: staging reuses `W02Requests.writeFile`
/// (`experimental.fs.write`); the prompt carries attachments through the
/// `files` array added to `PromptBody`. `paths.tmp` comes from
/// `server.info`, which W01 models for pairing with a plaintext secret —
/// staging re-requests the same route with the PAIRED credential.
public enum W08Requests {
    /// `GET /api/info` with a paired credential (no pairing secret): the
    /// response's `paths.tmp` is where staged uploads are written. Same
    /// route and operation as `W01Requests.health`, which cannot take a
    /// `BasicCredential`.
    public static func info(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "server.info",
            method: .get,
            path: "/api/info",
            credential: credential
        )
    }
}
