import SwiftUI
import OpenCodeDomain

/// Root navigation shell: Servers, Projects, Sessions, Settings
/// (docs/navigation-screens.md).
struct ContentView: View {
    @State private var library = HostLibrary()
    @State private var showingConnectSheet = false

    var body: some View {
        TabView {
            ServersTab(library: library, onConnectHost: { showingConnectSheet = true })
                .tabItem { Label("Servers", systemImage: "server.rack") }
            ProjectsTab()
                .tabItem { Label("Projects", systemImage: "folder") }
            SessionsTab()
                .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right") }
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .background(Color("AppBackgroundColor"))
        .environment(library)
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

private struct ProjectsTab: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Projects",
                systemImage: "folder",
                description: Text("Projects from your connected servers appear here.")
            )
            .navigationTitle("Projects")
        }
    }
}

private struct SessionsTab: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Sessions",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Sessions from your connected servers appear here.")
            )
            .navigationTitle("Sessions")
        }
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
