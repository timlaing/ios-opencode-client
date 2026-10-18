import Foundation
import OpenCodeTransport

/// W07 operations for a paired host (docs/api-contract.md W07,
/// docs/navigation-screens.md S08/S10): action discovery and the two
/// host-side invocations.
///
/// Discovery lists what the host exposes — it never implies a command
/// or skill can be installed or edited through these routes. Both
/// invocations are 204-authoritative and execute NOTHING locally: the
/// host applies the command/skill itself (typically to subsequent
/// turns), so the caller re-reads the transcript after a 204 instead of
/// rendering a local result.
public struct SkillCommandService: Sendable {
    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// `GET /api/command` — the host's command inventory
    /// (location-wrapped).
    public func commands(at host: URL, credential: BasicCredential?) async throws -> [CommandInfo] {
        try await makeTransport(host)
            .perform(W07Requests.listCommands(credential: credential))
            .decodedJSON(LocationEnvelope<[CommandInfo]>.self)
            .data
    }

    /// `GET /api/skill` — the host's skill inventory (location-wrapped).
    public func skills(at host: URL, credential: BasicCredential?) async throws -> [SkillInfo] {
        try await makeTransport(host)
            .perform(W07Requests.listSkills(credential: credential))
            .decodedJSON(LocationEnvelope<[SkillInfo]>.self)
            .data
    }

    /// `POST /api/session/{sessionID}/command` → 204. `text` is required
    /// by the schema even when empty (template commands expand host-side).
    public func invokeCommand(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        name: String,
        text: String,
        delivery: InboxDelivery? = nil
    ) async throws {
        _ = try await makeTransport(host)
            .perform(try W07Requests.invokeCommand(
                sessionID: sessionID, name: name, text: text,
                delivery: delivery, credential: credential
            ))
    }

    /// `POST /api/experimental/session/{sessionID}/skill` → 204.
    public func activateSkill(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        id: String,
        resume: Bool? = nil
    ) async throws {
        _ = try await makeTransport(host)
            .perform(try W07Requests.activateSkill(
                sessionID: sessionID, id: id, resume: resume, credential: credential
            ))
    }
}
