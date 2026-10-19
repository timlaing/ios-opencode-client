import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S16 integrations inspector — W14: the effective plugin inventory,
/// W15: the runtime MCP segment (docs/navigation-screens.md S16).
/// Every plugin row combines the runtime inventory with the declared
/// directives; a toggle shows its exact JSONC plan before anything is
/// written, and a saved change the host has not applied yet stays
/// visible. MCP rows separate configured intent from runtime status
/// and offer Connect/Disconnect as RUNTIME controls only — a
/// `needs_auth` server shows host setup guidance instead of a
/// success toggle that could not succeed.
struct IntegrationsView: View {
    let host: OpenCodeDomain.Host
    let sessionDirectory: String?
    @Bindable var library: IntegrationsLibrary

    /// The two S16 segments (docs/navigation-screens.md S16).
    enum Segment: String, CaseIterable, Identifiable {
        case plugins = "Plugins"
        case mcp = "MCP"
        var id: String { rawValue }
    }

    @State private var segment: Segment = .plugins

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
            Picker("Inspector", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("S16.segment")

            if segment == .plugins {
                Section("Plugins") {
                    if library.rows.isEmpty, !library.isLoading, library.loadError == nil {
                        Text("No plugins reported by this host.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.rows) { row in
                        rowView(row)
                    }
                }
            } else {
                Section("MCP") {
                    // This segment's OWN failure renders HERE — a
                    // failed or mismatched mcp.list never blanks the
                    // Plugins segment (W15 review round 1).
                    if let mcpError = library.mcpError {
                        Label(mcpError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                            .accessibilityIdentifier("S16.mcp.error")
                    } else if library.mcpRows.isEmpty, !library.isLoading, library.loadError == nil {
                        Text("No MCP servers reported by this host.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("S16.mcp.empty")
                    }
                    ForEach(library.mcpRows) { row in
                        mcpRowView(row)
                    }
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
            "Apply the plugin change?",
            isPresented: Binding(
                get: { library.pendingPlan != nil },
                set: { if !$0 { library.cancelPendingPlan() } }
            ),
            titleVisibility: .visible,
            presenting: library.pendingPlan
        ) { plan in
            // The plan arrives BY VALUE from the presenting overload —
            // never re-read from state the dismissal write clears.
            Button("Apply Change") {
                Task { await library.applyToggle(host: host, plan: plan) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text("The document is re-read before writing; a changed file aborts the save. (\(plan.description))")
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
                    .disabled(library.isToggling)
                    .accessibilityIdentifier("S16.plugins.enable.\(row.id)")
                } else if row.canDisable {
                    Button("Disable") {
                        Task { await library.planToggle(host: host, target: row.id, enable: false) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.isToggling)
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

    /// The setup guide for MCP authentication (the currently
    /// supported host path: `/mcps` on the host — verified
    /// opencode.ai docs; http(s) link only, house rule).
    private static let mcpSetupGuide = URL(string: "https://opencode.ai/v2/docs/mcp-servers")!

    @ViewBuilder
    private func mcpRowView(_ row: IntegrationsLibrary.McpRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("S16.mcp.row.\(row.name)")
                Spacer()
                // Runtime controls only — never a persisted enabled
                // flag (docs/api-contract.md W15). Row-level gating
                // (pending / needs_auth / unknown status) lives on
                // `canConnect`/`canDisconnect`.
                if row.canConnect {
                    Button("Connect (runtime)") {
                        Task {
                            await library.mcpAction(
                                host: host, server: row.name, connect: true,
                                sessionDirectory: sessionDirectory
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(library.isToggling)
                    .accessibilityIdentifier("S16.mcp.connect.\(row.name)")
                } else if row.canDisconnect {
                    Button("Disconnect (runtime)") {
                        Task {
                            await library.mcpAction(
                                host: host, server: row.name, connect: false,
                                sessionDirectory: sessionDirectory
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.isToggling)
                    .accessibilityIdentifier("S16.mcp.disconnect.\(row.name)")
                }
            }
            Text(row.statusText)
                .font(.subheadline)
                .foregroundStyle(row.status.kind == .failed ? Color.red : Color.secondary)
                .accessibilityIdentifier("S16.mcp.status.\(row.name)")
            Text(row.intentText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("S16.mcp.intent.\(row.name)")
            if row.status.kind == .needsAuth {
                // Sign-in runs on the HOST: show the state and the
                // currently supported setup path — never a success
                // toggle that could not succeed.
                Text("Sign-in is completed on the host: open OpenCode, run /mcps, select this server and sign in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("S16.mcp.authguide.\(row.name)")
                Link("Open the MCP setup guide", destination: Self.mcpSetupGuide)
                    .font(.footnote)
                    .accessibilityIdentifier("S16.mcp.authlink.\(row.name)")
            }
            if library.mcpActionServer == row.name {
                Text("Applying…")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("S16.mcp.inflight.\(row.name)")
            }
        }
        .padding(.vertical, 2)
    }
}
