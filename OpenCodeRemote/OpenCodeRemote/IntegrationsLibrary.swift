import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// S16 integrations state — W14: the effective plugin inventory
/// (docs/navigation-screens.md S16, docs/api-contract.md W14).
///
/// Honory rules: the RUNTIME inventory (`plugin.list`) and the
/// DECLARED directives (`config.get` + raw document bytes) are separate
/// facts combined into rows — a plugin's absence from the runtime list
/// is never presented alone as "disabled". A toggle is a PLAN over the
/// raw JSONC bytes (read → edit → compare-latest-read → write →
/// `location.reload` → authoritative readback); if the saved change is
/// not reflected by the runtime inventory afterwards, the row says so
/// instead of implying success. Built-in/SDK plugins are protected and
/// never offer a disable.
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
        /// Built-in/SDK sources (host policy) may not be disabled.
        var isProtected: Bool
        var statusText: String
        var detailText: String
        var featuresText: String?

        /// Enable appears only for a negatively-declared target;
        /// Disable only when the target is not already disabled and its
        /// source is host policy-free. (The editable-document gate lives
        /// in `planToggle`, which reports honestly when there is none.)
        var canEnable: Bool { target != nil && !disabledInPaths.isEmpty }
        var canDisable: Bool { target != nil && !isProtected && disabledInPaths.isEmpty }
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

    /// Loads the effective inventory: runtime plugins and the ordered
    /// configuration documents in parallel; the rows need BOTH and a
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
            async let runtime = service.plugins(at: host.address, credential: credential)
            async let documents = service.configDocuments(at: host.address, credential: credential)
            let (_, plugins) = try await runtime
            let entries = try await documents
            guard generation == loadGeneration else { return }
            let editable = Self.editableDocument(in: entries, sessionDirectory: sessionDirectory)
            editableDocument = editable
            rows = Self.buildRows(plugins: plugins, entries: entries, editable: editable)
            // Prune ineffective markers for rows no longer present;
            // row IDs cover declared (== target) and runtime keys alike.
            unreflected = unreflected.intersection(rows.map(\.id))
            loadError = nil
        } catch {
            guard generation == loadGeneration else { return }
            if !Self.isSilent(error) { loadError = Self.message(for: error) }
        }
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
            try await service.writeFile(
                at: host.address, credential: credential,
                directory: plan.directory, path: plan.path,
                bytes: Data(plan.resultingText.utf8)
            )
            try await service.reload(at: host.address, credential: credential)
            pendingPlan = nil
            // Authoritative readback: the runtime inventory decides
            // whether the saved directive is actually in effect.
            let directory = plan.directory
            let target = plan.target
            let enable = plan.enable
            await load(host: host, sessionDirectory: directory)
            // Joined by row ID: runtime-present rows carry the runtime
            // key (their `target` is nil when nothing declares them).
            let runningAfter = rows.contains { $0.id == target && $0.runtime != nil }
            if enable ? runningAfter : !runningAfter {
                unreflected.remove(target)
                notice = "Saved — the host reloaded the location."
            } else {
                unreflected.insert(target)
                notice = "Saved, but the host's runtime inventory has not applied it yet."
            }
            toggleError = nil
        } catch {
            if !Self.isSilent(error) { toggleError = Self.toggleErrorMessage(for: error) }
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
        var rows: [String: PluginRow] = [:]
        var order: [String] = []

        func row(for key: String) -> PluginRow {
            if let existing = rows[key] { return existing }
            order.append(key)
            return PluginRow(
                id: key, target: nil, runtime: nil,
                declaredInPaths: [], disabledInPaths: [],
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
            if row.isProtected { row.statusText += " (protected)" }
            return row
        }
    }

    private static func runtimeKey(_ plugin: PluginInfo) -> String {
        if let id = plugin.id { return id }
        if case .package(let target, _, _, _) = plugin.source { return target }
        if case .local(let path) = plugin.source { return path }
        if case .unknown(let type) = plugin.source { return "unknown:\(type)" }
        return plugin.source == .builtin ? "built-in" : "sdk"
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
