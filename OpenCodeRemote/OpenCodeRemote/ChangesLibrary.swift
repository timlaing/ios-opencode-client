import Foundation
import OpenCodeDomain
import OpenCodeTransport

/// Pure decisions + load orchestration for the S15 Changes inspector
/// (docs/navigation-screens.md S15, docs/api-contract.md W12/W13): a
/// session-turn scope (`session.diff` over the transcript's user turns)
/// and a workspace scope (`vcs.get`/`status`/`base`/`diff` over the
/// location). The view renders decisions made here.
///
/// Load invariants: one generation token per load — every selector
/// change bumps it and a completion that no longer matches is discarded
/// AFTER its await, including its error and its loading-flag bookkeeping,
/// which the newer load owns. Revisited scopes keep their adopted state
/// while reloading; `loadIfNeeded` never refetches a scope already
/// loaded (back-navigation from a detail view is free).
@MainActor
@Observable
final class ChangesLibrary {
    /// Which changes the inspector shows.
    enum Scope: String, CaseIterable, Identifiable {
        case sessionTurn
        case workspace
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sessionTurn: return "Session"
            case .workspace: return "Workspace"
            }
        }
    }

    /// Sections that load, fail and render independently.
    enum Section: Hashable {
        case sessionTurn
        case workspaceHeader
        case workspaceDiff
    }

    /// The host's review base. `unavailable` (the host answered that it
    /// has no base) is a DISTINCT state from `unloaded` and from a
    /// failure — never an empty successful diff (docs/api-contract.md
    /// W12/W13).
    enum BaseState: Equatable {
        case unloaded
        case unavailable
        case available(Vcs.Base)
    }

    /// Everything a load needs; the view builds it per call site.
    struct Inputs {
        var host: OpenCodeDomain.Host
        var credential: BasicCredential?
        var sessionID: String
        /// nil when the session has no workspace location — the
        /// workspace scope then fails honestly without any request.
        var directory: String?
    }

    /// One user turn offered by the range pickers (`msg_` IDs are the
    /// wire's `from`/`to` tokens).
    struct TurnOption: Identifiable, Equatable {
        let id: String
        let preview: String
    }

    // MARK: Selectors and services

    private let historyService: SessionHistoryService
    private let vcsService: VcsService

    private(set) var scope: Scope = .sessionTurn
    /// nil = the newest user turn (the host's default).
    private(set) var turnFrom: String?
    /// nil = `from`'s turn alone.
    private(set) var turnTo: String?
    /// Context expansion: full-file patches when true, three context
    /// lines around hunks when false.
    private(set) var fullFile = false
    private(set) var diffMode: Vcs.Mode = .working

    // MARK: Adopted state

    private(set) var sessionFiles: [FileDiff.Info]?
    private(set) var branchInfo: Vcs.Info?
    private(set) var baseState: BaseState = .unloaded
    private(set) var statusFiles: [Vcs.FileStatus]?
    private(set) var diffFiles: [FileDiff.Info]?

    private(set) var errors: [Section: String] = [:]
    private(set) var loading: Set<Section> = []
    private(set) var loadedScopes: Set<Scope> = []

    /// Single stale-result token (see the type doc).
    private var generation = 0

    init(
        historyService: SessionHistoryService? = nil,
        vcsService: VcsService? = nil,
        makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport = { URLSessionTransport(baseURL: $0) }
    ) {
        self.historyService = historyService ?? SessionHistoryService(makeTransport: makeTransport)
        self.vcsService = vcsService ?? VcsService(makeTransport: makeTransport)
    }

    // MARK: Selectors (mutate, then reload what changed)

    func setScope(_ scope: Scope, _ inputs: Inputs) {
        guard scope != self.scope else { return }
        self.scope = scope
        reload(inputs)
    }

    /// Picking a `from` turn always resets `to` — an end turn only makes
    /// sense relative to a chosen start, and the host rejects ranges
    /// that run backwards.
    func setTurn(from: String?, to: String?, _ inputs: Inputs) {
        turnFrom = from
        turnTo = to
        generation += 1
        loadSessionDiff(generation, inputs)
    }

    func setMode(_ mode: Vcs.Mode, _ inputs: Inputs) {
        diffMode = mode
        generation += 1
        loadWorkspaceDiff(generation, inputs)
    }

    func setFullFile(_ fullFile: Bool, _ inputs: Inputs) {
        self.fullFile = fullFile
        generation += 1
        switch scope {
        case .sessionTurn: loadSessionDiff(generation, inputs)
        case .workspace: loadWorkspaceDiff(generation, inputs)
        }
    }

    /// First appearance of a scope: loads only if that scope has never
    /// been loaded — popping back from a detail view preserves state and
    /// never refetches.
    func loadIfNeeded(_ inputs: Inputs) {
        guard !loadedScopes.contains(scope) else { return }
        reload(inputs)
    }

    /// Forced load of the current scope (pull-to-refresh, retry, first
    /// appearance). Adopted state survives the reload.
    func reload(_ inputs: Inputs) {
        loadedScopes.insert(scope)
        generation += 1
        let token = generation
        switch scope {
        case .sessionTurn: loadSessionDiff(token, inputs)
        case .workspace: loadWorkspace(token, inputs)
        }
    }

    /// Waits for the in-flight loads (newest generation) to settle so
    /// pull-to-refresh keeps its spinner honest.
    func settle() async {
        while !loading.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: Loads

    private func loadSessionDiff(_ token: Int, _ inputs: Inputs) {
        loading.insert(.sessionTurn)
        errors[.sessionTurn] = nil
        let from = turnFrom
        let to = turnTo
        let context = fullFile ? nil : "3"
        Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await historyService.diff(
                    at: inputs.host.address,
                    credential: inputs.credential,
                    sessionID: inputs.sessionID,
                    from: from,
                    to: to,
                    context: context
                )
                guard generation == token else { return } // stale
                sessionFiles = files
            } catch {
                guard generation == token else { return }
                errors[.sessionTurn] = Self.message(for: error)
            }
            loading.remove(.sessionTurn)
        }
    }

    private func loadWorkspace(_ token: Int, _ inputs: Inputs) {
        guard let directory = inputs.directory, !directory.isEmpty else {
            errors[.workspaceHeader] = "This session has no workspace directory to inspect."
            return
        }
        loading.insert(.workspaceHeader)
        loading.insert(.workspaceDiff)
        errors[.workspaceHeader] = nil
        errors[.workspaceDiff] = nil
        Task { [weak self] in
            guard let self else { return }
            async let branch = attempt { try await self.vcsService.info(
                at: inputs.host.address, credential: inputs.credential, directory: directory
            ) }
            async let status = attempt { try await self.vcsService.status(
                at: inputs.host.address, credential: inputs.credential, directory: directory
            ) }
            async let base = attempt { try await self.vcsService.base(
                at: inputs.host.address, credential: inputs.credential, directory: directory
            ) }
            async let diff = attempt { try await self.vcsService.diff(
                at: inputs.host.address, credential: inputs.credential, directory: directory,
                mode: self.diffMode, context: self.fullFile ? nil : "3"
            ) }

            let branchResult = await branch
            let statusResult = await status
            let baseResult = await base
            let diffResult = await diff

            // Stale results are discarded AFTER every await — including
            // their error and loading-flag bookkeeping below.
            guard generation == token else { return }

            switch branchResult {
            case .success(let info):
                branchInfo = info
            case .failure(let error):
                errors[.workspaceHeader] = errors[.workspaceHeader] ?? Self.message(for: error)
            }
            switch statusResult {
            case .success(let files):
                statusFiles = files
            case .failure(let error):
                errors[.workspaceHeader] = errors[.workspaceHeader] ?? Self.message(for: error)
            }
            switch baseResult {
            case .success(let base):
                // A host that has no inferable base answers null — a
                // distinct unavailable state, not a failure.
                baseState = base.map { .available($0) } ?? .unavailable
            case .failure(let error):
                errors[.workspaceHeader] = errors[.workspaceHeader] ?? Self.message(for: error)
            }
            switch diffResult {
            case .success(let files):
                diffFiles = files
            case .failure(let error):
                errors[.workspaceDiff] = Self.message(for: error)
            }
            loading.remove(.workspaceHeader)
            loading.remove(.workspaceDiff)
        }
    }

    private func loadWorkspaceDiff(_ token: Int, _ inputs: Inputs) {
        guard let directory = inputs.directory, !directory.isEmpty else {
            errors[.workspaceDiff] = "This session has no workspace directory to inspect."
            return
        }
        loading.insert(.workspaceDiff)
        errors[.workspaceDiff] = nil
        let mode = diffMode
        let context = fullFile ? nil : "3"
        Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await vcsService.diff(
                    at: inputs.host.address, credential: inputs.credential,
                    directory: directory, mode: mode, context: context
                )
                guard generation == token else { return } // stale
                diffFiles = files
            } catch {
                guard generation == token else { return }
                errors[.workspaceDiff] = Self.message(for: error)
            }
            loading.remove(.workspaceDiff)
        }
    }

    private func attempt<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    // MARK: Patch model

    /// One rendered patch line. Headers keep their raw text; content
    /// lines carry the text WITHOUT the +/- marker and the old/new line
    /// numbers the marker stood for.
    struct PatchLine: Equatable {
        enum Kind: Equatable {
            case fileHeader
            case hunkHeader
            case context
            case addition
            case deletion
            case note // "\ No newline at end of file"
        }
        var kind: Kind
        var text: String
        var oldLine: Int?
        var newLine: Int?
    }

    /// Side-by-side rendering: `span` covers headers/hunk headers/notes;
    /// `pair` aligns a deletion with its addition, padding the shorter
    /// run with nil. `rowOfLine` maps each patch line index to the row
    /// that displays it — the navigation target.
    struct SideBySide: Equatable {
        enum Row: Equatable {
            case span(PatchLine)
            case pair(left: PatchLine?, right: PatchLine?)
        }
        var rows: [Row]
        var rowOfLine: [Int]
    }

    /// Parses a unified diff into numbered lines. Line numbers come from
    /// the hunk headers; a malformed header leaves the following lines
    /// unnumbered rather than guessing. CRLF is normalised scalar-first —
    /// `"\r\n"` is a single Swift `Character`, so a plain
    /// `split(separator: "\n")` can never match it (the same trap
    /// `FileViewerLibrary.splitLines` documents).
    static func parsePatch(_ patch: String) -> [PatchLine] {
        let normalised = patch
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var components = normalised
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if components.last == "" {
            components.removeLast() // the terminating newline, not a line
        }
        var lines: [PatchLine] = []
        var oldLine: Int?
        var newLine: Int?
        for line in components {
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                lines.append(PatchLine(kind: .fileHeader, text: line, oldLine: nil, newLine: nil))
            } else if line.hasPrefix("@@") {
                if let start = parseHunkHeader(line) {
                    oldLine = start.old
                    newLine = start.new
                }
                lines.append(PatchLine(kind: .hunkHeader, text: line, oldLine: nil, newLine: nil))
            } else if line.hasPrefix("+") {
                lines.append(PatchLine(
                    kind: .addition, text: String(line.dropFirst()), oldLine: nil, newLine: newLine
                ))
                newLine = newLine.map { $0 + 1 }
            } else if line.hasPrefix("-") {
                lines.append(PatchLine(
                    kind: .deletion, text: String(line.dropFirst()), oldLine: oldLine, newLine: nil
                ))
                oldLine = oldLine.map { $0 + 1 }
            } else if line.hasPrefix("\\") {
                lines.append(PatchLine(kind: .note, text: line, oldLine: nil, newLine: nil))
            } else {
                // Context: the marker is a single leading space (dropped);
                // a bare empty line is context too.
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                lines.append(PatchLine(kind: .context, text: text, oldLine: oldLine, newLine: newLine))
                oldLine = oldLine.map { $0 + 1 }
                newLine = newLine.map { $0 + 1 }
            }
        }
        return lines
    }

    /// `@@ -old[,count] +new[,count] @@ optional section heading`.
    static func parseHunkHeader(_ header: String) -> (old: Int, new: Int)? {
        let parts = header.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3,
              parts[0] == "@@",
              parts[1].hasPrefix("-"),
              parts[2].hasPrefix("+"),
              let oldField = parts[1].dropFirst().split(separator: ",").first,
              let newField = parts[2].dropFirst().split(separator: ",").first,
              let old = Int(oldField),
              let new = Int(newField)
        else { return nil }
        return (old, new)
    }

    /// Pairs deletion/addition runs for side-by-side rendering; the
    /// pairing is order-agnostic within a run (a `-`/`+` block zips by
    /// position, padding the shorter side).
    static func sideBySide(_ lines: [PatchLine]) -> SideBySide {
        var rows: [SideBySide.Row] = []
        var rowOfLine = Array(repeating: 0, count: lines.count)
        var pendingDeletes: [Int] = []
        var pendingAdds: [Int] = []

        func flush() {
            let count = max(pendingDeletes.count, pendingAdds.count)
            for offset in 0..<count {
                let row = rows.count
                rows.append(.pair(
                    left: offset < pendingDeletes.count ? lines[pendingDeletes[offset]] : nil,
                    right: offset < pendingAdds.count ? lines[pendingAdds[offset]] : nil
                ))
                if offset < pendingDeletes.count { rowOfLine[pendingDeletes[offset]] = row }
                if offset < pendingAdds.count { rowOfLine[pendingAdds[offset]] = row }
            }
            pendingDeletes.removeAll(keepingCapacity: true)
            pendingAdds.removeAll(keepingCapacity: true)
        }

        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .deletion:
                pendingDeletes.append(index)
            case .addition:
                pendingAdds.append(index)
            case .context:
                flush()
                rowOfLine[index] = rows.count
                rows.append(.pair(left: line, right: line))
            case .fileHeader, .hunkHeader, .note:
                flush()
                rowOfLine[index] = rows.count
                rows.append(.span(line))
            }
        }
        flush()
        return SideBySide(rows: rows, rowOfLine: rowOfLine)
    }

    /// Case-insensitive substring hits as patch line indices, ascending;
    /// an empty/whitespace-only query has no hits.
    static func searchHits(query: String, in lines: [PatchLine]) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return lines.indices.filter { lines[$0].text.lowercased().contains(needle) }
    }

    /// The patch line index at the start of each change — a run of
    /// additions/deletions (the change-navigation targets).
    static func changeStarts(in lines: [PatchLine]) -> [Int] {
        var starts: [Int] = []
        for index in lines.indices
        where lines[index].kind == .addition || lines[index].kind == .deletion {
            let previous = index > 0 ? lines[index - 1].kind : nil
            if previous != .addition && previous != .deletion {
                starts.append(index)
            }
        }
        return starts
    }

    /// Advances a wrap-around cursor over `count` targets. nil = nothing
    /// landed yet: next lands on the FIRST target, previous on the last.
    static func advanceCursor(_ cursor: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let base = cursor ?? (delta > 0 ? -1 : count)
        return (base + delta + count) % count
    }

    /// The user turns offered by the range pickers, newest first,
    /// derived from the LOADED transcript. The default range needs no
    /// entry — `turnFrom` stays nil for the newest turn.
    static func userTurns(from messages: [SessionMessage]) -> [TurnOption] {
        Array(
            messages.compactMap { message -> TurnOption? in
                guard case .user(let text, _) = message.kind else { return nil }
                let flattened = text.replacingOccurrences(of: "\n", with: " ")
                return TurnOption(id: message.id, preview: String(flattened.prefix(80)))
            }.reversed()
        )
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, let envelope):
            if let envelope, !envelope.message.isEmpty {
                return envelope.message
            }
            return "The host refused this request (HTTP \(status)). Check your access."
        case TransportError.connectionFailed:
            return "The host is unreachable. Check the network and try again."
        default:
            return "Changes could not be loaded. \(error.localizedDescription)"
        }
    }
}
