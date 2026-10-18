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
    private let actionService: SkillCommandService
    private var credentialProvider: CredentialProvider?

    private(set) var models: [ModelInfo] = []
    private(set) var agents: [AgentInfo] = []
    /// Discovered host actions (W07) — listing never implies they can
    /// be installed or edited through these routes.
    private(set) var commands: [CommandInfo] = []
    private(set) var skills: [SkillInfo] = []
    private(set) var defaultModel: ModelInfo?
    /// The session's current `Model.Ref` (selection identity — never a
    /// bare `modelID`).
    private(set) var selectedRef: Session.ModelRef?
    private(set) var selectedAgentID: String?
    private(set) var isLoading = false
    private(set) var isSwitching = false
    /// A command/skill invocation is in flight (W07).
    private(set) var isInvoking = false
    /// Success feedback for a host-confirmed action (S10) — never a
    /// claim about what the host rendered.
    private(set) var notice: String?
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
    /// The (host, session) pair whose transcript the sheet currently
    /// shows. A switch that completes AFTER the user moved to another
    /// session updates that session's remembered selection but must not
    /// paint its result into the wrong (currently visible) transcript.
    private var activeHostID: HostID?
    private var activeSessionID: String?
    /// Which host the visible inventories belong to. On a host change
    /// they are cleared BEFORE any request, so a partial failure can
    /// never leave the previous host's models/agents/commands/skills
    /// offered under the new host.
    private var inventoriesHostID: HostID?
    /// Identifies individual loads: host identity cannot (A → B → A
    /// would pass it again, and A → A reloads are indistinguishable).
    /// Every result, error and busy-flag write checks its load's token.
    private var loadGeneration = 0

    init(
        service: ModelAgentService? = nil,
        actionService: SkillCommandService? = nil,
        credentialProvider: CredentialProvider? = nil
    ) {
        self.service = service ?? ModelAgentService(makeTransport: { URLSessionTransport(baseURL: $0) })
        self.actionService = actionService ?? SkillCommandService(makeTransport: { URLSessionTransport(baseURL: $0) })
        self.credentialProvider = credentialProvider
    }

    /// Late-binds credential access to the host library (SwiftUI creates
    /// view state before the environment is available).
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] id in hosts?.credential(for: id) }
    }

    /// Loads the host's inventories, seeded with the session's CURRENT
    /// selection so checkmarks appear immediately. The snapshot seeds a
    /// (host, session) pair only ONCE: a confirmed switch (or an earlier
    /// seed) is remembered under that identity and always beats the
    /// immutable, possibly-stale snapshot.
    ///
    /// A load superseded mid-flight by ANY newer load — another host,
    /// or the same host again — writes NOTHING at all: results, errors
    /// and the busy flag all check this load's generation token.
    func load(host: OpenCodeDomain.Host, session: Session) async {
        loadGeneration += 1
        let generation = loadGeneration
        func isCurrentLoad() -> Bool { loadGeneration == generation }
        let key = Self.key(hostID: host.id, sessionID: session.id)
        if let known = confirmedBySession[key] {
            selectedRef = known.ref
            selectedAgentID = known.agent
        } else {
            selectedRef = session.model
            selectedAgentID = session.agent
            confirmedBySession[key] = ConfirmedSelection(agent: session.agent, ref: session.model)
        }
        activeHostID = host.id
        activeSessionID = session.id
        if inventoriesHostID != host.id {
            models = []
            agents = []
            defaultModel = nil
            commands = []
            skills = []
            inventoriesHostID = host.id
        }
        guard let credential = credentialProvider?(host.id) else {
            // Superseding with a credential-less host must not leave the
            // previous load's busy flag stuck on.
            isLoading = false
            error = "Re-pair this host to choose a model or agent."
            return
        }
        isLoading = true
        error = nil
        notice = nil
        defer {
            // Only the load that still holds its token resets the busy
            // flag — a superseded load must not clear it under the load
            // that is still fetching.
            if isCurrentLoad() {
                isLoading = false
            }
        }

        // Every write checks this load's generation token: a superseded
        // load's late response belongs to a load that is no longer the
        // current one and must land nowhere.
        var failures: [String] = []
        do {
            let fetched = try await service.models(at: host.address, credential: credential)
            if isCurrentLoad() { models = fetched }
        } catch {
            if isCurrentLoad(), !Self.isSilent(error) {
                failures.append(Self.message(for: error))
            }
        }
        do {
            let fetched = try await service.defaultModel(at: host.address, credential: credential)
            if isCurrentLoad() { defaultModel = fetched }
        } catch {
            if isCurrentLoad(), !Self.isSilent(error) {
                failures.append(Self.message(for: error))
            }
        }
        do {
            let fetched = try await service.agents(at: host.address, credential: credential)
            if isCurrentLoad() { agents = fetched }
        } catch {
            if isCurrentLoad(), !Self.isSilent(error) {
                failures.append(Self.message(for: error))
            }
        }
        do {
            let fetched = try await actionService.commands(at: host.address, credential: credential)
            if isCurrentLoad() { commands = fetched }
        } catch {
            if isCurrentLoad(), !Self.isSilent(error) {
                failures.append(Self.message(for: error))
            }
        }
        do {
            let fetched = try await actionService.skills(at: host.address, credential: credential)
            if isCurrentLoad() { skills = fetched }
        } catch {
            if isCurrentLoad(), !Self.isSilent(error) {
                failures.append(Self.message(for: error))
            }
        }
        if isCurrentLoad() {
            // One host, one problem: collapse duplicate messages (e.g.
            // three identical connection failures) preserving first
            // order. A superseded load contributes nothing.
            var seen = Set<String>()
            let unique = failures.filter { seen.insert($0).inserted }
            error = unique.isEmpty ? nil : unique.joined(separator: " ")
        }
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
        notice = nil
        let ref = model.selectionRef()
        do {
            try await service.switchModel(at: host.address, credential: credential, sessionID: sessionID, to: ref)
            updateConfirmed(hostID: host.id, sessionID: sessionID) { $0.ref = ref }
            if isActive(hostID: host.id, sessionID: sessionID) {
                selectedRef = ref
            }
            error = nil
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
        notice = nil
        do {
            try await service.switchAgent(at: host.address, credential: credential, sessionID: sessionID, agent: agent.id)
            updateConfirmed(hostID: host.id, sessionID: sessionID) { $0.agent = agent.id }
            if isActive(hostID: host.id, sessionID: sessionID) {
                selectedAgentID = agent.id
            }
            error = nil
            sessions?.noteSelection(host: host, sessionID: sessionID, agent: agent.id, model: nil)
            return true
        } catch {
            if !Self.isSilent(error) { self.error = Self.message(for: error) }
            return false
        }
    }

    // MARK: - Command and skill invocation (W07)

    /// Invokes a discovered command in a session. Returns true ONLY on
    /// the host's 204: nothing executes or renders locally, so the
    /// caller re-reads the transcript for the effect. `text` carries the
    /// user's arguments (sent even when empty — schema-required; template
    /// commands expand host-side). A second invocation while one is in
    /// flight is rejected: a double tap must not run a command twice.
    func invokeCommand(
        host: OpenCodeDomain.Host,
        sessionID: String,
        command: CommandInfo,
        text: String = ""
    ) async -> Bool {
        guard !isInvoking else { return false }
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to run commands or skills."
            return false
        }
        isInvoking = true
        defer { isInvoking = false }
        notice = nil
        do {
            try await actionService.invokeCommand(
                at: host.address, credential: credential,
                sessionID: sessionID, name: command.name, text: text
            )
            error = nil
            notice = "Command “\(command.name)” sent — the host works it into the conversation."
            return true
        } catch {
            if !Self.isSilent(error) { self.error = Self.message(for: error) }
            return false
        }
    }

    /// Activates a discovered skill for subsequent turns; same
    /// 204-is-the-only-authority rule as `invokeCommand`, including the
    /// single-flight guard (activation is a real host-side effect too).
    func activateSkill(
        host: OpenCodeDomain.Host,
        sessionID: String,
        skill: SkillInfo
    ) async -> Bool {
        guard !isInvoking else { return false }
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to run commands or skills."
            return false
        }
        isInvoking = true
        defer { isInvoking = false }
        notice = nil
        do {
            try await actionService.activateSkill(
                at: host.address, credential: credential,
                sessionID: sessionID, id: skill.id
            )
            error = nil
            notice = "Skill “\(skill.name)” activated for subsequent turns."
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

    /// Updates ONLY the field a switch confirmed for its target session,
    /// preserving that session's other remembered field — never reading
    /// the currently visible selection, which may already be a different
    /// session if the switch completed late.
    private func updateConfirmed(
        hostID: HostID,
        sessionID: String,
        _ mutate: (inout ConfirmedSelection) -> Void
    ) {
        let key = Self.key(hostID: hostID, sessionID: sessionID)
        var selection = confirmedBySession[key] ?? ConfirmedSelection(agent: nil, ref: nil)
        mutate(&selection)
        confirmedBySession[key] = selection
    }

    private func isActive(hostID: HostID, sessionID: String) -> Bool {
        activeHostID == hostID && activeSessionID == sessionID
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
