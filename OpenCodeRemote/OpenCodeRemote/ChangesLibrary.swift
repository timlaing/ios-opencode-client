import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// Pure decisions + load orchestration for the S15 Changes inspector
/// (docs/navigation-screens.md S15, docs/api-contract.md W12/W13): a
/// session-turn scope (`session.diff` over the transcript's user turns)
/// and a workspace scope (`vcs.get`/`status`/`base`/`diff` over the
/// location). The view renders decisions made here.
///
/// Load invariants: PER-SECTION stale tokens — a load bumps only the
/// sections it covers, and a completion that no longer matches its
/// section is discarded AFTER its await. The newer load of THAT section
/// owns the adopted state and the loading flag, so a superseded task can
/// never strand a flag and a cross-section switch never invalidates
/// another section's work. Revisited scopes keep their adopted state
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

    /// Per-section stale tokens (see the type doc). A section's flag is
    /// inserted only by a load that just bumped that section's token,
    /// and every completion removes its flag only while its token is
    /// still current — the chain always ends with the newest load of a
    /// section, so flags always clear and `settle()` always terminates.
    private var tokens: [Section: Int] = [:]

    private func bump(_ sections: Section...) {
        for section in sections { tokens[section, default: 0] += 1 }
    }

    private func isCurrent(_ section: Section, _ token: Int) -> Bool {
        tokens[section] == token
    }

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
        loadSessionDiff(inputs)
    }

    func setMode(_ mode: Vcs.Mode, _ inputs: Inputs) {
        diffMode = mode
        loadWorkspaceDiff(inputs)
    }

    func setFullFile(_ fullFile: Bool, _ inputs: Inputs) {
        self.fullFile = fullFile
        switch scope {
        case .sessionTurn: loadSessionDiff(inputs)
        case .workspace: loadWorkspaceDiff(inputs)
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
        switch scope {
        case .sessionTurn: loadSessionDiff(inputs)
        case .workspace: loadWorkspace(inputs)
        }
    }

    /// Waits for the in-flight loads to settle so pull-to-refresh keeps
    /// its spinner honest. A cancelled waiter (the refreshable's task
    /// dying with the view) leaves at once instead of spinning on a
    /// sleep that now throws immediately.
    func settle() async {
        while !loading.isEmpty, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
    }

    // MARK: Loads

    private func loadSessionDiff(_ inputs: Inputs) {
        bump(.sessionTurn)
        let myToken = tokens[.sessionTurn] ?? 0
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
                // Stale: the newer session-turn load owns the state AND
                // this flag.
                guard isCurrent(.sessionTurn, myToken) else { return }
                sessionFiles = files
            } catch {
                guard isCurrent(.sessionTurn, myToken) else { return }
                errors[.sessionTurn] = Self.message(for: error)
            }
            loading.remove(.sessionTurn)
        }
    }

    private func loadWorkspace(_ inputs: Inputs) {
        guard let directory = inputs.directory, !directory.isEmpty else {
            // No bump: the directory never changes within a presentation,
            // so nothing was ever in flight for this guard to invalidate.
            errors[.workspaceHeader] = "This session has no workspace directory to inspect."
            return
        }
        bump(.workspaceHeader, .workspaceDiff)
        let headerToken = tokens[.workspaceHeader] ?? 0
        let diffToken = tokens[.workspaceDiff] ?? 0
        // Captured at load start — the in-flight load reflects the
        // selector state when it BEGAN, not whenever its task runs.
        let mode = diffMode
        let context = fullFile ? nil : "3"
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
                mode: mode, context: context
            ) }

            let branchResult = await branch
            let statusResult = await status
            let baseResult = await base
            let diffResult = await diff

            // Sections own their results and flags INDEPENDENTLY: a
            // mode/full-file change mid-flight supersedes only the diff
            // section, so the header answers still adopt (and a scope
            // never strands another section's flag). Discard happens
            // only after every await.
            if isCurrent(.workspaceHeader, headerToken) {
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
                loading.remove(.workspaceHeader)
            }
            if isCurrent(.workspaceDiff, diffToken) {
                switch diffResult {
                case .success(let files):
                    diffFiles = files
                case .failure(let error):
                    errors[.workspaceDiff] = Self.message(for: error)
                }
                loading.remove(.workspaceDiff)
            }
        }
    }

    private func loadWorkspaceDiff(_ inputs: Inputs) {
        guard let directory = inputs.directory, !directory.isEmpty else {
            errors[.workspaceDiff] = "This session has no workspace directory to inspect."
            return
        }
        bump(.workspaceDiff)
        let myToken = tokens[.workspaceDiff] ?? 0
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
                // Stale: the newer diff-section load owns the state AND
                // this flag.
                guard isCurrent(.workspaceDiff, myToken) else { return }
                diffFiles = files
            } catch {
                guard isCurrent(.workspaceDiff, myToken) else { return }
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
        // `--- `/`+++ ` count as FILE headers only OUTSIDE a hunk: inside
        // one, a deletion whose content starts with `-- ` serialises as
        // `--- …` (SQL/Lua/Markdown comments) and must stay a deletion
        // with its number. Each hunk's declared old/new counts end it
        // exactly, so a following file's headers and metadata never
        // consume line numbers either.
        var inHunk = false
        var oldRemaining = 0
        var newRemaining = 0

        for line in components {
            let kind: PatchLine.Kind
            if line.hasPrefix("@@") {
                kind = .hunkHeader
            } else if !inHunk,
                      line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                        || line.hasPrefix("diff --git") {
                kind = .fileHeader
            } else if line.hasPrefix("+") {
                kind = .addition
            } else if line.hasPrefix("-") {
                kind = .deletion
            } else if line.hasPrefix("\\") {
                kind = .note
            } else {
                kind = .context
            }

            // Headers and notes keep their raw text and are never
            // numbered; content lines take the marker off and (inside a
            // hunk only) their numbers from the running counters.
            let text: String
            var old: Int?
            var new: Int?
            switch kind {
            case .addition, .deletion:
                text = String(line.dropFirst())
            case .context:
                // The marker is a single leading space (dropped); a bare
                // empty line is context too.
                text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
            case .fileHeader, .hunkHeader, .note:
                text = line
            }
            switch kind {
            case .addition:
                old = nil
                new = newLine
                if inHunk { newLine = newLine.map { $0 + 1 } }
            case .deletion:
                old = oldLine
                new = nil
                if inHunk { oldLine = oldLine.map { $0 + 1 } }
            case .context:
                old = oldLine
                new = newLine
                if inHunk {
                    oldLine = oldLine.map { $0 + 1 }
                    newLine = newLine.map { $0 + 1 }
                }
            case .fileHeader, .hunkHeader, .note:
                old = nil
                new = nil
            }
            lines.append(PatchLine(kind: kind, text: text, oldLine: old, newLine: new))

            switch kind {
            case .hunkHeader:
                if let start = parseHunkHeader(line) {
                    oldLine = start.old
                    newLine = start.new
                    oldRemaining = start.oldCount
                    newRemaining = start.newCount
                    inHunk = true
                } else {
                    // Malformed: numbering cannot continue — stay
                    // unnumbered rather than guessing.
                    oldLine = nil
                    newLine = nil
                    inHunk = false
                }
            case .context:
                if inHunk {
                    oldRemaining -= 1
                    newRemaining -= 1
                }
            case .deletion:
                if inHunk { oldRemaining -= 1 }
            case .addition:
                if inHunk { newRemaining -= 1 }
            case .fileHeader, .note:
                break
            }
            if inHunk, oldRemaining <= 0, newRemaining <= 0 {
                // Hunk exhausted exactly: the next lines are outside it.
                inHunk = false
                oldLine = nil
                newLine = nil
            }
        }
        return lines
    }

    /// `@@ -old[,count] +new[,count] @@ optional section heading` — an
    /// omitted count means 1.
    static func parseHunkHeader(
        _ header: String
    ) -> (old: Int, new: Int, oldCount: Int, newCount: Int)? {
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
        let oldParts = parts[1].dropFirst().split(separator: ",")
        let newParts = parts[2].dropFirst().split(separator: ",")
        let oldCount = oldParts.count > 1 ? Int(oldParts[1]) ?? 1 : 1
        let newCount = newParts.count > 1 ? Int(newParts[1]) ?? 1 : 1
        return (old, new, oldCount, newCount)
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
