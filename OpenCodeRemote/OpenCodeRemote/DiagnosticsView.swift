import SwiftUI

/// S20 — Diagnostics & support (docs/navigation-screens.md): the
/// last error, the redacted log with its retention story, export and
/// clear, the honest local-push status with the counts that will
/// appear once delivery activates, and the source/licence inventory.
/// "Retry Local Push" from the inventory has no mechanism to retry
/// while the pipeline is dormant, so it does not exist yet — the
/// status explains why (the docs' honesty rule: never present a
/// control with no real mechanism behind it).
struct DiagnosticsView: View {
    /// Stateless value over the one log file — no environment needed.
    @State private var log = DiagnosticsLogStore()

    @State private var entries: [DiagnosticsEntry] = []
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showingClear = false

    var body: some View {
        List {
            lastErrorSection
            logSection
            pushSection
            sourceSection
        }
        .scrollContentBackground(.hidden)
        .background(Color("AppBackgroundColor"))
        .navigationTitle("Diagnostics & Support")
        .task { refresh() }
    }

    // MARK: - Last error

    private var lastErrorSection: some View {
        Section("Last Error") {
            if let error = log.latestError() {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.message)
                        .font(.footnote)
                    Text("\(error.category.rawValue) · \(error.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Nothing has failed since the last clear.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section {
            if entries.isEmpty {
                Text("No events recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                // entries() is oldest-first — suffix keeps the
                // NEWEST 20 (review W17 r1).
                ForEach(entries.suffix(20).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .font(.footnote)
                        Text("\(entry.category.rawValue) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Export Diagnostic Logs", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    do {
                        exportURL = try log.exportURL()
                        exportError = nil
                    } catch {
                        exportError = "Export failed: \(error.localizedDescription)"
                    }
                } label: {
                    Label("Export Diagnostic Logs", systemImage: "square.and.arrow.up")
                }
            }
            if let exportError {
                Text(exportError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button("Clear Logs", role: .destructive) {
                showingClear = true
            }
        } header: {
            Text("Recent Events")
        } footer: {
            Text("Kept on this device for 7 days, capped at 5 MiB, never uploaded. Addresses and URLs are redacted before storage; eligible network names are recorded only as counts.")
        }
        .confirmationDialog(
            "Clear the diagnostic log?",
            isPresented: $showingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Logs", role: .destructive) {
                log.clear()
                refresh()
            }
        } message: {
            Text("Every recorded event and the last-error display are removed. Hosts, drafts, and settings are untouched.")
        }
    }

    // MARK: - Local push

    private var pushSection: some View {
        Section {
            LabeledContent("Delivery", value: "Not Active")
            LabeledContent("Received Events", value: "—")
            LabeledContent("Relevant Events", value: "—")
            LabeledContent("Scheduled Notifications", value: "—")
        } header: {
            Text("Local Push")
        } footer: {
            Text("Background delivery is pending Apple approval of the app's push entitlement; counts appear here once it activates, each kept separate — received, relevant, and scheduled are never merged into one number.")
        }
    }

    // MARK: - Source & licences

    private var sourceSection: some View {
        Section("Source & Licences") {
            LabeledContent("OpenCode baseline", value: "v2.0.25 · MIT")
            LabeledContent("GRDB", value: "7.11.1 · MIT")
            LabeledContent("This app", value: "MPL-2.0")
        }
    }

    private func refresh() {
        entries = log.entries()
        exportURL = nil
        exportError = nil
    }
}
