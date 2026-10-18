import Foundation
import OpenCodeTransport

/// W06 operations for a paired host (docs/api-contract.md W06,
/// docs/navigation-screens.md S10): the model/agent inventories and the
/// session switches that affect SUBSEQUENT turns.
///
/// Selection identity is `Model.Ref` (`{id, providerID, variant?}`) —
/// never `modelID`. "No default configured" is an honest absence (503 →
/// `nil`), not a failure. Switches answer 204; nothing here streams
/// results (event.subscribe remains W16).
public struct ModelAgentService: Sendable {
    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// `GET /api/model` — the host's model inventory (location-wrapped).
    public func models(at host: URL, credential: BasicCredential?) async throws -> [ModelInfo] {
        try await makeTransport(host)
            .perform(W06Requests.listModels(credential: credential))
            .decodedJSON(LocationEnvelope<[ModelInfo]>.self)
            .data
    }

    /// `GET /api/model/default` — the host's default model when one is
    /// configured. A 503 ("no default available") maps to `nil`: an
    /// unavailable default is absent state, never an error to surface.
    public func defaultModel(at host: URL, credential: BasicCredential?) async throws -> ModelInfo? {
        do {
            return try await makeTransport(host)
                .perform(W06Requests.defaultModel(credential: credential))
                .decodedJSON(LocationEnvelope<ModelInfo>.self)
                .data
        } catch TransportError.http(let status, _) where status == 503 {
            return nil
        }
    }

    /// `GET /api/agent` — every agent the host exposes (location-
    /// wrapped); the picker filters offerable ones client-side.
    public func agents(at host: URL, credential: BasicCredential?) async throws -> [AgentInfo] {
        try await makeTransport(host)
            .perform(W06Requests.listAgents(credential: credential))
            .decodedJSON(LocationEnvelope<[AgentInfo]>.self)
            .data
    }

    /// `GET /api/agent/{agentID}` — one agent; 404 surfaces honestly
    /// when the host does not expose it.
    public func agent(
        id: String,
        at host: URL,
        credential: BasicCredential?
    ) async throws -> AgentInfo {
        try await makeTransport(host)
            .perform(W06Requests.getAgent(agentID: id, credential: credential))
            .decodedJSON(LocationEnvelope<AgentInfo>.self)
            .data
    }

    /// `POST /api/session/{sessionID}/model` → 204. Applies to
    /// subsequent turns; the host's 204 is the only authority — the
    /// caller updates local selection state after this returns.
    public func switchModel(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        to ref: Session.ModelRef
    ) async throws {
        _ = try await makeTransport(host)
            .perform(try W06Requests.switchModel(sessionID: sessionID, model: ref, credential: credential))
    }

    /// `POST /api/session/{sessionID}/agent` → 204; same 204-is-the-
    /// -authority rule as `switchModel`.
    public func switchAgent(
        at host: URL,
        credential: BasicCredential?,
        sessionID: String,
        agent id: String
    ) async throws {
        _ = try await makeTransport(host)
            .perform(try W06Requests.switchAgent(sessionID: sessionID, agent: id, credential: credential))
    }
}
