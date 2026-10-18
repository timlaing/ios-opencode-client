import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S08 conversation (W04, read scope): the paged transcript with honest
/// per-variant rendering — user bubbles, assistant content blocks
/// (reasoning, text, tool rows by state), and compact transition rows for
/// bookkeeping variants (switches, compaction, idle, unknown).
/// Sending/stopping/inbox live in W05.
struct ConversationView: View {
    let host: OpenCodeDomain.Host
    let session: Session
    var sessions: SessionsLibrary?

    @Environment(HostLibrary.self) private var library
    @State private var conversation = ConversationLibrary()
    @State private var showingContext = false

    var body: some View {
        Group {
            if conversation.messages.isEmpty, conversation.isLoading {
                ProgressView("Loading Conversation…")
            } else if conversation.messages.isEmpty, conversation.error != nil {
                // Not scrollable — pull-to-refresh is dead here, so the
                // state MUST carry its own retry action.
                ContentUnavailableView {
                    Label("Conversation Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(conversation.error ?? "")
                } actions: {
                    Button("Try Again") {
                        Task { await openTranscript() }
                    }
                }
            } else if conversation.messages.isEmpty {
                ContentUnavailableView {
                    Label("No Messages Yet", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("This session has no messages yet. W05 adds sending the first prompt.")
                } actions: {
                    Button("Refresh") {
                        Task { await openTranscript() }
                    }
                }
            } else {
                transcript
            }
        }
        .navigationTitle(session.title ?? "Untitled Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingContext = true
                } label: {
                    Label("Active Context", systemImage: "square.stack.3d.up")
                }
                .accessibilityIdentifier("S08.context")
            }
        }
        .sheet(isPresented: $showingContext) {
            NavigationStack {
                ContextPanelView(conversation: conversation, host: host, session: session)
                    .navigationTitle("Active Context")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingContext = false }
                        }
                    }
            }
        }
        .refreshable {
            await conversation.refresh(host: host, sessionID: session.id)
        }
        .task {
            conversation.attach(hosts: library)
            await openTranscript()
        }
    }

    /// Opens the transcript and acknowledges unread ONLY when it actually
    /// showed (error nil + session matched) — a failed open must not
    /// clear unread, and a successful retry must.
    private func openTranscript() async {
        await conversation.open(host: host, sessionID: session.id)
        if conversation.error == nil, conversation.loadedSessionID == session.id {
            await sessions?.markViewed(host: host, session: session)
        }
    }

    private var transcript: some View {
        List {
            if conversation.hasMore {
                Section {
                    Button {
                        Task { await conversation.loadOlder(host: host) }
                    } label: {
                        if conversation.isLoadingMore {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Loading Older Messages…")
                            }
                        } else {
                            Label("Load Older Messages", systemImage: "chevron.up")
                        }
                    }
                    .disabled(conversation.isLoadingMore)
                    .accessibilityIdentifier("S08.loadOlder")
                }
            }
            if let error = conversation.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .accessibilityIdentifier("S08.error")
                }
            }
            Section {
                ForEach(conversation.messages) { message in
                    messageRow(message)
                        .accessibilityIdentifier("S08.message.\(message.id)")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Message rendering

    @ViewBuilder
    private func messageRow(_ message: SessionMessage) -> some View {
        switch message.kind {
        case .user(let text, let files):
            VStack(alignment: .trailing, spacing: 6) {
                markdown(text)
                    .padding(10)
                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                    Label(file.name ?? file.mime, systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.vertical, 2)

        case .assistant(let agent, let model, let content, let error, _):
            VStack(alignment: .leading, spacing: 6) {
                Text([agent, model.map { "\($0.providerID)/\($0.id)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(content.enumerated()), id: \.offset) { _, item in
                    contentItemView(item)
                }
                if let error {
                    Label(error.message ?? error.name ?? "The assistant failed.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 2)

        case .synthetic(let text, let description):
            compactRow(description ?? text, systemImage: "sparkles")

        case .system(let text, let description):
            compactRow(description ?? text, systemImage: "info.circle")

        case .skill(_, let name, _):
            compactRow("Skill: \(name)", systemImage: "hammer")

        case .shell(_, let command, let status, _, _):
            compactRow("$ \(command) — \(status)", systemImage: "terminal")

        case .agentSwitched(let agent, _):
            compactRow("Switched to \(agent) agent", systemImage: "person.2.badge.gearshape")

        case .modelSwitched(let model, _):
            compactRow("Switched to \(model?.id ?? "another model")", systemImage: "cpu")

        case .locationSwitched(_, _, let directory):
            compactRow("Moved to \(directory ?? "another location")", systemImage: "folder")

        case .compaction(let status, _, let summary, let errorMessage):
            compactRow(
                "Context compaction \(status)" + (errorMessage.map { ": \($0)" } ?? ""),
                systemImage: "arrow.down.circle",
                secondary: summary
            )

        case .idle(let outcome):
            compactRow("Turn ended (\(outcome))", systemImage: "checkmark.circle")

        case .unknown(let type, _):
            // Never silently dropped: the variant stays visible.
            compactRow("Unsupported message (\(type))", systemImage: "questionmark.square")
        }
    }

    @ViewBuilder
    private func contentItemView(_ item: SessionMessage.ContentItem) -> some View {
        switch (item.type, item.state) {
        case ("text", _):
            if let text = item.text {
                markdown(text)
            }
        case ("reasoning", _):
            DisclosureGroup {
                if let text = item.text {
                    markdown(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Label("Reasoning", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case ("tool", .some(let state)):
            toolRow(name: item.name ?? "tool", state: state)
        case ("tool", nil):
            compactRow(item.name ?? "tool", systemImage: "wrench")
        default:
            compactRow("content: \(item.type)", systemImage: "questionmark.square")
        }
    }

    @ViewBuilder
    private func toolRow(name: String, state: SessionMessage.ToolState) -> some View {
        switch state {
        case .streaming, .running:
            HStack(spacing: 8) {
                ProgressView()
                Label("\(name) — running…", systemImage: "wrench")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .completed(_, let content):
            let preview = content.compactMap { item -> String? in
                if case .text(let text) = item.kind { return text }
                return nil
            }.first
            compactRow(preview.map { "\(name): \($0)" } ?? name, systemImage: "checkmark.circle")
        case .error(_, let error, _):
            Label(
                "\(name): \(error.message ?? error.name ?? "failed")",
                systemImage: "xmark.circle"
            )
            .font(.footnote)
            .foregroundStyle(.red)
        case .unknown(let status, _):
            compactRow("\(name) (\(status))", systemImage: "questionmark.circle")
        }
    }

    private func compactRow(_ text: String, systemImage: String, secondary: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(text, systemImage: systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let secondary {
                markdown(secondary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    /// Inline-only markdown so user/assistant text renders formatting
    /// without executing anything.
    private func markdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(verbatim: text)
    }
}

/// S14 active-context panel (W04 minimal consumer): what the server says
/// is currently in the model's context since the last compaction. The
/// full usage/cost panel belongs to W13.
struct ContextPanelView: View {
    let conversation: ConversationLibrary
    let host: OpenCodeDomain.Host
    let session: Session

    private var countsByType: [(type: String, count: Int)] {
        Dictionary(grouping: conversation.activeContext, by: \.rawType)
            .map { (type: $0.key, count: $0.value.count) }
            .sorted { $0.type < $1.type }
    }

    var body: some View {
        List {
            if conversation.isLoadingContext {
                Section { ProgressView("Loading Context…") }
            }
            if let error = conversation.contextError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            Section("Since Last Compaction") {
                LabeledContent("Messages", value: "\(conversation.activeContext.count)")
                LabeledContent("Session ID", value: session.id)
            }
            Section("By Message Type") {
                ForEach(countsByType, id: \.type) { entry in
                    LabeledContent(entry.type, value: "\(entry.count)")
                        .accessibilityIdentifier("S14.context.row.\(entry.type)")
                }
            }
        }
        .task {
            await conversation.loadContext(host: host, sessionID: session.id)
        }
    }
}
