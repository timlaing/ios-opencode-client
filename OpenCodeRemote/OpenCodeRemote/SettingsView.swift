import SwiftUI
import OpenCodeDomain

/// Appearance modes map to `preferredColorScheme` at the shell; nil
/// follows the system (the documented default, implementation-
/// defaults.md "Appearance").
extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// S18 — Settings root (docs/navigation-screens.md): settings grouped
/// by OUTCOME, with advanced detail collapsed into the subpages.
/// Only controls backed by a REAL mechanism appear here: the two code
/// controls (size, wrap) join once transcript code blocks exist to
/// consume them. Every default comes from docs/implementation-
/// defaults.md (W17).
struct SettingsView: View {
    @Environment(HostLibrary.self) private var hosts
    @Environment(SettingsLibrary.self) private var settings

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Hosts") {
                    NavigationLink {
                        HostsSettingsView()
                    } label: {
                        LabeledContent("Configured", value: "\(hosts.entries.count)")
                    }
                }

                Section("Appearance") {
                    Picker("Mode", selection: binding(\.appearance)) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue.capitalized).tag(mode)
                        }
                    }
                    Picker("Spacing", selection: binding(\.spacing)) {
                        ForEach(TextSpacing.allCases, id: \.self) { spacing in
                            Text(spacing.rawValue.capitalized).tag(spacing)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        PrivacyStorageView()
                    } label: {
                        Text("Privacy, Storage & Sync")
                    }
                }

                // "Attachments & Network" WITHHELD (review W17 r4):
                // uploadWarningThreshold, allowCellularUploads and
                // continueBackgroundUploads persist, but nothing
                // reads them — the attachment pipeline still uses
                // its static threshold and cannot yet restrict
                // cellular or background transfers. Controls appear
                // only when a real mechanism honours them.

                Section("Notifications & Activities") {
                    NavigationLink {
                        NotificationsSettingsView()
                    } label: {
                        Text("Notifications & Live Activities")
                    }
                }

                Section("Diagnostics & Support") {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Text("Diagnostics & Support")
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color("AppBackgroundColor"))
            .navigationTitle("Settings")
        }
    }

    /// Settings edits must PERSIST (`SettingsLibrary.update`): a
    /// straight `@Observable` binding would mutate the in-memory state
    /// and silently skip the UserDefaults write.
    private func binding<T>(_ keyPath: WritableKeyPath<SettingsState, T>) -> Binding<T> {
        Binding(
            get: { settings.state[keyPath: keyPath] },
            set: { newValue in settings.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
