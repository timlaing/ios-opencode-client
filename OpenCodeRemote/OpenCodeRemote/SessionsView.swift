import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S07 Sessions list (docs/navigation-screens.md S07, docs/api-contract.md
/// W03): server TITLE search, host/project scopes that stay visible,
/// running/unread/needs-attention markers, pinned grouping and the
/// device-local pin/follow/hide/delete/rename actions. Pinned, followed
/// and hidden states are local; Archive/Restore are unavailable in this
/// pinned baseline and are simply not offered (capability gap, never a
/// fabricated mutation).
struct SessionsView: View {
    @Environment(HostLibrary.self) private var library
    @Environment(ProjectsLibrary.self) private var projects
    @State private var sessions = SessionsLibrary()
    @State private var hostFilter: HostID?
    @State private var projectFilter: String?
    @State private var showHidden = false
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?

    @State private var showingNewSession = false
    @State private var showingRename = false
    @State private var renameTarget: SessionsLibrary.SessionRow?
    @State private var renameText = ""
    @State private var showingDelete = false
    @State private var deleteTarget: SessionsLibrary.SessionRow?
    @State private var detailTarget: SessionsLibrary.SessionRow?
    @State private var mutationError: String?

    private var visibleEntries: [HostLibrary.Entry] {
        library.entries.filter { hostFilter == nil || $0.id == hostFilter }
    }

    private var rows: [SessionsLibrary.SessionRow] {
        sessions.rows(
            entries: library.entries,
            hostFilter: hostFilter,
            projectFilter: projectFilter,
            hiddenFilter: showHidden
        )
    }

    private var pinnedRows: [SessionsLibrary.SessionRow] { rows.filter(\.pinned) }
    private var unpinnedRows: [SessionsLibrary.SessionRow] { rows.filter { !$0.pinned } }

    var body: some View {
        NavigationStack {
            Group {
                if library.entries.isEmpty {
                    ContentUnavailableView(
                        "No Hosts Paired",
                        systemImage: "server.rack",
                        description: Text("Pair a server on the Servers tab to see its sessions.")
                    )
                } else {
                    sessionList
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { scopeMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewSession = true
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .accessibilityIdentifier("S07.newSession")
                    .disabled(library.entries.isEmpty)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search session titles")
        .task {
            sessions.attach(hosts: library)
            // The shared ProjectsLibrary may not have loaded yet if the
            // user opens Sessions first — the project filter, row
            // subtitles and New Session recents depend on it. Load only
            // the hosts not already cached (a partial cache must not
            // starve the remaining hosts).
            projects.attach(hosts: library)
            let missingProjects = library.entries.filter { projects.projectsByHost[$0.id] == nil }
            if !missingProjects.isEmpty {
                await projects.load(missingProjects)
            }
            await sessions.load(library.entries)
        }
        .refreshable {
            if let hostFilter, let entry = library.entries.first(where: { $0.id == hostFilter }) {
                // Always the host-wide inventory: project scoping is
                // applied client-side in rows(), so a scoped page never
                // replaces the cache or its cursors.
                await sessions.load(host: entry.host)
            } else {
                await sessions.load(library.entries)
            }
        }
        .onChange(of: searchText) { _, value in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await sessions.search(value, entries: visibleEntries)
            }
        }
        .onChange(of: hostFilter) { _, _ in
            projectFilter = nil
            // Restart the search in the new scope from the CURRENT field
            // text — the field can hold a newer term than activeSearch if
            // the scope changed inside the debounce window; empty text
            // clears the search outright.
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await sessions.search(searchText, entries: visibleEntries)
            }
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionSheet(
                sessions: sessions,
                entries: library.entries,
                suggestedHost: hostFilter ?? library.entries.first?.id
            ) { _, _ in
                // A fresh creation makes any stale search/scope stale:
                // show the unfiltered inventory where the new row lands.
                searchText = ""
                showHidden = false
            }
            .environment(library)
            .environment(projects)
        }
        .sheet(item: $detailTarget) { row in
            SessionDetailSheet(
                host: row.host,
                credential: library.credential(for: row.host.id),
                initial: row.session,
                sessions: sessions
            )
            .environment(library)
        }
        .alert("Rename Session", isPresented: $showingRename, presenting: renameTarget) { row in
            TextField("Title", text: $renameText)
            Button("Rename") {
                let title = renameText
                Task {
                    do {
                        try await sessions.rename(host: row.host, sessionID: row.session.id, title: title)
                    } catch {
                        mutationError = Self.mutationMessage(error, action: "rename")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text(row.session.title ?? row.session.id)
        }
        .alert("Delete Session?", isPresented: $showingDelete, presenting: deleteTarget) { row in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await sessions.remove(host: row.host, sessionID: row.session.id)
                    } catch {
                        mutationError = Self.mutationMessage(error, action: "delete")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text(deleteMessage(for: row))
        }
        .alert("Sessions", isPresented: Binding(
            get: { mutationError != nil },
            set: { if !$0 { mutationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mutationError ?? "")
        }
    }

    // MARK: - List

    private var sessionList: some View {
        List {
            let errors = sessions.visibleErrors(entries: library.entries, hostFilter: hostFilter)
            if !errors.isEmpty {
                Section("Host Status") {
                    ForEach(errors, id: \.id) { error in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(error.name)
                                .font(.caption.weight(.medium))
                            Text(error.message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            if rows.isEmpty {
                Section {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(emptyDescription(errors: errors))
                    )
                }
            } else {
                if !pinnedRows.isEmpty, !showHidden {
                    Section("Pinned") {
                        ForEach(pinnedRows) { row in sessionRow(row) }
                    }
                }
                Section(showHidden ? "Hidden on This Device" : "Sessions") {
                    // In the hidden view ALL hidden rows render (a row can
                    // be both pinned and hidden, and must stay reachable
                    // for "Unhide on This Device").
                    ForEach(showHidden ? rows : unpinnedRows) { row in sessionRow(row) }
                }
                if sessions.activeSearch == nil, hasMorePages {
                    Section {
                        Button("Load More Sessions") {
                            Task {
                                for entry in visibleEntries where sessions.hasMoreByHost[entry.id] == true {
                                    await sessions.loadMore(host: entry.host)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("AppBackgroundColor"))
    }

    private var hasMorePages: Bool {
        visibleEntries.contains { sessions.hasMoreByHost[$0.id] == true }
    }

    private func sessionRow(_ row: SessionsLibrary.SessionRow) -> some View {
        Button {
            detailTarget = row
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.session.title ?? "Untitled Session")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if row.running {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Running")
                    }
                    if row.needsAttention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .accessibilityLabel("Needs attention")
                    }
                    if row.unread {
                        Circle()
                            .fill(.blue)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("Unread")
                    }
                }
                Text(subtitle(for: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityIdentifier("S07.session.row.\(row.session.id)")
        }
        .contextMenu {
            Button("Rename…") {
                renameText = row.session.title ?? ""
                renameTarget = row
                showingRename = true
            }
            Button(row.pinned ? "Unpin" : "Pin") {
                sessions.localState.togglePinned(SessionKey(hostID: row.host.id, sessionID: row.session.id))
            }
            Button(row.followed ? "Unfollow Updates" : "Follow Updates") {
                sessions.localState.toggleFollowed(SessionKey(hostID: row.host.id, sessionID: row.session.id))
            }
            Button(row.hidden ? "Unhide on This Device" : "Hide on This Device") {
                sessions.localState.toggleHidden(SessionKey(hostID: row.host.id, sessionID: row.session.id))
            }
            Button("Mark as Read") {
                Task { await sessions.markViewed(host: row.host, session: row.session) }
            }
            .disabled(!row.unread)
            Divider()
            Button("Delete…", role: .destructive) {
                deleteTarget = row
                showingDelete = true
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                sessions.localState.togglePinned(SessionKey(hostID: row.host.id, sessionID: row.session.id))
            } label: {
                Label(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteTarget = row
                showingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func subtitle(for row: SessionsLibrary.SessionRow) -> String {
        let projectName = projects.projectsByHost[row.host.id]?
            .first(where: { $0.id == row.session.projectID })?.name
        let parts = [
            projectName ?? row.session.location?.directory ?? "",
            row.host.displayName,
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Scope menu

    private var scopeMenu: some View {
        Menu {
            Section("Host") {
                Button {
                    hostFilter = nil
                } label: {
                    if hostFilter == nil { Label("All Hosts", systemImage: "checkmark") } else { Text("All Hosts") }
                }
                ForEach(library.entries) { entry in
                    Button {
                        hostFilter = entry.id
                    } label: {
                        if hostFilter == entry.id { Label(entry.host.displayName, systemImage: "checkmark") } else { Text(entry.host.displayName) }
                    }
                }
            }
            if let hostFilter {
                Section("Project") {
                    Button {
                        projectFilter = nil
                    } label: {
                        if projectFilter == nil { Label("All Projects", systemImage: "checkmark") } else { Text("All Projects") }
                    }
                    ForEach(projects.projectsByHost[hostFilter] ?? [], id: \.id) { project in
                        Button {
                            projectFilter = project.id
                        } label: {
                            if projectFilter == project.id {
                                Label(project.name ?? project.canonical, systemImage: "checkmark")
                            } else {
                                Text(project.name ?? project.canonical)
                            }
                        }
                    }
                }
            }
            Section("Local") {
                Toggle("Hidden on This Device", isOn: $showHidden)
            }
        } label: {
            Label(scopeLabel, systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("S07.scopePicker")
    }

    /// Scope is always visible in the toolbar button: host first, then
    /// narrowed project, and the local hidden filter when active.
    private var scopeLabel: String {
        var parts: [String] = []
        if let hostFilter, let entry = library.entries.first(where: { $0.id == hostFilter }) {
            parts.append(entry.host.displayName)
        } else {
            parts.append("All Hosts")
        }
        if let hostFilter, let projectFilter,
           let name = projects.projectsByHost[hostFilter]?.first(where: { $0.id == projectFilter })?.name {
            parts.append(name)
        }
        if showHidden { parts.append("Hidden") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Empty states

    private var emptyTitle: String {
        if sessions.activeSearch != nil { return "No Matches" }
        if showHidden { return "No Hidden Sessions" }
        return "No Sessions"
    }

    private func emptyDescription(errors: [(id: HostID, name: String, message: String)]) -> String {
        if sessions.activeSearch != nil {
            return "No session title matches “\(sessions.activeSearch ?? "")” on the selected hosts."
        }
        if showHidden {
            return "Sessions you hide on this device appear here and can be restored."
        }
        if !errors.isEmpty {
            return "Some hosts could not list sessions — see Host Status above."
        }
        return "Sessions created on your servers appear here."
    }

    private func deleteMessage(for row: SessionsLibrary.SessionRow) -> String {
        let children = sessions.sessionsByHost[row.host.id]?.filter {
            $0.parentID == row.session.id
        }.count ?? 0
        let title = row.session.title ?? row.session.id
        if children > 0 {
            return "“\(title)” and \(children) child session\(children == 1 ? "" : "s") are deleted from the server. This cannot be undone."
        }
        return "“\(title)” is deleted from the server. This cannot be undone."
    }

    private static func mutationMessage(_ error: Error, action: String) -> String {
        switch error {
        case TransportError.connectionFailed:
            return "The \(action) could not reach the host. Check the connection and try again."
        case TransportError.http(let status, _):
            return "The host rejected the \(action) (HTTP \(status))."
        default:
            return "The \(action) did not complete."
        }
    }
}

// MARK: - New Session (S07)

/// Creates a native session bound to an explicit host/location. The
/// server verifies the directory through its location handling; this
/// sheet never creates folders, Git repositories, or shell state.
private struct NewSessionSheet: View {
    let sessions: SessionsLibrary
    let entries: [HostLibrary.Entry]
    var suggestedHost: HostID?
    var onCreated: (OpenCodeDomain.Host, Session) -> Void

    @Environment(ProjectsLibrary.self) private var projects
    @Environment(\.dismiss) private var dismiss
    @State private var hostID: HostID?
    @State private var directory = ""
    @State private var title = ""
    @State private var creating = false
    @State private var errorMessage: String?

    private var selectedHost: OpenCodeDomain.Host? {
        entries.first(where: { $0.id == hostID })?.host
    }

    private var trimmedDirectory: String {
        directory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        !trimmedDirectory.isEmpty && !creating && selectedHost != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    Picker("Host", selection: Binding(
                        get: { hostID ?? suggestedHost },
                        set: { hostID = $0 }
                    )) {
                        ForEach(entries) { entry in
                            Text(entry.host.displayName).tag(Optional(entry.id))
                        }
                    }
                }
                Section {
                    TextField("/path/on/host", text: $directory)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Title (optional)", text: $title)
                    if let host = selectedHost {
                        let recent = projects.recentLocations.filter { $0.host.id == host.id }
                        if !recent.isEmpty {
                            Menu("Recent Folders") {
                                ForEach(Array(recent.enumerated()), id: \.offset) { _, item in
                                    Button(item.location.project.canonical) {
                                        directory = item.location.project.canonical
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text(trimmedDirectory.isEmpty
                         ? "The session is created in the directory you enter; the server verifies it."
                         : "The session will be created in \(trimmedDirectory). The server verifies the directory.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if creating { ProgressView() } else { Text("Create") }
                    }
                    .disabled(!canCreate)
                    .accessibilityIdentifier("S07.newSession.create")
                }
            }
            .onAppear {
                if hostID == nil { hostID = suggestedHost }
            }
        }
    }

    private func create() async {
        guard let host = selectedHost else { return }
        creating = true
        defer { creating = false }
        do {
            let created = try await sessions.create(
                host: host,
                directory: trimmedDirectory,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onCreated(host, created)
            dismiss()
        } catch {
            switch error {
            case TransportError.http(let status, _):
                errorMessage = "The host rejected the session creation (HTTP \(status)). Check the directory and try again."
            case TransportError.connectionFailed:
                errorMessage = "The host is unreachable. The draft is kept — try again when connected."
            default:
                errorMessage = "The session was not created."
            }
        }
    }
}

// MARK: - Session detail (session.get)

/// Reads one session through `session.get` for cumulative detail and
/// offers the explicit unread acknowledgement. Absent values render as
/// "Unknown" — never invented (docs/api-contract.md W03 read).
private struct SessionDetailSheet: View {
    let host: OpenCodeDomain.Host
    let credential: BasicCredential?
    let initial: Session
    let sessions: SessionsLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var service = SessionService(makeTransport: { URLSessionTransport(baseURL: $0) })
    @State private var current: Session?
    @State private var loadFailed = false

    private var session: Session { current ?? initial }

    var body: some View {
        NavigationStack {
            List {
                if loadFailed {
                    Section {
                        Text("Live details could not be refreshed; showing the last known values.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Session") {
                    LabeledContent("Title", value: session.title ?? "Untitled Session")
                    LabeledContent("Location", value: session.location?.directory ?? "Unknown")
                    if let model = session.model {
                        LabeledContent("Model", value: "\(model.providerID)/\(model.id)")
                    } else {
                        LabeledContent("Model", value: "Unknown")
                    }
                    LabeledContent("Agent", value: session.agent ?? "Unknown")
                    if let outcome = session.outcome {
                        LabeledContent("Outcome") {
                            Text(outcome)
                                .foregroundStyle(outcome == "succeeded" ? .green : .red)
                        }
                    }
                }
                Section("Usage") {
                    LabeledContent("Input", value: token(session.tokens?.input))
                    LabeledContent("Output", value: token(session.tokens?.output))
                    LabeledContent("Reasoning", value: token(session.tokens?.reasoning))
                    LabeledContent("Cost") {
                        Text(session.cost.map { String(format: "$%.4f", $0) } ?? "Unknown")
                    }
                }
                Section("Times") {
                    LabeledContent("Created", value: Self.date(session.time?.created))
                    LabeledContent("Updated", value: Self.date(session.time?.updated))
                }
                if session.isUnread {
                    Section {
                        Button("Mark as Read") {
                            Task {
                                await sessions.markViewed(host: host, session: session)
                                await refresh()
                            }
                        }
                    } footer: {
                        Text("Records that you have seen this session using the host's own timestamps.")
                    }
                }
                Section {
                    Text(session.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Session Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        do {
            current = try await service.session(at: host.address, credential: credential, sessionID: initial.id)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func token(_ value: Int?) -> String {
        value.map(String.init) ?? "Unknown"
    }

    private static func date(_ epochMilliseconds: Int64?) -> String {
        guard let epochMilliseconds else { return "Unknown" }
        let date = Date(timeIntervalSince1970: Double(epochMilliseconds) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
