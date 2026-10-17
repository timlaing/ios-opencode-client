import SwiftUI

/// Root navigation shell: Servers, Projects, Sessions, Settings
/// (docs/navigation-screens.md). Screens are populated in follow-up slices;
/// empty states are honest.
struct ContentView: View {
    @State private var showingConnectSheet = false

    var body: some View {
        TabView {
            ServersTab(onConnectHost: { showingConnectSheet = true })
                .tabItem { Label("Servers", systemImage: "server.rack") }
            ProjectsTab()
                .tabItem { Label("Projects", systemImage: "folder") }
            SessionsTab()
                .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right") }
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .background(Color("AppBackgroundColor"))
        .sheet(isPresented: $showingConnectSheet) {
            ConnectHostView()
        }
    }
}

/// Host management (S01/S02). With no hosts configured this shows the welcome
/// and guided setup screen; a hosts list replaces it once pairing exists.
private struct ServersTab: View {
    var onConnectHost: () -> Void

    var body: some View {
        NavigationStack {
            WelcomeView(onConnectHost: onConnectHost)
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
