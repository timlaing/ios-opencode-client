import SwiftUI
import OpenCodeDomain
import OpenCodeStorage
import OpenCodeTransport

/// Root navigation shell: Servers, Projects, Sessions, Settings
/// (docs/navigation-screens.md).
struct ContentView: View {
    @State private var library = HostLibrary()
    /// Shared across Projects and Sessions (recent locations feed
    /// New Session; project inventory feeds the S07 project filter).
    @State private var projects = ProjectsLibrary()
    @State private var showingConnectSheet = false
    /// W17: shared from the shell so Clear Local Data (S19) wipes the
    /// SAME live stores every screen renders from — a second store
    /// over the same domain would leave stale rows until relaunch.
    @State private var settings = SettingsLibrary()
    @State private var localState = SessionLocalStateStore()
    /// W17 S17: the permission state every notifications screen reads.
    /// The diagnostic log is a stateless value over one file — each
    /// consumer constructs its own handle.
    @State private var notifications = NotificationsLibrary()
    /// W17 I6: the opt-in iCloud settings sync (S19). One instance so
    /// the external-change subscription and the local mirror are
    /// shared app-wide.
    @State private var cloud = CloudSettingsSync()
    /// W17 r2: the foreground pull — an iCloud edit made on another
    /// device converges when the app becomes active, not only when
    /// S19 opens.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ServersTab(library: library, onConnectHost: { showingConnectSheet = true })
                .tabItem { Label("Servers", systemImage: "server.rack") }
            ProjectsTab()
                .tabItem { Label("Projects", systemImage: "folder") }
            SessionsView(localState: localState)
                .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .background(Color("AppBackgroundColor"))
        // Appearance ▸ Mode (W17): nil follows the system — the
        // documented default; light/dark force the scheme shell-wide.
        .preferredColorScheme(settings.state.appearance.colorScheme)
        .environment(library)
        .environment(projects)
        .environment(settings)
        .environment(localState)
        .environment(notifications)
        .environment(cloud)
        // W17 I6: the store's external-change notification reaches
        // the engine (quota refusal → status; server push / initial
        // sync → the reconcile hook below). Stored closures capture
        // REFERENCES (nextHead lesson), never the view struct.
        .onAppear {
            let cloud = self.cloud
            let settings = self.settings
            let library = self.library
            cloud.onExternalChange = {
                Self.reconcileCloudSync(cloud: cloud, settings: settings, library: library)
            }
            cloud.observeExternalChanges()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // The foreground pull (review W17 r2) — and the COLD
            // LAUNCH pull (review W17 r6): without initial: true the
            // action never fires for the first render, and a relaunch
            // receives no external-change notification for edits that
            // already landed, so a change from another device would
            // stay unapplied until the first background/foreground
            // cycle or an S19 open. The engine is opt-in gated: sync
            // off converges nothing.
            guard phase == .active else { return }
            Self.reconcileCloudSync(cloud: cloud, settings: settings, library: library)
        }
        .onChange(of: settings.state.appearance) { _, _ in
            // Local sync-scope edit → push on the edit itself (review
            // W17 r8). Opt-in gated in the engine: sync off no-ops.
            Self.reconcileCloudSync(cloud: cloud, settings: settings, library: library)
        }
        .onChange(of: library.entries.map { $0.id.rawValue + "|" + $0.host.address.absoluteString }) { _, _ in
            // Host add/remove/re-pair → push on the change (review
            // W17 r8). Connection state is deliberately NOT in the
            // fingerprint: probe results (checking → reachable) are
            // not sync-scope edits.
            Self.reconcileCloudSync(cloud: cloud, settings: settings, library: library)
        }
        // W17 drafts retention: one sweep per launch removes drafts
        // older than the active policy's cutoff (until-discarded
        // sweeps nothing — see ComposerDraftStore.applyRetention).
        .task {
            if let drafts = try? DraftStore(writingAt: StorageLibrary.defaultDraftsDirectory) {
                ComposerDraftStore(drafts: drafts).applyRetention(settings)
            }
        }
        .sheet(isPresented: $showingConnectSheet) {
            // Injected explicitly rather than relying on sheet environment
            // inheritance — a missing HostLibrary or CloudSettingsSync is
            // a fatal SwiftUI error.
            ConnectHostView()
                .environment(library)
                .environment(cloud)
        }
    }

    /// One pull-merge-push pass — the call S19 makes, from the
    /// SHELL: external KVS pushes and the scene returning to active
    /// converge here too (review W17 r2). Static so the stored
    /// external-change hook captures only the three references.
    private static func reconcileCloudSync(
        cloud: CloudSettingsSync, settings: SettingsLibrary, library: HostLibrary
    ) {
        // An unreadable host store is NOT "every host removed":
        // hostAddresses would be empty, and the tombstone loop would
        // delete every synced host for every device (review W17 r8).
        // HostLibrary.reload() runs synchronously in init, so with no
        // storage error the inventory IS authoritative — genuinely
        // empty means genuinely empty.
        guard library.storageError == nil else { return }
        cloud.reconcile(
            settings: settings,
            hostAddresses: Dictionary(
                library.entries.map { ($0.id.rawValue, $0.host.address.absoluteString) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

}

/// Host management (S01/S02): the welcome/setup screen with no hosts, then
/// the hosts list with per-host connection, version, and auth state.
private struct ServersTab: View {
    let library: HostLibrary
    var onConnectHost: () -> Void

    /// W17 r2: Remove Host clears the host's local settings too
    /// (implementation-defaults.md I5) — read from the shell's
    /// injection, like ProjectsTab reads ProjectsLibrary.
    @Environment(SettingsLibrary.self) private var settings

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
        case .invalidResponse:
            Text("Not OpenCode")
                .font(.caption)
                .foregroundStyle(.orange)
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
        // Keyed on the paired-host IDs: TabView keeps this view alive, so
        // a host paired on Servers afterwards must still get its projects
        // loaded (plain .task would run only on first appearance).
        .task(id: library.entries.map(\.id.rawValue)) {
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
                            // The chosen DIRECTORY, not the project root that
                            // contains it (noteRecent stores what the user
                            // picked; two subfolders are two rows).
                            Text(item.location.directory)
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

#Preview {
    ContentView()
}
