import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// S16 integrations state — W14: the effective plugin inventory
/// (docs/navigation-screens.md S16, docs/api-contract.md W14);
/// W15: the runtime MCP segment with its per-server Connect/
/// Disconnect runtime controls.
///
/// Honesty rules: the RUNTIME inventory (`plugin.list`) and the
/// DECLARED directives (`config.get` + raw document bytes) are separate
/// facts combined into rows — a plugin's absence from the runtime list
/// is never presented alone as "disabled". A toggle is a PLAN over the
/// raw JSONC bytes (read → edit → compare-latest-read → write →
/// `location.reload` → authoritative readback); if the saved change is
/// not reflected by the runtime inventory afterwards, the row says so
/// instead of implying success. Built-in/SDK plugins are protected and
/// never offer a disable. W15: a CONNECT/DISCONNECT is a RUNTIME
/// control — 204 is admission and the REFETCHED inventory decides the
/// status shown (never a success claim from the response alone), a
/// `needs_auth` server offers no toggle because sign-in runs on the
/// host, and no MCP row ever implies a persisted enabled flag.
@MainActor
@Observable
final class IntegrationsLibrary {
    typealias CredentialProvider = @MainActor (HostID) -> BasicCredential?

    /// One effective plugin: the union of runtime state and declared
    /// directives across all configuration documents.
    struct PluginRow: Identifiable, Equatable {
        /// Display identity: runtime ID, else the declared target.
        var id: String
        /// The declared target name (nil when nothing declares it —
        /// nothing to toggle in this document).
        var target: String?
        var runtime: PluginInfo?
        /// Document paths positively declaring the target.
        var declaredInPaths: [String]
        /// Document paths whose negative directive disables it.
        var disabledInPaths: [String]
        /// Whether the EDITABLE document is among `disabledInPaths` —
        /// `planToggle` writes only that document, so an Enable offered
        /// for a directive that lives elsewhere could only fail.
        var negativeIsEditable: Bool
        /// Whether an editable document EXISTS that `planToggle` can
        /// write — with none (no session directory, or no document
        /// under it) both toggles could only fail.
        var hasEditableDocument: Bool
        /// Whether that document already carries the top-level
        /// `plugins` array the splice EDITS — the directives are never
        /// created where absent (PluginDirectives doctrine), so
        /// without the array Disable could only fail (a new project's
        /// `opencode.jsonc` is `{}` — W02).
        var editableHasPluginsArray: Bool
        /// Built-in/SDK sources (host policy) may not be disabled.
        var isProtected: Bool
        var statusText: String
        var detailText: String
        var featuresText: String?

        /// Enable appears only for a negatively-declared target whose
        /// negative is in the EDITABLE document; Disable only when the
        /// target is not already disabled, its source is host policy-
        /// free, and an editable document exists to write — an action
        /// that could only fail is never offered.
        var canEnable: Bool { target != nil && negativeIsEditable }
        var canDisable: Bool {
            target != nil && hasEditableDocument && editableHasPluginsArray
                && !isProtected && disabledInPaths.isEmpty
        }
    }

    /// One runtime MCP server in the W15 segment: configured intent,
    /// runtime status and the in-flight control are SEPARATE facts —
    /// Connect/Disconnect acts on the RUNTIME only, never on a
    /// persisted enabled flag (docs/api-contract.md W15).
    struct McpRow: Identifiable, Equatable {
        var name: String
        var status: McpStatus
        /// This location's configuration declares the server with this
        /// `disabled` flag; nil when no document declares it (the
        /// server is host/runtime-provided in this location).
        var configuredDisabled: Bool?

        var id: String { name }

        /// The runtime status as the screen shows it — the pinned
        /// vocabulary, unknown kinds verbatim.
        var statusText: String { IntegrationsLibrary.mcpStatusPhrase(status) }

        /// The CONFIGURED intent line, kept separate from the runtime
        /// status: what this location's documents declare (the
        /// baseline shape is `mcp.servers.<name>` — Config.InfoEncoded
        /// allows no other nesting), nil when none declares it.
        var intentText: String {
            switch configuredDisabled {
            case .some(true): return "Declared DISABLED in this location's configuration."
            case .some(false): return "Declared ENABLED in this location's configuration."
            case nil: return "Not declared in this location's configuration."
            }
        }

        /// Controls appear only where they can mean something:
        /// `pending` is the host mid-work (the refresh shows the
        /// outcome), `needs_auth` needs sign-in on the HOST — a
        /// success toggle offered there could not succeed
        /// (docs/navigation-screens.md S16) — and an unknown status
        /// this baseline cannot label gets no control either.
        var canConnect: Bool {
            guard let kind = status.kind else { return false }
            return kind == .disabled || kind == .failed
        }
        var canDisconnect: Bool { status.kind == .connected }
    }

    /// A confirmed plan awaiting Apply: the exact edit plus the bytes it
    /// was computed against — a changed document invalidates the plan.
    struct PendingPlan: Equatable {
        var target: String
        var enable: Bool
        var directory: String
        /// Absolute document path (the fs.write target).
        var path: String
        /// Location-relative path (fs.read takes relative paths).
        var relativePath: String
        var againstBytes: Data
        var resultingText: String
        var description: String
    }

    private let service: IntegrationsService
    private let projectService: ProjectService
    private var credentialProvider: CredentialProvider?

    private(set) var rows: [PluginRow] = []
    /// A load supersedes an older one; results of stale loads are
    /// discarded (W12 lesson: one token per load).
    private var loadGeneration = 0
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// The project document an editable toggle writes under (nil when
    /// the location reports none — then no toggle is offered).
    private(set) var editableDocument: (directory: String, path: String, relativePath: String)?
    private(set) var isToggling = false
    private(set) var toggleError: String?
    /// Gray banner: honest outcomes (saved, plan invalidated, …).
    private(set) var notice: String?
    private(set) var pendingPlan: PendingPlan?
    /// Targets whose last saved toggle the runtime inventory does NOT
    /// reflect — ineffective overrides stay visible, never glossed.
    private(set) var unreflected: Set<String> = []
    /// The W15 MCP segment: one row per runtime server, rebuilt from
    /// every authoritative inventory read (never mutated by a status
    /// claim alone).
    private(set) var mcpRows: [McpRow] = []
    /// The MCP segment's OWN failure (failed or mismatched `mcp.list`
    /// read) — rendered inside that segment, never as a global error
    /// that would hide the plugin rows (W15 review round 1).
    private(set) var mcpError: String?
    /// The server an in-flight connect/disconnect runs for — the row
    /// shows its pending control while `isToggling` disables every
    /// action on the screen.
    private(set) var mcpActionServer: String?

    init(
        service: IntegrationsService? = nil,
        projectService: ProjectService? = nil,
        credentialProvider: CredentialProvider? = nil
    ) {
        let makeTransport: @Sendable (URL) -> any OpenCodeTransport = { URLSessionTransport(baseURL: $0) }
        self.service = service ?? IntegrationsService(makeTransport: makeTransport)
        self.projectService = projectService ?? ProjectService(makeTransport: makeTransport)
        self.credentialProvider = credentialProvider
    }

    /// Late-binds credential access to the host library (SwiftUI builds
    /// view state before the environment exists).
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] in hosts?.credential(for: $0) }
    }

    /// Loads the effective inventory: runtime plugins, the ordered
    /// configuration documents and the runtime MCP servers in
    /// parallel; the plugin rows need the first two, the MCP segment
    /// the third — an MCP failure degrades only that segment — and a
    /// stale load's result is discarded whole.
    func load(host: OpenCodeDomain.Host, sessionDirectory: String?) async {
        guard !isLoading else { return }
        loadGeneration += 1
        let generation = loadGeneration
        guard let credential = credentialProvider?(host.id) else {
            loadError = "Re-pair this host to read its integrations."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let inventory = try await fetchInventory(
                host: host, credential: credential, sessionDirectory: sessionDirectory
            )
            guard generation == loadGeneration else { return }
            adopt(inventory: inventory, directory: sessionDirectory)
            loadError = nil
        } catch {
            guard generation == loadGeneration else { return }
            if case InventoryError.locationMismatch = error {
                loadError = "The host reports its plugins for a different location than this session's directory."
            } else if !Self.isSilent(error) {
                loadError = Self.message(for: error)
            }
        }
    }

    private enum InventoryError: Error {
        case locationMismatch(requested: String, answered: String)
    }

    /// One inventory read: plugin facts THROW when unusable (the
    /// plugin rows cannot exist without both the runtime inventory
    /// and the directives), while the MCP section's outcome travels
    /// as a Result — an mcp.list failure or scope mismatch clears and
    /// labels the MCP segment only, never hiding the plugin rows the
    /// failure has nothing to do with (W15 review round 1). All three
    /// reads are scoped to `sessionDirectory` (each route declares
    /// `location[directory]` — unscoped, the host answers its default
    /// location whose documents may not live under the session's),
    /// in parallel.
    private func fetchInventory(
        host: OpenCodeDomain.Host,
        credential: BasicCredential?,
        sessionDirectory: String?
    ) async throws -> Inventory {
        async let runtime = service.plugins(
            at: host.address, credential: credential, directory: sessionDirectory
        )
        async let documents = service.configDocuments(
            at: host.address, credential: credential, directory: sessionDirectory
        )
        async let mcp = service.mcpServers(
            at: host.address, credential: credential, directory: sessionDirectory
        )
        let (answeredDirectory, plugins) = try await runtime
        let entries = try await documents
        // Captured without throwing: this section fails alone
        // (adopt() clears it and names the failure).
        let mcpResult: Result<(directory: String, servers: [McpServer]), Error>
        do {
            mcpResult = .success(try await mcp)
        } catch {
            mcpResult = .failure(error)
        }
        if let requested = sessionDirectory, !Self.sameLocation(answeredDirectory, requested) {
            // Combining runtime facts with directives from another
            // scope would render half-truth rows and lie about what
            // is running — refused fail-closed, as before.
            throw InventoryError.locationMismatch(requested: requested, answered: answeredDirectory)
        }
        return (plugins, entries, mcpResult)
    }

    /// The plugin facts of one read (throwing) plus the MCP section's
    /// own outcome — kept apart so one section's trouble never
    /// suppresses the other.
    typealias Inventory = (
        plugins: [PluginInfo],
        entries: [ConfigEntry],
        mcp: Result<(directory: String, servers: [McpServer]), Error>
    )

    /// Rebuilds EVERY section from a freshly fetched inventory —
    /// shared by `load`, the plugin readback and the MCP runtime
    /// action so no path can update one section and leave another
    /// stale. The MCP section is adopted independently: a failed or
    /// mismatched read clears its rows and sets `mcpError` (the view
    /// renders it in that segment), a success rebuilds the rows and
    /// clears the error — never a global failure.
    private func adopt(inventory: Inventory, directory: String?) {
        let editable = Self.editableDocument(in: inventory.entries, sessionDirectory: directory)
        editableDocument = editable
        rows = Self.buildRows(
            plugins: inventory.plugins, entries: inventory.entries, editable: editable
        )
        // Prune ineffective markers for rows no longer present; row
        // IDs cover declared (== target) and runtime keys alike.
        unreflected = unreflected.intersection(rows.map(\.id))
        switch inventory.mcp {
        case .success(let answered, let servers):
            if let requested = directory, !Self.sameLocation(answered, requested) {
                // Fail-closed like the plugin rule: statuses from
                // another scope are never shown under this session —
                // but only this segment is affected.
                mcpRows = []
                mcpError = "The host reports its MCP inventory for a different location than this session's directory."
            } else {
                mcpRows = Self.buildMcpRows(servers: servers, entries: inventory.entries)
                mcpError = nil
            }
        case .failure(let error):
            mcpRows = []
            mcpError = Self.isSilent(error) ? nil : Self.message(for: error)
        }
    }

    /// The authoritative refresh pattern: bump BEFORE the fetch so an
    /// in-flight load's pre-action snapshot can never overwrite this
    /// result (W14 round-4 lesson), then adopt the fresh inventory.
    private func refresh(
        host: OpenCodeDomain.Host, credential: BasicCredential?, directory: String?
    ) async throws -> Inventory {
        loadGeneration += 1
        let inventory = try await fetchInventory(
            host: host, credential: credential, sessionDirectory: directory
        )
        adopt(inventory: inventory, directory: directory)
        return inventory
    }

    /// The host answered FOR the requested directory: equal modulo
    /// trailing slashes (a host may normalise "/srv/demo/" to
    /// "/srv/demo"). Anything else — another directory, an ENCLOSING
    /// or a NESTED scope — is refused fail-closed: an enclosing scope
    /// can show a sibling's plugin as running, a nested one can hide
    /// plugins the session declares, so only the same location's
    /// runtime facts may be combined with its directives
    /// (docs/api-contract.md W14).
    private static func sameLocation(_ answered: String, _ requested: String) -> Bool {
        func normalised(_ path: String) -> String {
            var path = path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path
        }
        return normalised(answered) == normalised(requested)
    }

    /// Plans a toggle against the CURRENT document bytes. The plan is
    /// shown to the user; nothing is written until `applyToggle`.
    func planToggle(
        host: OpenCodeDomain.Host,
        target: String,
        enable: Bool
    ) async {
        pendingPlan = nil
        toggleError = nil
        guard let credential = credentialProvider?(host.id) else {
            toggleError = "Re-pair this host to change plugins."
            return
        }
        guard let document = editableDocument else {
            toggleError = "This location reports no editable configuration document."
            return
        }
        do {
            let file = try await projectService.readFile(
                at: host.address, credential: credential,
                directory: document.directory, path: document.relativePath
            )
            guard let raw = String(data: file.bytes, encoding: .utf8) else {
                toggleError = "The configuration document is not UTF-8 text."
                return
            }
            let edit = enable
                ? PluginDirectives.enable(target, in: raw)
                : PluginDirectives.disable(target, in: raw)
            guard let edit else {
                toggleError = enable
                    ? "No \"-\(target)\" directive exists to remove."
                    : "The document already disables \"\(target)\" or declares no plugins directives."
                return
            }
            pendingPlan = PendingPlan(
                target: target,
                enable: enable,
                directory: document.directory,
                path: document.path,
                relativePath: document.relativePath,
                againstBytes: file.bytes,
                resultingText: edit.resultingText,
                description: edit.description
            )
        } catch {
            if !Self.isSilent(error) { toggleError = Self.message(for: error) }
        }
    }

    /// Cancels a shown plan — nothing was written, nothing changes.
    func cancelPendingPlan() {
        pendingPlan = nil
    }

    /// Applies a confirmed plan: RE-READS the document and only writes
    /// when it is byte-identical to what the plan was computed against
    /// (the contract's compare-latest-read), then reloads the location
    /// and verifies the runtime inventory — an unreflected change stays
    /// visible as an ineffective override.
    ///
    /// The caller PASSES the plan it was shown: dismissing the
    /// confirmation dialog clears `pendingPlan` through the
    /// isPresented setter BEFORE the button's Task gets to run, so
    /// reading state here would find nothing and silently do nothing
    /// (the alert hazard documented in ConversationView).
    func applyToggle(host: OpenCodeDomain.Host, plan: PendingPlan) async {
        guard !isToggling else { return }
        guard let credential = credentialProvider?(host.id) else {
            toggleError = "Re-pair this host to change plugins."
            return
        }
        isToggling = true
        defer { isToggling = false }
        // A new attempt owns the banners: the view renders notice and
        // toggleError independently, so an earlier "Saved" beside an
        // unknown write outcome would contradict it — and a stale
        // error beside a later "Saved, but…" would too.
        notice = nil
        toggleError = nil
        do {
            let latest = try await projectService.readFile(
                at: host.address, credential: credential,
                directory: plan.directory, path: plan.relativePath
            )
            guard latest.bytes == plan.againstBytes else {
                pendingPlan = nil
                notice = "The document changed on the host — review the current plugins directives and retry."
                return
            }
            do {
                try await service.writeFile(
                    at: host.address, credential: credential,
                    directory: plan.directory, path: plan.path,
                    bytes: Data(plan.resultingText.utf8)
                )
            } catch {
                if case TransportError.http(_, _) = error {
                    // The host ANSWERED the write: an HTTP rejection is
                    // definite — nothing landed — so the shared message is
                    // true and the plan (computed against an unchanged
                    // document) stays retryable.
                    toggleError = Self.toggleErrorMessage(for: error)
                    return
                }
                // No usable response — connection lost, timeout, a
                // malformed body, or cancellation mid-save: the bytes
                // may already be on the host. The outcome is UNKNOWN —
                // never claim "not saved" (api-contract.md W14) — and
                // the plan is dropped either way: it may already
                // describe the change, and re-planning must re-read
                // the document. A cancelled save claims nothing
                // (silent by convention) but still drops it.
                pendingPlan = nil
                if !Self.isSilent(error) {
                    toggleError = "The connection dropped during the save — pull to refresh to see whether the change landed."
                }
                return
            }
            // The bytes are on the host now: the plan is spent, and
            // nothing after this point may offer it again.
            pendingPlan = nil
            do {
                try await service.reload(at: host.address, credential: credential)
            } catch {
                if Self.isSilent(error) { return }
                // The WRITE landed — a reload failure is an apply
                // failure, never a save failure ("not saved" after a
                // successful write would be a lie).
                unreflected.insert(plan.target)
                notice = "Saved, but the host could not reload the location."
                return
            }
            // Authoritative readback — fetched DIRECTLY, never through
            // load: a concurrent refresh holds load's single-flight
            // guard, and a silently skipped readback would claim an
            // outcome from stale rows.
            do {
                // `refresh` supersedes any in-flight load BEFORE its
                // fetch (that snapshot must not overwrite this
                // readback) and adopts every section — plugin rows,
                // editable document and the MCP segment alike.
                _ = try await refresh(
                    host: host, credential: credential, directory: plan.directory
                )
                // Joined by row ID: runtime-present rows carry the
                // runtime key (their `target` is nil when nothing
                // declares them).
                let runningAfter = rows.contains { $0.id == plan.target && $0.runtime != nil }
                if plan.enable ? runningAfter : !runningAfter {
                    unreflected.remove(plan.target)
                    notice = "Saved — the host reloaded the location."
                } else {
                    unreflected.insert(plan.target)
                    notice = "Saved, but the host's runtime inventory has not applied it yet."
                }
                toggleError = nil
            } catch {
                if Self.isSilent(error) { return }
                // Saved AND reloaded — only the verification failed.
                // (An MCP-only failure never reaches this: it travels
                // as a Result to `mcpError`, so this verdict reports
                // only plugin/config facts.)
                if case InventoryError.locationMismatch = error {
                    notice = "Saved, but the host reports its plugins for a different location."
                } else {
                    notice = "Saved, but the host's runtime inventory could not be read."
                }
            }
        } catch {
            if !Self.isSilent(error) { toggleError = Self.toggleErrorMessage(for: error) }
        }
    }

    // MARK: - W15 MCP runtime controls

    /// A RUNTIME connect/disconnect for the W15 MCP segment
    /// (docs/api-contract.md W15). Honesty rules: 204 is ADMISSION —
    /// the REFETCHED inventory decides the status shown, never the
    /// response alone; a definite HTTP rejection (other than 404)
    /// means the host answered "no", so nothing changed and the rows
    /// stand; a 404 or a response-less failure may have changed the
    /// host, so the list is refreshed and the banner names what is
    /// actually known. Banners are owned by this attempt: the view
    /// renders notice and toggleError independently (W14 round 6).
    func mcpAction(
        host: OpenCodeDomain.Host,
        server: String,
        connect: Bool,
        sessionDirectory: String?
    ) async {
        guard !isToggling else { return }
        guard let credential = credentialProvider?(host.id) else {
            toggleError = "Re-pair this host to control its MCP runtime."
            return
        }
        isToggling = true
        defer { isToggling = false }
        // A new attempt owns the banners — an earlier "Saved" beside a
        // later unknown outcome would contradict it.
        notice = nil
        toggleError = nil
        mcpActionServer = server
        defer { mcpActionServer = nil }

        var failure: Error?
        do {
            if connect {
                try await service.mcpConnect(
                    at: host.address, credential: credential,
                    server: server, directory: sessionDirectory
                )
            } else {
                try await service.mcpDisconnect(
                    at: host.address, credential: credential,
                    server: server, directory: sessionDirectory
                )
            }
        } catch {
            if Self.isSilent(error) { return }
            failure = error
        }

        // The host ANSWERED with a rejection (404 is handled below: it
        // means this list itself is stale): the runtime did not change,
        // so the rows stand and the message names the actual failure.
        if let failure, case TransportError.http(let status, _) = failure, status != 404 {
            toggleError = Self.mcpFailureMessage(for: failure, server: server, desired: connect)
            return
        }

        // Admitted (204), a vanished server (404), or a response-less
        // attempt: only the current inventory can say what the runtime
        // now is.
        do {
            _ = try await refresh(
                host: host, credential: credential, directory: sessionDirectory
            )
        } catch {
            if Self.isSilent(error) { return }
            if let failure {
                toggleError = Self.mcpFailureMessage(
                    for: failure, server: server, desired: connect
                )
            } else {
                notice = "The change was accepted, but the refreshed inventory could not be read."
            }
            return
        }

        // The refresh itself answered for the plugin facts, but the
        // MCP segment's own read failed (`mcpError`, rows cleared) —
        // the runtime status stays UNKNOWN and the banner says so
        // rather than presenting cleared rows as an absent server.
        if mcpError != nil {
            if let failure {
                toggleError = Self.mcpFailureMessage(
                    for: failure, server: server, desired: connect
                )
            } else {
                notice = "The change was accepted, but the MCP inventory could not be read."
            }
            return
        }

        let current = mcpRows.first { $0.name == server }
        guard let failure else {
            // 204 admission: judge ONLY by the refetched status.
            if let current, Self.desiredMatches(current.status, connect: connect) {
                notice = Self.mcpReportedMessage(server: server, connect: connect)
            } else if let current {
                notice = "The host accepted the change, but still reports \"\(server)\" as \(Self.mcpStatusPhrase(current.status))."
            } else {
                notice = "The host accepted the change, but no longer reports \"\(server)\"."
            }
            return
        }

        // The attempt failed, but the refreshed list may show it took
        // effect anyway (a lost response after a landed change).
        if let current, Self.desiredMatches(current.status, connect: connect) {
            notice = Self.mcpReportedMessage(server: server, connect: connect)
        } else {
            toggleError = Self.mcpFailureMessage(
                for: failure, server: server, desired: connect,
                refreshed: true, status: current?.status
            )
        }
    }

    /// The success notice — never written from the 204 itself, only
    /// from a refetched row that shows the desired status.
    private static func mcpReportedMessage(server: String, connect: Bool) -> String {
        "The host now reports \"\(server)\" as \(connect ? "connected" : "disabled")."
    }

    private static func desiredMatches(_ status: McpStatus, connect: Bool) -> Bool {
        status.kind == (connect ? .connected : .disabled)
    }

    /// Names the ACTUAL failure (house rule). An HTTP rejection is
    /// definite — the host answered, nothing landed; a 404 means the
    /// server left the host (after a refresh the list is already
    /// current, without one the user is told what stands); a
    /// response-less failure is UNKNOWN: with a fresh read it says
    /// what the host does not report, without one it says to refresh.
    private static func mcpFailureMessage(
        for error: Error,
        server: String,
        desired: Bool,
        refreshed: Bool = false,
        status: McpStatus? = nil
    ) -> String {
        if case TransportError.http(let statusCode, _) = error {
            if statusCode == 404 {
                // The REFRESHED LIST is the evidence: when it still
                // shows the server, "does not report it" would be a
                // lie printed under the row itself — name the status
                // the refresh actually reports (W15 review round 1).
                if refreshed, let status {
                    return "The host answered HTTP 404 for \"\(server)\"; the refreshed list shows it as \(mcpStatusPhrase(status))."
                }
                return refreshed
                    ? "The host does not report an MCP server named \"\(server)\" — the list was refreshed."
                    : "The host does not report an MCP server named \"\(server)\", and the list could not be refreshed."
            }
            return "The host rejected the MCP runtime change (HTTP \(statusCode))."
        }
        let wanted = desired ? "connected" : "disabled"
        if refreshed, let status {
            return "The connection dropped during the MCP change — the host does not report \"\(server)\" as \(wanted); it shows \(mcpStatusPhrase(status))."
        }
        if refreshed {
            return "The connection dropped during the MCP change — the host no longer reports \"\(server)\"."
        }
        return "The connection dropped during the MCP change — pull to refresh to see whether it landed."
    }

    /// The user-facing phrase for a runtime status: the pinned five
    /// get their documented vocabulary; an unknown kind shows its raw
    /// string verbatim (never a guessed mapping — house rule for
    /// DECODED values hosts may evolve). `nonisolated`: McpRow's
    /// display properties are plain struct members, not actor state.
    nonisolated static func mcpStatusPhrase(_ status: McpStatus) -> String {
        guard let kind = status.kind else { return "\"\(status.rawKind)\"" }
        switch kind {
        case .connected: return "Connected"
        case .pending: return "Pending"
        case .disabled: return "Disabled"
        case .failed: return "Failed: \(status.error ?? "no detail reported")"
        case .needsAuth: return "Needs authentication: \(status.error ?? "sign-in required")"
        }
    }

    // MARK: - Row building (pure)

    private struct DocumentFacts {
        var path: String
        var positives: Set<String>
        var negatives: Set<String>
    }

    private static func documents(in entries: [ConfigEntry]) -> [DocumentFacts] {
        entries.compactMap { entry in
            guard case .document(let path, let info) = entry, let path else { return nil }
            guard case .object(let fields) = info,
                  case .array(let plugins)? = fields["plugins"] else {
                return DocumentFacts(path: path, positives: [], negatives: [])
            }
            var positives: Set<String> = []
            var negatives: Set<String> = []
            for element in plugins {
                guard case .string(let name) = element else { continue }
                if name.hasPrefix("-") {
                    negatives.insert(String(name.dropFirst()))
                } else {
                    positives.insert(name)
                }
            }
            return DocumentFacts(path: path, positives: positives, negatives: negatives)
        }
    }

    /// The document a toggle WRITES: the one under the session's own
    /// directory. Documents outside it (global config) stay scope-only —
    /// the app never edits a file it cannot attribute to this location.
    private static func editableDocument(
        in entries: [ConfigEntry], sessionDirectory: String?
    ) -> (directory: String, path: String, relativePath: String)? {
        guard let sessionDirectory, !sessionDirectory.isEmpty else { return nil }
        for entry in entries {
            guard case .document(let path, _) = entry, let path else { continue }
            let prefix = sessionDirectory.hasSuffix("/") ? sessionDirectory : sessionDirectory + "/"
            guard path.hasPrefix(prefix) else { continue }
            return (sessionDirectory, path, String(path.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func buildRows(
        plugins: [PluginInfo],
        entries: [ConfigEntry],
        editable: (directory: String, path: String, relativePath: String)?
    ) -> [PluginRow] {
        let docs = documents(in: entries)
        // The editable document must CARRY the plugins array the
        // splice edits: disable/enable never CREATE the key, so an
        // offered toggle against a `{}` document (the W02
        // new-project default) could only fail.
        let editableHasPluginsArray: Bool = {
            guard let editable else { return false }
            for entry in entries {
                guard case .document(let path, let info) = entry, path == editable.path else {
                    continue
                }
                guard case .object(let fields) = info, case .array? = fields["plugins"] else {
                    return false
                }
                return true
            }
            return false
        }()
        var rows: [String: PluginRow] = [:]
        var order: [String] = []

        func row(for key: String) -> PluginRow {
            if let existing = rows[key] { return existing }
            order.append(key)
            return PluginRow(
                id: key, target: nil, runtime: nil,
                declaredInPaths: [], disabledInPaths: [], negativeIsEditable: false,
                hasEditableDocument: false, editableHasPluginsArray: false,
                isProtected: false, statusText: "", detailText: "", featuresText: nil
            )
        }

        // Declared directives first: the document facts anchor identity.
        for doc in docs {
            for target in doc.positives.union(doc.negatives).sorted() {
                var row = row(for: target)
                row.target = target
                if doc.positives.contains(target) { row.declaredInPaths.append(doc.path) }
                if doc.negatives.contains(target) { row.disabledInPaths.append(doc.path) }
                rows[target] = row
            }
        }
        // Runtime plugins join by ID, falling back to the package
        // target when the ID names no row: the schema does NOT
        // guarantee id == source.target, and a plugin that missed the
        // join would show as two half-truths — declared-not-running
        // beside active-without-toggle — with the readback reporting a
        // successful enable as "not applied yet".
        for plugin in plugins {
            var key = runtimeKey(plugin)
            if rows[key] == nil, case .package(let target, _, _, _) = plugin.source,
               rows[target] != nil {
                key = target
            }
            // Id-less built-in/SDK plugins share ONE constant key: give
            // every occurrence after the first its own, or two host
            // built-ins collapse into a single row (the later one
            // overwrites the earlier runtime) and the inspector hides
            // part of the effective inventory. The first occurrence
            // keeps the base key so a declared directive with that
            // name still joins.
            if isConstantRuntimeKey(plugin), rows[key]?.runtime != nil {
                var occurrence = 2
                var candidate = "\(key)#\(occurrence)"
                while rows[candidate]?.runtime != nil {
                    occurrence += 1
                    candidate = "\(key)#\(occurrence)"
                }
                key = candidate
            }
            var row = row(for: key)
            row.runtime = plugin
            if row.target == nil {
                row.target = docs.contains { $0.positives.contains(key) || $0.negatives.contains(key) }
                    ? key : nil
            }
            row.isProtected = row.isProtected || isProtectedSource(plugin.source)
            rows[key] = row
        }
        // Finalise status/detail for every row.
        return order.compactMap { key in
            guard var row = rows[key] else { return nil }
            row.hasEditableDocument = editable != nil
            row.editableHasPluginsArray = editableHasPluginsArray
            let running = row.runtime != nil
            let disabled = !row.disabledInPaths.isEmpty
            let declared = !row.declaredInPaths.isEmpty || disabled
            if case .failed(let error, _)? = row.runtime?.state {
                row.statusText = "Failed: \(error)"
            } else if running {
                row.statusText = "Active"
            } else if disabled {
                row.statusText = "Disabled in config"
            } else if declared {
                row.statusText = "Declared, not running"
            } else {
                row.statusText = "Not running"
            }
            row.detailText = sourceDetail(row.runtime?.source)
            row.featuresText = featuresText(row.runtime?.features)
            // Only a negative inside the EDITABLE document can be
            // removed by a toggle — an Enable offered for a directive
            // elsewhere could only fail.
            row.negativeIsEditable = editable.map { row.disabledInPaths.contains($0.path) } ?? false
            if row.isProtected { row.statusText += " (protected)" }
            return row
        }
    }

    /// Builds the W15 MCP segment: one row per runtime server, joined
    /// with the CONFIGURED intent declared in this location's
    /// documents (`mcp.servers.<name>`, baseline Config.InfoEncoded —
    /// `mcp` has `additionalProperties: false`, so this is the only
    /// nesting). config.get answers LOW → HIGH precedence, so the
    /// LAST declaration of a name wins — the same join rule the
    /// plugin rows use. A name no document declares stays nil: the
    /// server is host/runtime-provided here, never "declared
    /// disabled" by absence.
    private static func buildMcpRows(
        servers: [McpServer], entries: [ConfigEntry]
    ) -> [McpRow] {
        var declared: [String: Bool] = [:]
        for entry in entries {
            guard case .document(let path, let info) = entry, let path,
                  case .object(let fields) = info,
                  case .object(let mcp)? = fields["mcp"],
                  case .object(let declaredServers)? = mcp["servers"]
            else { continue }
            for (name, value) in declaredServers {
                guard case .object(let config) = value else { continue }
                // Declared without the `disabled` flag = enabled.
                if case .bool(let disabled)? = config["disabled"] {
                    declared[name] = disabled
                } else {
                    declared[name] = false
                }
            }
        }
        return servers.map { server in
            McpRow(
                name: server.name,
                status: server.status,
                configuredDisabled: declared[server.name]
            )
        }
    }

    private static func runtimeKey(_ plugin: PluginInfo) -> String {
        if let id = plugin.id { return id }
        if case .package(let target, _, _, _) = plugin.source { return target }
        if case .local(let path) = plugin.source { return path }
        if case .unknown(let type) = plugin.source { return "unknown:\(type)" }
        return plugin.source == .builtin ? "built-in" : "sdk"
    }

    /// Whether `runtimeKey` fell through to a CONSTANT (the plugin has
    /// no id, package target, local path or unknown type to name it
    /// by) — only such keys need per-occurrence uniquification; keys
    /// from id/target/path are join keys and stay untouched.
    private static func isConstantRuntimeKey(_ plugin: PluginInfo) -> Bool {
        if plugin.id != nil { return false }
        switch plugin.source {
        case .builtin, .sdk: return true
        case .package, .local, .unknown: return false
        }
    }

    private static func isProtectedSource(_ source: PluginInfo.Source) -> Bool {
        switch source {
        case .builtin, .sdk: return true
        default: return false
        }
    }

    private static func sourceDetail(_ source: PluginInfo.Source?) -> String {
        guard let source else { return "Not in the runtime inventory." }
        switch source {
        case .builtin:
            return "Built-in (host policy)."
        case .sdk:
            return "SDK-provided (host policy)."
        case .package(let target, let version, let outdated, let updating):
            var text = "Package \(target)"
            if let version { text += " v\(version)" }
            if outdated { text += " — update available" }
            if updating { text += " — updating" }
            return text + "."
        case .local(let path):
            return "Local \(path)."
        case .unknown(let type):
            return "Source \"\(type)\" is outside this app's known set."
        }
    }

    private static func featuresText(_ features: PluginInfo.Features?) -> String? {
        guard let features else { return nil }
        var names: [String] = []
        if features.server { names.append("server") }
        if features.tui { names.append("tui") }
        if features.rpc { names.append("rpc") }
        return names.isEmpty ? nil : "Features: \(names.joined(separator: ", "))."
    }

    // MARK: - Errors

    private static func isSilent(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case TransportError.cancelled = error { return true }
        return false
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not load integrations (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable right now. Pull to refresh to try again."
        default:
            return "Integrations could not be loaded from this host."
        }
    }

    /// "Not saved" is only ever emitted where it is TRUE, from two
    /// places: applyToggle's COMPARE-READ phase (nothing was written
    /// yet) and the WRITE phase's HTTP clause (the host answered with
    /// a rejection — nothing landed). Response-less write failures
    /// never reach this — they are reported as an unknown outcome.
    private static func toggleErrorMessage(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not save the plugin change (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable — the change was not saved."
        default:
            return "The plugin change could not be saved."
        }
    }
}
