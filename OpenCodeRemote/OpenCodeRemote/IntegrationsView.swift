import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S16 integrations inspector — W14: the effective plugin inventory
/// (docs/navigation-screens.md S16). Every row combines the runtime
/// inventory with the declared directives; a toggle shows its exact
/// JSONC plan before anything is written, and a saved change the host
/// has not applied yet stays visible. The MCP segment arrives with W15.
struct IntegrationsView: View {
    let host: OpenCodeDomain.Host
    let sessionDirectory: String?
    @Bindable var library: IntegrationsLibrary

    var body: some View {
        List {
            if library.isLoading {
                Section { ProgressView("Loading Integrations…") }
            }
            if let error = library.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                    Button("Retry") {
                        Task { await library.load(host: host, sessionDirectory: sessionDirectory) }
                    }
                }
            }
            if let error = library.toggleError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            if let notice = library.notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Plugins") {
                if library.rows.isEmpty, !library.isLoading, library.loadError == nil {
                    Text("No plugins reported by this host.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.rows) { row in
                    rowView(row)
                }
            }
        }
        .refreshable {
            await library.load(host: host, sessionDirectory: sessionDirectory)
        }
        .task {
            await library.load(host: host, sessionDirectory: sessionDirectory)
        }
        .confirmationDialog(
            library.pendingPlan?.description ?? "",
            isPresented: Binding(
                get: { library.pendingPlan != nil },
                set: { if !$0 { library.cancelPendingPlan() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Apply Change") {
                Task { await library.applyToggle(host: host) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The document is re-read before writing; a changed file aborts the save.")
        }
        .navigationTitle("Integrations")
    }

    @ViewBuilder
    private func rowView(_ row: IntegrationsLibrary.PluginRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.id)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("S16.plugins.row.\(row.id)")
                Spacer()
                if row.canEnable {
                    Button("Enable") {
                        Task { await library.planToggle(host: host, target: row.id, enable: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("S16.plugins.enable.\(row.id)")
                } else if row.canDisable {
                    Button("Disable") {
                        Task { await library.planToggle(host: host, target: row.id, enable: false) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("S16.plugins.disable.\(row.id)")
                }
            }
            Text(row.statusText)
                .font(.subheadline)
                .foregroundStyle(row.statusText.hasPrefix("Failed") ? .red : .secondary)
            Text(row.detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let features = row.featuresText {
                Text(features)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !row.declaredInPaths.isEmpty {
                Text("Declared in: \(row.declaredInPaths.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !row.disabledInPaths.isEmpty {
                Text("Disabled by directive in: \(row.disabledInPaths.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if library.unreflected.contains(row.id) {
                Text("Saved — not yet reflected by the host's runtime inventory.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("S16.plugins.ineffective.\(row.id)")
            }
        }
        .padding(.vertical, 2)
    }
}
