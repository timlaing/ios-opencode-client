import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S08 conversation (W04 read scope + W05 writing): the paged transcript
/// with honest per-variant rendering — user bubbles, assistant content
/// blocks (reasoning, text, tool rows by state), and compact transition
/// rows for bookkeeping variants (switches, compaction, idle, unknown).
/// The composer sends prompts by durable admission (stable `msg_` ID,
/// reconciled by inbox/transcript search on failure), Stop is an ordinary
/// `interrupt?resume=false`, and the inbox (S09) manages admitted-but-
/// undelivered work. The S10 model/agent picker (W06) opens from this
/// toolbar. Live event streaming arrives with W16.
struct ConversationView: View {
    let host: OpenCodeDomain.Host
    let session: Session
    var sessions: SessionsLibrary?

    @Environment(HostLibrary.self) private var library
    @State private var conversation = ConversationLibrary()
    @State private var selection = SelectionLibrary()
    @State private var showingSelection = false
    @State private var showingContext = false
    @State private var showingInbox = false
    /// Preserved across failures — cleared ONLY on durable admission.
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            transcriptArea
            banners
            composer
        }
        .navigationTitle(session.title ?? "Untitled Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSelection = true
                } label: {
                    Label("Model and Agent", systemImage: "cpu")
                }
                .accessibilityIdentifier("S10.open")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingInbox = true
                } label: {
                    Label("Pending Prompts", systemImage: "tray.full")
                }
                .accessibilityIdentifier("S08.inbox")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingContext = true
                } label: {
                    Label("Active Context", systemImage: "square.stack.3d.up")
                }
                .accessibilityIdentifier("S08.context")
            }
        }
        .sheet(isPresented: $showingSelection) {
            // State and environment are injected HERE — `.environment`
            // on the presenter does not reach into the sheet.
            NavigationStack {
                ModelAgentPickerView(
                    host: host, session: session, selection: selection, sessions: sessions
                )
                .navigationTitle("Model & Agent")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingSelection = false }
                    }
                }
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
        .sheet(isPresented: $showingInbox) {
            NavigationStack {
                InboxListView(conversation: conversation, host: host, sessionID: session.id)
                    .navigationTitle("Pending Prompts")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingInbox = false }
                        }
                    }
            }
        }
        .refreshable {
            await conversation.refresh(host: host, sessionID: session.id)
        }
        .task {
            conversation.attach(hosts: library)
            selection.attach(hosts: library)
            await openTranscript()
        }
    }

    /// Empty/error states or the transcript itself — extracted so the
    /// composer stays mounted in EVERY state: the first prompt must be
    /// sendable into an empty session.
    private var transcriptArea: some View {
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
                    Text("This session has no messages yet — send the first prompt below.")
                } actions: {
                    Button("Refresh") {
                        Task { await openTranscript() }
                    }
                }
            } else {
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var banners: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = conversation.bannerError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("S08.banner.error")
            }
            if let notice = conversation.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("S08.banner.notice")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .accessibilityIdentifier("S08.composer.field")
            Button {
                Task {
                    let text = draft
                    // The draft is cleared ONLY when admission is durable
                    // (directly or reconciled) AND the field still holds
                    // what was sent — text typed DURING the send is kept.
                    if await conversation.send(host: host, sessionID: session.id, text: text) {
                        if draft == text { draft = "" }
                    }
                }
            } label: {
                if conversation.isSending {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
            }
            .disabled(
                draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || conversation.isSending
            )
            .accessibilityIdentifier("S08.composer.send")
            Button {
                Task { await conversation.stop(host: host, sessionID: session.id) }
            } label: {
                Label("Stop", systemImage: "stop.circle")
                    .labelStyle(.iconOnly)
                    .font(.title)
            }
            .disabled(conversation.isSending)
            .accessibilityIdentifier("S08.stop")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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

/// S09 connected-session inbox (W05): admitted-but-undelivered work
/// (`session.inbox.list`). Delivery changes (`steer`/`queue`) and cancel
/// run through their native operations; an unavailable item that cancels
/// as a server-side no-op is simply verified gone on the next read.
struct InboxListView: View {
    let conversation: ConversationLibrary
    let host: OpenCodeDomain.Host
    let sessionID: String

    var body: some View {
        List {
            if conversation.isLoadingInbox {
                Section { ProgressView("Loading Pending Prompts…") }
            }
            if let error = conversation.inboxError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .accessibilityIdentifier("S09.error")
                }
            }
            if conversation.inboxItems.isEmpty, !conversation.isLoadingInbox, conversation.inboxError == nil {
                Section {
                    ContentUnavailableView(
                        "Nothing Pending",
                        systemImage: "tray",
                        description: Text("Admitted prompts that have not been delivered to the transcript appear here.")
                    )
                }
            } else {
                ForEach(conversation.inboxItems) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title(for: item))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(3)
                        HStack(spacing: 12) {
                            Menu {
                                Button("Deliver: Steer") {
                                    Task {
                                        await conversation.setDelivery(
                                            host: host, sessionID: sessionID, inboxID: item.id, delivery: .steer
                                        )
                                    }
                                }
                                Button("Deliver: Queue") {
                                    Task {
                                        await conversation.setDelivery(
                                            host: host, sessionID: sessionID, inboxID: item.id, delivery: .queue
                                        )
                                    }
                                }
                            } label: {
                                Label("Delivery: \(item.delivery.rawValue.capitalized)", systemImage: "arrow.triangle.branch")
                                    .font(.caption)
                            }
                            .accessibilityIdentifier("S09.delivery.\(item.id)")

                            Button(role: .destructive) {
                                Task {
                                    await conversation.cancelInbox(host: host, sessionID: sessionID, inboxID: item.id)
                                }
                            } label: {
                                Label("Cancel", systemImage: "trash")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption)
                            }
                            .accessibilityIdentifier("S09.cancel.\(item.id)")
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("S09.item.\(item.id)")
                }
            }
        }
        .task {
            await conversation.loadInbox(host: host, sessionID: sessionID)
        }
    }

    private func title(for item: InboxItem) -> String {
        switch item.kind {
        case .user(let text, _, _):
            return text
        case .synthetic(let text, _):
            return text
        case .compaction:
            // Unknown variants decode into the raw-payload case but keep
            // their own type name — never mislabelled as compaction.
            return item.rawType == "compaction" ? "Context compaction" : "Pending \(item.rawType)"
        case .move(_, _, let directory):
            return "Move to \(directory ?? "another location")"
        }
    }
}
