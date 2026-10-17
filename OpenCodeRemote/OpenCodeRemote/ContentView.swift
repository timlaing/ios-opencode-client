import SwiftUI

/// Root navigation shell: Projects, Sessions, Settings (docs/navigation-screens.md).
/// Screens are populated in follow-up slices; the tabs currently show honest
/// empty states.
struct ContentView: View {
    @State private var showingConnectSheet = false

    var body: some View {
        TabView {
            ProjectsTab(onConnectHost: { showingConnectSheet = true })
                .tabItem { Label("Projects", systemImage: "folder") }
            SessionsTab()
                .tabItem { Label("Sessions", systemImage: "bubble.left.and.bubble.right") }
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showingConnectSheet) {
            ConnectHostView()
        }
    }
}

private struct ProjectsTab: View {
    var onConnectHost: () -> Void

    var body: some View {
        NavigationStack {
            WelcomeView(onConnectHost: onConnectHost)
        }
    }
}

private struct SessionsTab: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Sessions",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Sessions from your configured hosts appear here.")
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
                    Text("Hosts, appearance, privacy, and storage settings arrive with follow-up slices.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    ContentView()
}
