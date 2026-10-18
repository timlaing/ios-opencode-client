import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S10 model/agent picker (W06): searchable host inventories with
/// honest selected / default / unavailable states. Tapping a row runs
/// the native session switch; the checkmark moves ONLY after the host's
/// 204 — a rejected switch leaves the previous selection visible and
/// shows the failure. Disabled/deprecated models stay listed but are
/// never selectable. Commands and skills join this sheet with W07.
struct ModelAgentPickerView: View {
    let host: OpenCodeDomain.Host
    let session: Session
    /// Owned by the presenting view so the environment is captured there
    /// (sheets do not receive `.environment` from their presenter).
    let selection: SelectionLibrary
    var sessions: SessionsLibrary?

    @State private var query = ""

    private var term: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredModels: [ModelInfo] {
        guard !term.isEmpty else { return selection.models }
        return selection.models.filter {
            $0.name.lowercased().contains(term)
                || $0.providerID.lowercased().contains(term)
                || $0.modelID.lowercased().contains(term)
        }
    }

    private var filteredAgents: [AgentInfo] {
        let offerable = selection.agents.filter(\.isOfferedAsPrimary)
        guard !term.isEmpty else { return offerable }
        return offerable.filter {
            $0.name.lowercased().contains(term)
                || ($0.description?.lowercased().contains(term) ?? false)
        }
    }

    var body: some View {
        List {
            if selection.isLoading {
                Section { ProgressView("Loading Models and Agents…") }
            }
            if let error = selection.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("S10.error")
                }
            }
            if !selection.isLoading, selection.models.isEmpty, selection.agents.isEmpty, selection.error == nil {
                Section {
                    ContentUnavailableView(
                        "Nothing to Select",
                        systemImage: "slider.horizontal.3",
                        description: Text("This host reported no models or agents.")
                    )
                    .accessibilityIdentifier("S10.empty")
                }
            } else {
                Section("Models") {
                    if filteredModels.isEmpty {
                        Text(term.isEmpty ? "The host reported no models." : "No models match your search.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("S10.models.empty")
                    } else {
                        ForEach(filteredModels) { model in
                            modelRow(model)
                        }
                    }
                }
                Section("Agents") {
                    if filteredAgents.isEmpty {
                        Text(term.isEmpty ? "The host reported no offerable agents." : "No agents match your search.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("S10.agents.empty")
                    } else {
                        ForEach(filteredAgents) { agent in
                            agentRow(agent)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search models and agents")
        .task {
            await selection.load(host: host, session: session)
        }
    }

    // MARK: - Rows

    private func modelRow(_ model: ModelInfo) -> some View {
        Button {
            Task {
                _ = await selection.selectModel(
                    host: host, sessionID: session.id, model: model, sessions: sessions
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if isSelected(model) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("S10.model.\(model.id).selected")
                    }
                    if isDefault(model) {
                        Text("Default")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(model.providerID) · \(model.modelID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(contextLimit(model))
                    if model.acceptsImages {
                        Label("Images", systemImage: "photo")
                            .labelStyle(.iconOnly)
                    }
                    if model.acceptsPDFs {
                        Label("PDFs", systemImage: "doc")
                            .labelStyle(.iconOnly)
                    }
                    if !model.variants.isEmpty {
                        Text("\(model.variants.count) variant\(model.variants.count == 1 ? "" : "s")")
                    }
                    if let cost = model.cost.first {
                        // Flat pricing display; tiered pricing keeps its
                        // first reported tier rather than inventing a
                        // single blended number.
                        Text(String(format: "$%.2f in / $%.2f out per M", cost.input, cost.output))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if !model.isSelectable {
                    Text(model.enabled ? "Deprecated — not selectable" : "Unavailable on this host")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("S10.model.\(model.id).unavailable")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!model.isSelectable || selection.isSwitching)
        .accessibilityIdentifier("S10.model.\(model.id)")
    }

    private func agentRow(_ agent: AgentInfo) -> some View {
        Button {
            Task {
                _ = await selection.selectAgent(
                    host: host, sessionID: session.id, agent: agent, sessions: sessions
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if selection.selectedAgentID == agent.id {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("S10.agent.\(agent.id).selected")
                    }
                    Text(agent.mode.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let description = agent.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(selection.isSwitching)
        .accessibilityIdentifier("S10.agent.\(agent.id)")
    }

    // MARK: - Presentation helpers

    private func isSelected(_ model: ModelInfo) -> Bool {
        selection.selectedRef?.id == model.id && selection.selectedRef?.providerID == model.providerID
    }

    private func isDefault(_ model: ModelInfo) -> Bool {
        selection.defaultModel?.id == model.id && selection.defaultModel?.providerID == model.providerID
    }

    private func contextLimit(_ model: ModelInfo) -> String {
        model.limit.context >= 1000
            ? "\(model.limit.context / 1000)K context"
            : "\(model.limit.context) context"
    }
}
