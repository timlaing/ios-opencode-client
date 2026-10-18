import Foundation

/// `Command.Info` (`GET /api/command`): discovered host commands. `name`
/// is the schema-required identity (`CommandInput.name` on invoke) —
/// discovery never implies the command can be installed or edited
/// through these routes (docs/api-contract.md W07).
public struct CommandInfo: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var description: String?

    public var id: String { name }

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// `Skill.Info` (`GET /api/skill`): discovered host skills. `id`,
/// `name`, `path` and `content` are schema-required; `description` and
/// `autoinvoke` when reported. Activation is `{id,resume?}` — discovery
/// never implies editability through these routes.
public struct SkillInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var autoinvoke: Bool?
    public var path: String
    public var content: String

    public init(
        id: String, name: String, description: String? = nil,
        autoinvoke: Bool? = nil, path: String, content: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.autoinvoke = autoinvoke
        self.path = path
        self.content = content
    }
}

/// W07 request builders (docs/api-contract.md W07, S08/S10): action
/// discovery plus the two invocation routes. Both invocations answer
/// 204 — the host applies them itself; the client never executes a
/// command or skill locally.
public enum W07Requests {
    /// `GET /api/command` — location-wrapped command list.
    public static func listCommands(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "command.list",
            method: .get,
            path: "/api/command",
            credential: credential
        )
    }

    /// `GET /api/skill` — location-wrapped skill list.
    public static func listSkills(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "skill.list",
            method: .get,
            path: "/api/skill",
            credential: credential
        )
    }

    /// `POST /api/session/{sessionID}/command` — `{name,text}` → 204.
    /// `text` is schema-REQUIRED even when the argument is empty (a
    /// template command expands on the host). `files`/`agents`/`skills`
    /// are attachment scope (W08/W06) and are not sent yet;
    /// `additionalProperties:false` forbids invented keys.
    public static func invokeCommand(
        sessionID: String,
        name: String,
        text: String,
        delivery: InboxDelivery? = nil,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        try APIRequest.jsonBody(
            operationID: "session.command",
            method: .post,
            path: "/api/session/\(sessionID)/command",
            value: CommandInvokeBody(name: name, text: text, delivery: delivery),
            credential: credential
        )
    }

    /// `POST /api/experimental/session/{sessionID}/skill` — `{id,
    /// resume?}` → 204.
    public static func activateSkill(
        sessionID: String,
        id: String,
        resume: Bool? = nil,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        try APIRequest.jsonBody(
            operationID: "experimental.session.skill",
            method: .post,
            path: "/api/experimental/session/\(sessionID)/skill",
            value: SkillActivateBody(id: id, resume: resume),
            credential: credential
        )
    }

    struct CommandInvokeBody: Encodable {
        var name: String
        var text: String
        var delivery: InboxDelivery?
    }

    struct SkillActivateBody: Encodable {
        var id: String
        var resume: Bool?
    }
}
