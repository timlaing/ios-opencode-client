import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// Root navigation shell: Servers, Projects, Sessions, Settings
/// (docs/navigation-screens.md).
struct ContentView: View {
    @State private var library = HostLibrary()
    /// Shared across Projects and Sessions (recent locations feed
    /// New Session; project inventory feeds the S07 project filter).
    @State private var projects = ProjectsLibrary()
    @State private var showingConnectSheet = false

    var body: some View {
        TabView {
            ServersTab(library: library, onConnectHost: { showingConnectSheet = true })
                .tabItem { Label("Servers", systemImage: "server.rack") }
            ProjectsTab()
                .tabItem { Label("Projects", systemImage: "folder") }
            SessionsView()
                .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right") }
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .background(Color("AppBackgroundColor"))
        .environment(library)
        .environment(projects)
        .sheet(isPresented: $showingConnectSheet) {
            // Injected explicitly rather than relying on sheet environment
            // inheritance — a missing HostLibrary is a fatal SwiftUI error.
            ConnectHostView()
                .environment(library)
        }
    }
}

/// Host management (S01/S02): the welcome/setup screen with no hosts, then
/// the hosts list with per-host connection, version, and auth state.
private struct ServersTab: View {
    let library: HostLibrary
    var onConnectHost: () -> Void

    @State private var hostPendingRemoval: OpenCodeDomain.Host?
    @State private var removalFailure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let storageError = library.storageError {
                    ContentUnavailableView(
                        "Storage Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(storageError)
                    )
                } else if library.entries.isEmpty {
                    WelcomeView(onConnectHost: onConnectHost)
                } else {
                    hostList
                }
            }
        }
        .task { await library.refreshStates() }
    }

    private var hostList: some View {
        List {
            ForEach(library.entries) { entry in
                HostRow(entry: entry)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            hostPendingRemoval = entry.host
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onConnectHost()
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
        }
        .refreshable { await library.refreshStates() }
        .confirmationDialog(
            "Remove \(hostPendingRemoval?.displayName ?? "Host")?",
            isPresented: Binding(
                get: { hostPendingRemoval != nil },
                set: { if !$0 { hostPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from This Device", role: .destructive) {
                removePendingHost()
            }
            Button("Cancel", role: .cancel) { hostPendingRemoval = nil }
        } message: {
            Text("This removes the host and its stored credential from this device. The host server itself is unchanged, and access is not revoked on the server.")
        }
        .alert(
            "Could Not Remove Host",
            isPresented: Binding(
                get: { removalFailure != nil },
                set: { if !$0 { removalFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { removalFailure = nil }
        } message: {
            Text(removalFailure ?? "")
        }
    }

    private func removePendingHost() {
        guard let host = hostPendingRemoval else { return }
        hostPendingRemoval = nil
        do {
            try library.remove(host.id)
        } catch {
            removalFailure = "The host could not be removed from this device."
        }
    }
}

private struct HostRow: View {
    let entry: HostLibrary.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.host.displayName)
                    .font(.headline)
                Spacer()
                statusLabel
            }
            Text(entry.host.address.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch entry.connection {
        case .checking:
            ProgressView()
        case .reachable(let version):
            Text(version.map { "v \($0)" } ?? "Connected")
                .font(.caption)
                .foregroundStyle(.green)
        case .unreachable:
            Text("Unreachable")
                .font(.caption)
                .foregroundStyle(.orange)
        case .reauthRequired:
            Text("Re-pair Required")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// S04 Projects tab (docs/navigation-screens.md): host-scoped project
/// inventory with search, recents, and entry points into S05 Folder
/// browser and S06 New Project. Rows always show name, path and host so a
/// friendly name is never ambiguous.
private struct ProjectsTab: View {
    @Environment(HostLibrary.self) private var library
    @Environment(ProjectsLibrary.self) private var projects
    @State private var hostFilter: HostID?
    @State private var searchText = ""
    @State private var browsing: BrowseTarget?
    @State private var newProjectTarget: NewProjectTarget?

    private struct BrowseTarget: Identifiable {
        let id = UUID()
        let host: OpenCodeDomain.Host
        let credential: BasicCredential?
        let startDirectory: String
    }

    private struct ProjectRow: Identifiable {
        let host: OpenCodeDomain.Host
        let project: Project
        var id: String { host.id.rawValue + "|" + project.id }
    }

    private var rows: [ProjectRow] {
        projects.rows(entries: library.entries, hostFilter: hostFilter, search: searchText)
            .map { ProjectRow(host: $0.host, project: $0.project) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.entries.isEmpty {
                    ContentUnavailableView(
                        "No Hosts Paired",
                        systemImage: "server.rack",
                        description: Text("Pair a host on the Servers tab to see its projects.")
                    )
                } else {
                    projectList
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            if let entry = library.entries.first(where: { hostFilter == nil || $0.id == hostFilter }) ?? library.entries.first {
                                newProjectTarget = NewProjectTarget(
                                    host: entry.host,
                                    credential: library.credential(for: entry.id),
                                    parent: "/"
                                )
                            }
                        } label: {
                            Label("New Project…", systemImage: "folder.badge.plus")
                        }
                        Button {
                            if let entry = library.entries.first(where: { hostFilter == nil || $0.id == hostFilter }) ?? library.entries.first {
                                browsing = BrowseTarget(
                                    host: entry.host,
                                    credential: library.credential(for: entry.id),
                                    startDirectory: "/"
                                )
                            }
                        } label: {
                            Label("Open Unlisted Folder…", systemImage: "folder")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            hostFilter = nil
                        } label: {
                            Label("All Hosts", systemImage: networkImage(selected: hostFilter == nil))
                        }
                        ForEach(library.entries) { entry in
                            Button {
                                hostFilter = entry.id
                            } label: {
                                Label(entry.host.displayName, systemImage: networkImage(selected: hostFilter == entry.id))
                            }
                        }
                    } label: {
                        Label("Host", systemImage: "network")
                    }
                    .accessibilityIdentifier("S04.hostPicker")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search projects")
        .task {
            projects.attach(hosts: library)
            await projects.load(library.entries)
        }
        .refreshable {
            await projects.load(library.entries)
        }
        .sheet(item: $browsing) { target in
            FolderBrowserView(
                host: target.host,
                credential: target.credential,
                startDirectory: target.startDirectory
            ) { resolved in
                projects.noteRecent(host: target.host, location: resolved)
            }
            .environment(library)
        }
        .sheet(item: $newProjectTarget) { target in
            NewProjectView(
                host: target.host,
                credential: target.credential,
                parentDirectory: target.parent
            ) { resolved in
                projects.noteRecent(host: target.host, location: resolved)
                Task { await projects.load(library.entries) }
            }
            .environment(library)
        }
    }

    private func networkImage(selected: Bool) -> String {
        selected ? "checkmark.circle.fill" : "circle"
    }

    private var projectList: some View {
        List {
            if !visibleErrors.isEmpty {
                Section("Host Status") {
                    ForEach(visibleErrors, id: \.id) { error in
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
            if !projects.recentLocations.isEmpty, searchText.isEmpty {
                Section("Recent Folders") {
                    ForEach(Array(projects.recentLocations.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.location.project.canonical)
                                .font(.body.monospaced())
                                .lineLimit(1)
                            Text(item.host.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if rows.isEmpty {
                Section {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Projects" : "No Matches",
                        systemImage: "folder",
                        description: Text(emptyStateDescription)
                    )
                }
            } else {
                Section("Projects") {
                    ForEach(rows) { row in
                        rowView(row)
                            .accessibilityIdentifier("S04.project.row")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("AppBackgroundColor"))
    }

    /// Host load failures relevant to the current filter (missing
    /// credential, unreachable host) — never rendered as "no projects".
    /// Identified by host ID: display names are not unique.
    private var visibleErrors: [(id: HostID, name: String, message: String)] {
        library.entries
            .filter { hostFilter == nil || $0.id == hostFilter }
            .compactMap { entry in
                guard let message = projects.errorsByHost[entry.id] else { return nil }
                return (entry.id, entry.host.displayName, message)
            }
    }

    private var emptyStateDescription: String {
        if !searchText.isEmpty {
            return "No project name or path matches “\(searchText)”."
        }
        if !visibleErrors.isEmpty {
            return "Some hosts could not list projects — see Host Status above."
        }
        return "This host has no projects yet. Use Open Unlisted Folder or New Project."
    }

    @ViewBuilder
    private func rowView(_ row: ProjectRow) -> some View {
        Button {
            browsing = BrowseTarget(
                host: row.host,
                credential: library.credential(for: row.host.id),
                startDirectory: row.project.canonical
            )
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.project.name ?? lastPathSegment(row.project.canonical))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(row.project.canonical)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(row.host.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contextMenu {
            Button {
                browsing = BrowseTarget(
                    host: row.host,
                    credential: library.credential(for: row.host.id),
                    startDirectory: row.project.canonical
                )
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            Button {
                newProjectTarget = NewProjectTarget(
                    host: row.host,
                    credential: library.credential(for: row.host.id),
                    parent: row.project.canonical
                )
            } label: {
                Label("New Project Here…", systemImage: "folder.badge.plus")
            }
        }
    }

    private func lastPathSegment(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// Identity for the S06 New Project sheet: the host it targets plus the
/// absolute existing parent directory.
private struct NewProjectTarget: Identifiable {
    let id: String
    let host: OpenCodeDomain.Host
    let credential: BasicCredential?
    let parent: String

    init(host: OpenCodeDomain.Host, credential: BasicCredential?, parent: String) {
        id = host.id.rawValue + "|" + parent
        self.host = host
        self.credential = credential
        self.parent = parent
    }
}

private struct SettingsTab: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Version", value: appVersion)
                }
                Section("Not Yet Implemented") {
                    Text("Server, appearance, privacy, and storage settings arrive with follow-up slices.")
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color("AppBackgroundColor"))
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    ContentView()
}
