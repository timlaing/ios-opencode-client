import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// S10 model/agent selection state (W06, docs/api-contract.md W06,
/// docs/navigation-screens.md S10): the host's inventories plus the two
/// session switches that affect SUBSEQUENT turns.
///
/// Honesty rules: local selection is claimed ONLY after the host's 204;
/// a rejected switch surfaces the failure and the previous selection
/// stays visible. The two inventories load independently — one failing
/// must not erase the other — and a total failure carries its own retry
/// (the sheet's `.task` re-runs the load).
@MainActor
@Observable
final class SelectionLibrary {
    typealias CredentialProvider = @MainActor (HostID) -> BasicCredential?

    private let service: ModelAgentService
    private var credentialProvider: CredentialProvider?

    private(set) var models: [ModelInfo] = []
    private(set) var agents: [AgentInfo] = []
    private(set) var defaultModel: ModelInfo?
    /// The session's current `Model.Ref` (selection identity — never a
    /// bare `modelID`).
    private(set) var selectedRef: Session.ModelRef?
    private(set) var selectedAgentID: String?
    private(set) var isLoading = false
    private(set) var isSwitching = false
    private(set) var error: String?

    /// The last known selection per (host, session). Session identity
    /// is the PAIR: two hosts may have sessions with the same session
    /// ID, and each seeds from its own snapshot. A confirmed switch is
    /// remembered here, so reopening a sheet or switching A → B → A
    /// never restores A from its stale immutable snapshot.
    private struct ConfirmedSelection {
        var agent: String?
        var ref: Session.ModelRef?
    }

    private var confirmedBySession: [String: ConfirmedSelection] = [:]

    init(service: ModelAgentService? = nil, credentialProvider: CredentialProvider? = nil) {
        self.service = service ?? ModelAgentService(makeTransport: { URLSessionTransport(baseURL: $0) })
        self.credentialProvider = credentialProvider
    }

    /// Late-binds credential access to the host library (SwiftUI creates
    /// view state before the environment is available).
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] id in hosts?.credential(for: id) }
    }

    /// Loads both inventories and the host default, seeded with the
    /// session's CURRENT selection so checkmarks appear immediately.
    /// The snapshot seeds a (host, session) pair only ONCE: a confirmed
    /// switch (or an earlier seed) is remembered under that identity and
    /// always beats the immutable, possibly-stale snapshot.
    func load(host: OpenCodeDomain.Host, session: Session) async {
        let key = Self.key(hostID: host.id, sessionID: session.id)
        if let known = confirmedBySession[key] {
            selectedRef = known.ref
            selectedAgentID = known.agent
        } else {
            selectedRef = session.model
            selectedAgentID = session.agent
            confirmedBySession[key] = ConfirmedSelection(agent: session.agent, ref: session.model)
        }
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to choose a model or agent."
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }

        var failures: [String] = []
        do {
            models = try await service.models(at: host.address, credential: credential)
        } catch {
            if !Self.isSilent(error) { failures.append(Self.message(for: error)) }
        }
        do {
            defaultModel = try await service.defaultModel(at: host.address, credential: credential)
        } catch {
            if !Self.isSilent(error) { failures.append(Self.message(for: error)) }
        }
        do {
            agents = try await service.agents(at: host.address, credential: credential)
        } catch {
            if !Self.isSilent(error) { failures.append(Self.message(for: error)) }
        }
        // One host, one problem: collapse duplicate messages (e.g. three
        // identical connection failures) while preserving first order.
        var seen = Set<String>()
        let unique = failures.filter { seen.insert($0).inserted }
        error = unique.isEmpty ? nil : unique.joined(separator: " ")
    }

    /// Switches the session's model for subsequent turns. Returns true
    /// ONLY on the host's 204 — the local selection and the sessions
    /// store are updated at that instant, never optimistically.
    func selectModel(
        host: OpenCodeDomain.Host,
        sessionID: String,
        model: ModelInfo,
        sessions: SessionsLibrary? = nil
    ) async -> Bool {
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to change the model."
            return false
        }
        isSwitching = true
        defer { isSwitching = false }
        let ref = model.selectionRef()
        do {
            try await service.switchModel(at: host.address, credential: credential, sessionID: sessionID, to: ref)
            selectedRef = ref
            error = nil
            rememberConfirmed(hostID: host.id, sessionID: sessionID)
            sessions?.noteSelection(host: host, sessionID: sessionID, agent: nil, model: ref)
            return true
        } catch {
            if !Self.isSilent(error) { self.error = Self.message(for: error) }
            return false
        }
    }

    /// Switches the session's agent; same 204-is-the-only-authority rule
    /// as `selectModel`.
    func selectAgent(
        host: OpenCodeDomain.Host,
        sessionID: String,
        agent: AgentInfo,
        sessions: SessionsLibrary? = nil
    ) async -> Bool {
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to change the agent."
            return false
        }
        isSwitching = true
        defer { isSwitching = false }
        do {
            try await service.switchAgent(at: host.address, credential: credential, sessionID: sessionID, agent: agent.id)
            selectedAgentID = agent.id
            error = nil
            rememberConfirmed(hostID: host.id, sessionID: sessionID)
            sessions?.noteSelection(host: host, sessionID: sessionID, agent: agent.id, model: nil)
            return true
        } catch {
            if !Self.isSilent(error) { self.error = Self.message(for: error) }
            return false
        }
    }

    // MARK: - Confirmed-selection memory

    /// Session identity is the (host, session) PAIR — the same session
    /// ID on two different hosts is two different selections.
    private static func key(hostID: HostID, sessionID: String) -> String {
        "\(hostID.rawValue)/\(sessionID)"
    }

    private func rememberConfirmed(hostID: HostID, sessionID: String) {
        confirmedBySession[Self.key(hostID: hostID, sessionID: sessionID)] = ConfirmedSelection(
            agent: selectedAgentID, ref: selectedRef
        )
    }

    // MARK: - Error handling (mirrors ConversationLibrary)

    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host rejected the request (HTTP \(status))."
        case TransportError.connectionFailed:
            return "Connection failed — the host may be unreachable."
        default:
            return "The request failed."
        }
    }

    private static func isSilent(_ error: Error) -> Bool {
        error is CancellationError
    }
}
