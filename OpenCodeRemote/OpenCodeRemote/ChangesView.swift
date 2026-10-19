import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S15 Changes inspector (docs/navigation-screens.md S15): session-turn
/// or workspace scope, selected range/base, changed-file totals, and a
/// unified or side-by-side diff with search, change navigation and copy.
/// All decisions live in `ChangesLibrary` — this view only renders them.
struct ChangesView: View {
    let host: OpenCodeDomain.Host
    let credential: BasicCredential?
    let sessionID: String
    /// nil when the session has no workspace location — the workspace
    /// scope then says so instead of inventing a directory.
    let directory: String?
    let conversation: ConversationLibrary

    @State private var library = ChangesLibrary()

    private var inputs: ChangesLibrary.Inputs {
        .init(host: host, credential: credential, sessionID: sessionID, directory: directory)
    }

    var body: some View {
        List {
            scopeSection
            if library.scope == .sessionTurn {
                sessionSection
            } else {
                workspaceSection
            }
        }
        .task { library.loadIfNeeded(inputs) }
        .refreshable {
            library.reload(inputs)
            await library.settle()
        }
        .navigationTitle("Changes")
    }

    // MARK: Scope

    private var scopeSection: some View {
        Section {
            Picker("Scope", selection: Binding(
                get: { library.scope },
                set: { library.setScope($0, inputs) }
            )) {
                ForEach(ChangesLibrary.Scope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("S15.scope")
        }
    }

    // MARK: Session-turn scope

    private var sessionSection: some View {
        let turns = ChangesLibrary.userTurns(from: conversation.messages)
        return Section("Session turn") {
            Picker("From", selection: Binding(
                get: { library.turnFrom },
                set: { picked in
                    // A new start resets the end — the host rejects
                    // ranges that run backwards.
                    library.setTurn(from: picked, to: nil, inputs)
                }
            )) {
                Text("Newest turn").tag(String?.none)
                ForEach(turns) { turn in
                    Text(turn.preview).tag(String?.some(turn.id))
                }
            }
            .accessibilityIdentifier("S15.range.from")

            if library.turnFrom != nil {
                Picker("Through", selection: Binding(
                    get: { library.turnTo },
                    set: { library.setTurn(from: library.turnFrom, to: $0, inputs) }
                )) {
                    Text("Same turn").tag(String?.none)
                    ForEach(laterTurns) { turn in
                        Text(turn.preview).tag(String?.some(turn.id))
                    }
                }
                .accessibilityIdentifier("S15.range.to")
            }

            contextToggle

            if let error = library.errors[.sessionTurn] {
                errorRow(error)
            } else if let files = library.sessionFiles {
                if files.isEmpty {
                    emptyRow("This turn changed no files.")
                } else {
                    fileRows(files)
                }
            } else if library.loading.contains(.sessionTurn) {
                ProgressView()
            }
        }
    }

    /// Turns chronologically AFTER the chosen start — the `Through`
    /// options. `conversation.messages` is ascending, so the newest-
    /// first turn list shows them before `from`'s index.
    private var laterTurns: [ChangesLibrary.TurnOption] {
        let turns = ChangesLibrary.userTurns(from: conversation.messages)
        guard let fromIndex = turns.firstIndex(where: { $0.id == library.turnFrom }) else {
            return []
        }
        return Array(turns[..<fromIndex])
    }

    // MARK: Workspace scope

    private var workspaceSection: some View {
        Section("Workspace") {
            if let error = library.errors[.workspaceHeader] {
                errorRow(error)
            }
            if let info = library.branchInfo {
                LabeledContent("Branch", value: branchText(info))
                    .accessibilityIdentifier("S15.branch")
            }
            baseRow
            if let status = library.statusFiles {
                LabeledContent("Working copy", value: workingCopyText(status))
                    .accessibilityIdentifier("S15.status.totals")
            }

            Picker("Mode", selection: Binding(
                get: { library.diffMode },
                set: { library.setMode($0, inputs) }
            )) {
                Text("Working").tag(Vcs.Mode.working)
                Text("Branch").tag(Vcs.Mode.branch)
                Text("Committed").tag(Vcs.Mode.committed)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("S15.mode")

            contextToggle

            if let error = library.errors[.workspaceDiff] {
                errorRow(error)
            } else if let files = library.diffFiles {
                if files.isEmpty {
                    emptyRow("No changes in this mode.")
                } else {
                    fileRows(files)
                }
            } else if library.loading.contains(.workspaceDiff) {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var baseRow: some View {
        switch library.baseState {
        case .unloaded:
            EmptyView()
        case .unavailable:
            // A null base is a distinct state — never an empty
            // successful diff. The host keeps its repository-default
            // comparison; ambiguous history needs an explicit base.
            Label(
                "No review base — diffs use the repository default.",
                systemImage: "exclamationmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("S15.base.unavailable")
        case .available(let base):
            LabeledContent("Base", value: "\(base.name) (\(base.source.rawValue))")
                .accessibilityIdentifier("S15.base")
        }
    }

    private func branchText(_ info: Vcs.Info) -> String {
        var parts: [String] = []
        if let current = info.branch.current { parts.append(current) }
        if let base = info.branch.defaultBranch, base != info.branch.current {
            parts.append("→ \(base)")
        }
        if let provider = info.provider { parts.append("(\(provider))") }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    private func workingCopyText(_ status: [Vcs.FileStatus]) -> String {
        let additions = status.reduce(0) { $0 + $1.additions }
        let deletions = status.reduce(0) { $0 + $1.deletions }
        return "\(status.count) \(status.count == 1 ? "file" : "files") · +\(additions) −\(deletions)"
    }

    // MARK: Shared pieces

    private var contextToggle: some View {
        Toggle("Full file", isOn: Binding(
            get: { library.fullFile },
            set: { library.setFullFile($0, inputs) }
        ))
        .accessibilityIdentifier("S15.context")
    }

    private func fileRows(_ files: [FileDiff.Info]) -> some View {
        ForEach(files.indices, id: \.self) { index in
            NavigationLink {
                PatchDetailView(file: files[index])
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(files[index].file)
                            .font(.body.monospaced())
                            .lineLimit(2)
                        Text(statusLabel(files[index].status))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("+\(files[index].additions) −\(files[index].deletions)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("S15.file.\(index)")
        }
    }

    private func statusLabel(_ status: FileDiff.Status) -> String {
        // A NEWER host's vocabulary (renamed, …) shows verbatim — the
        // host said it; inventing a known label would lie.
        switch status {
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .modified: return "Modified"
        default: return status.rawValue
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button("Retry") { library.reload(inputs) }
                .accessibilityIdentifier("S15.retry")
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// S15 diff detail: unified or side-by-side rendering of one file's
/// patch, with within-diff search, search/change navigation and copy.
/// Parsing, pairing and cursor math are `ChangesLibrary` decisions —
/// this view only renders and scrolls.
private struct PatchDetailView: View {
    let file: FileDiff.Info

    enum Style: String, CaseIterable, Identifiable {
        case unified
        case sideBySide
        var id: String { rawValue }
        var label: String { self == .unified ? "Unified" : "Side by side" }
    }

    private let lines: [ChangesLibrary.PatchLine]
    private let side: ChangesLibrary.SideBySide
    private let changeStarts: [Int]

    init(file: FileDiff.Info) {
        self.file = file
        let parsed = ChangesLibrary.parsePatch(file.patch)
        self.lines = parsed
        self.side = ChangesLibrary.sideBySide(parsed)
        self.changeStarts = ChangesLibrary.changeStarts(in: parsed)
    }

    @State private var style: Style = .unified
    @State private var query = ""
    @State private var hits: [Int] = []
    @State private var hitCursor: Int?
    @State private var changeCursor: Int?
    @State private var scrollTarget: String?
    @State private var copied = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Picker("Style", selection: $style) {
                        ForEach(Style.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("S15.style")
                }

                Section {
                    TextField("Search diff", text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("S15.search")
                    HStack {
                        Text(hitCounter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            hitCursor = ChangesLibrary.advanceCursor(hitCursor, delta: -1, count: hits.count)
                            if let cursor = hitCursor { scrollTo(line: hits[cursor]) }
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(hits.isEmpty)
                        .accessibilityIdentifier("S15.search.prev")
                        Button {
                            hitCursor = ChangesLibrary.advanceCursor(hitCursor, delta: 1, count: hits.count)
                            if let cursor = hitCursor { scrollTo(line: hits[cursor]) }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(hits.isEmpty)
                        .accessibilityIdentifier("S15.search.next")
                    }
                    HStack {
                        Spacer()
                        Button {
                            changeCursor = ChangesLibrary.advanceCursor(
                                changeCursor, delta: -1, count: changeStarts.count
                            )
                            if let cursor = changeCursor { scrollTo(line: changeStarts[cursor]) }
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(changeStarts.isEmpty)
                        .accessibilityIdentifier("S15.change.prev")
                        Button {
                            changeCursor = ChangesLibrary.advanceCursor(
                                changeCursor, delta: 1, count: changeStarts.count
                            )
                            if let cursor = changeCursor { scrollTo(line: changeStarts[cursor]) }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(changeStarts.isEmpty)
                        .accessibilityIdentifier("S15.change.next")
                    }
                }

                Section {
                    switch style {
                    case .unified: unifiedRows
                    case .sideBySide: sideBySideRows
                    }
                }
            }
            .onChange(of: query) { _, newValue in
                hits = ChangesLibrary.searchHits(query: newValue, in: lines)
                hitCursor = nil
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                // Re-arm: onChange fires only on a VALUE change, so a
                // repeat tap on the same target (one hit, one change, or
                // a row the user scrolled away from) must still scroll.
                scrollTarget = nil
            }
        }
        .navigationTitle((file.file as NSString).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = file.patch
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label("Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("S15.copy")
            }
        }
    }

    private var hitCounter: String {
        guard !query.isEmpty else { return "" }
        guard let cursor = hitCursor else {
            return hits.isEmpty ? "No matches" : "\(hits.count) matches"
        }
        return "\(cursor + 1)/\(hits.count)"
    }

    private var unifiedRows: some View {
        ForEach(lines.indices, id: \.self) { index in
            let line = lines[index]
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.oldLine.map(String.init) ?? "")
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Text(line.newLine.map(String.init) ?? "")
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Text(marker(line.kind) + line.text)
            }
            .font(.footnote.monospaced())
            .foregroundStyle(textColor(line.kind))
            .id("line-\(index)")
            .listRowBackground(rowBackground(line.kind))
        }
    }

    private var sideBySideRows: some View {
        ForEach(side.rows.indices, id: \.self) { rowIndex in
            Group {
                switch side.rows[rowIndex] {
                case .span(let line):
                    Text(line.text)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                case .pair(let left, let right):
                    HStack(spacing: 0) {
                        column(left, role: .old)
                        Divider()
                        column(right, role: .new)
                    }
                }
            }
            .id("row-\(rowIndex)")
        }
    }

    private enum Column {
        case old
        case new
    }

    private func column(_ line: ChangesLibrary.PatchLine?, role: Column) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(number(line, role: role))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
            Text(line.map { marker($0.kind) + $0.text } ?? "")
                .font(.footnote.monospaced())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .background(line.map { columnBackground($0.kind, role: role) } ?? Color.clear)
    }

    private func number(_ line: ChangesLibrary.PatchLine?, role: Column) -> String {
        guard let line else { return "" }
        switch role {
        case .old: return line.oldLine.map(String.init) ?? ""
        case .new: return line.newLine.map(String.init) ?? ""
        }
    }

    private func scrollTo(line: Int) {
        switch style {
        case .unified:
            scrollTarget = "line-\(line)"
        case .sideBySide:
            scrollTarget = "row-\(side.rowOfLine[line])"
        }
    }

    private func marker(_ kind: ChangesLibrary.PatchLine.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        case .fileHeader, .hunkHeader, .note: return "" // raw text already carries it
        }
    }

    private func textColor(_ kind: ChangesLibrary.PatchLine.Kind) -> Color {
        switch kind {
        case .addition: return .green
        case .deletion: return .red
        default: return .primary
        }
    }

    private func rowBackground(_ kind: ChangesLibrary.PatchLine.Kind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.15)
        case .deletion: return Color.red.opacity(0.15)
        case .hunkHeader, .fileHeader: return Color.secondary.opacity(0.08)
        default: return .clear
        }
    }

    private func columnBackground(
        _ kind: ChangesLibrary.PatchLine.Kind, role: Column
    ) -> Color {
        switch (kind, role) {
        case (.deletion, .old): return Color.red.opacity(0.15)
        case (.addition, .new): return Color.green.opacity(0.15)
        default: return .clear
        }
    }
}
