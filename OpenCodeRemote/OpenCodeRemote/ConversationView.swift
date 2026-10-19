import SwiftUI
import OpenCodeDomain
import OpenCodeTransport
import PhotosUI
import UniformTypeIdentifiers

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
    /// W09 approvals (S11): pending-permission dock above the
    /// composer; the detail sheet opens from it.
    @State private var approvals = ApprovalLibrary()
    @State private var showingApproval = false
    /// W10 forms (S12): pending-question dock beside the approval dock
    /// (docs/navigation-screens.md S08/S12); the detail sheet opens
    /// from it.
    @State private var forms = FormLibrary()
    @State private var showingForm = false
    /// Preserved across failures — cleared ONLY on durable admission.
    @State private var draft = ""
    /// W08 attachments (S09): prepared per the web inline/staging rule;
    /// chips mirror the tray beside the draft.
    @State private var attachments = AttachmentLibrary()
    @State private var showingTray = false
    @State private var showingCamera = false
    @State private var showingFileImporter = false
    @State private var photoSelection: [PhotosPickerItem] = []
    /// W11 Files inspector (S13): read-only tree + preview over the
    /// session's workspace; opens from the trailing toolbar button.
    @State private var showingFiles = false
    /// W12 Changes inspector (S15): session-turn/workspace diffs over
    /// the session's location; opens from the trailing toolbar button.
    @State private var showingChanges = false
    /// Which queued confirmation is on screen. The library's queue is
    /// the source of truth; the sequencer gives each question its own
    /// presentation cycle (SwiftUI ignores presented-data swaps on a
    /// live alert, and its dismissal write must never land on the next
    /// question).
    @State private var confirmationAlerts = ConfirmationAlertSequencer()

    var body: some View {
        VStack(spacing: 0) {
            transcriptArea
            banners
            approvalDock
            formsDock
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingFiles = true
                } label: {
                    Label("Files", systemImage: "folder")
                }
                .accessibilityIdentifier("S13.files")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingChanges = true
                } label: {
                    Label("Changes", systemImage: "arrow.left.arrow.right")
                }
                .accessibilityIdentifier("S15.changes")
            }
        }
        .sheet(isPresented: $showingSelection) {
            // State and environment are injected HERE — `.environment`
            // on the presenter does not reach into the sheet.
            NavigationStack {
                ModelAgentPickerView(
                    host: host, session: session, selection: selection,
                    sessions: sessions, conversation: conversation
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
        .sheet(isPresented: $showingApproval) {
            // State is injected inside the sheet closure — the
            // presenter's environment does not reach sheets.
            ApprovalSheetView(host: host, session: session, approvals: approvals)
        }
        .sheet(isPresented: $showingForm) {
            // State is injected inside the sheet closure — the
            // presenter's environment does not reach sheets.
            FormSheetView(host: host, forms: forms)
        }
        .sheet(isPresented: $showingTray) {
            // State is injected inside the sheet closure — the
            // presenter's environment does not reach sheets.
            AttachmentTrayView(
                attachments: attachments, host: host, inputCapabilities: inputCapabilities
            )
        }
        .sheet(isPresented: $showingFiles) {
            // State is injected inside the sheet closure — the
            // presenter's environment does not reach sheets. The viewer
            // starts at the session's workspace location and hands the
            // existing draft a remote `file:` reference on Attach.
            if let directory = session.location?.directory {
                FileViewerView(
                    host: host,
                    credential: library.credential(for: host.id),
                    startDirectory: directory
                ) { hostAbsolutePath in
                    attachments.addHostReference(
                        hostAbsolutePath: hostAbsolutePath,
                        name: (hostAbsolutePath as NSString).lastPathComponent
                    )
                    showingFiles = false
                }
            } else {
                ContentUnavailableView(
                    "No Workspace Location",
                    systemImage: "questionmark.folder",
                    description: Text("This session has no workspace directory, so its files cannot be browsed.")
                )
            }
        }
        .sheet(isPresented: $showingChanges) {
            // State and environment are injected HERE — `.environment`
            // on the presenter does not reach into the sheet. The
            // session-turn scope needs no directory; the workspace scope
            // degrades honestly when the session has none.
            NavigationStack {
                ChangesView(
                    host: host,
                    credential: library.credential(for: host.id),
                    sessionID: session.id,
                    directory: session.location?.directory,
                    conversation: conversation
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingChanges = false }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPickerView { image in
                attachments.addCameraImage(image, host: host)
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            attachments.addPhotos(items, host: host)
            photoSelection = []
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                attachments.addFiles(urls, host: host)
            }
        }
        .alert(
            confirmationAlerts.presented?.name ?? "Attachment",
            isPresented: Binding(
                get: { confirmationAlerts.presented != nil },
                // The dismissal write is the sequencer's signal: it
                // clears the on-screen copy and schedules the next
                // question only after the dismissal settles. The buttons
                // never touch presentation state, so this write can
                // neither race the accept button nor land on the next
                // confirmation.
                set: { presented in
                    if !presented { confirmationAlerts.alertDismissed() }
                }
            ),
            presenting: confirmationAlerts.presented
        ) { confirmation in
            Button("Attach Anyway") {
                attachments.answerConfirmation(confirmation, accepted: true, host: host)
            }
            .accessibilityIdentifier("S09.confirm.accept")
            Button("Cancel", role: .cancel) {
                attachments.answerConfirmation(confirmation, accepted: false, host: host)
            }
            .accessibilityIdentifier("S09.confirm.cancel")
        } message: { confirmation in
            switch confirmation.kind {
            case .oversized(let byteCount):
                Text("\(confirmation.name) is \(byteCount.formatted(.byteCount(style: .file))) — over the \(AttachmentRouter.warningThresholdBytes.formatted(.byteCount(style: .file))) warning threshold. This is not a hard limit; the host may still accept it.")
            case .duplicate:
                Text("\(confirmation.name) is already attached with the same size.")
            }
        }
        .onChange(of: attachments.pendingConfirmation) { _, _ in
            confirmationAlerts.queueMayHaveAdvanced()
        }
        .onAppear {
            // Capture only the library (weakly) — capturing the view
            // value would pull the sequencer's own State storage into
            // nextHead: sequencer → closure → view State → sequencer.
            let attachments = attachments
            confirmationAlerts.nextHead = { [weak attachments] in
                attachments?.pendingConfirmation
            }
            confirmationAlerts.queueMayHaveAdvanced()
        }
        .refreshable {
            await conversation.refresh(host: host, sessionID: session.id)
            await loadApprovals()
            await loadForms()
        }
        .task {
            conversation.attach(hosts: library)
            selection.attach(hosts: library)
            attachments.attach(hosts: library)
            approvals.attach(hosts: library)
            forms.attach(hosts: library)
            await openTranscript()
            await loadApprovals()
            await loadForms()
        }
        .onDisappear {
            // A dismissed conversation stops watching — its dock and
            // attribution are gone; nothing polls on its behalf. The
            // CAMERA COVER hides this view without dismissing it
            // (fullScreenCover takes the presenter out of the hierarchy
            // and fires onDisappear): stopping then would kill the
            // bounded post-send watch mid-window, and the load that
            // runs on return never restarts it — an approval or form
            // created afterwards would never reach the dock. It is the
            // only cover in this view; the sheets leave the presenter
            // in the hierarchy.
            guard !showingCamera else { return }
            approvals.stopPostSendWatch()
            forms.stopPostSendWatch()
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

    /// S11 dock (W09): pending approvals above the composer, with a
    /// count when several exist and the owner session ID on linked
    /// child entries. Opens the detail sheet — never answers anything
    /// by itself.
    @ViewBuilder private var approvalDock: some View {
        if approvals.hasPending {
            Button {
                showingApproval = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(approvals.pendingCount > 1
                            ? "\(approvals.pendingCount) approvals waiting"
                            : "Approval needed")
                            .font(.subheadline.weight(.semibold))
                        if let first = approvals.entries.first, first.isLinked {
                            Text("Child session \(first.request.sessionID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .accessibilityIdentifier("S11.dock")
        }
    }

    /// Refresh-driven approval reconciliation (no live SSE yet): the
    /// sessions inventory contributes child attribution when it knows
    /// the descendants — otherwise only the session's own entries show.
    /// Loading also RECORDS the watch context (no polling starts): a
    /// conversation opened onto a pre-existing approval must reopen the
    /// watch on answer too — the released turn's next request has the
    /// same admission-late timing as a sent prompt's (review R3).
    private func loadApprovals() async {
        let childSessionIDs = sessions?.descendantSessionIDs(of: session.id, on: host.id) ?? []
        approvals.recordWatchContext(host: host, sessionID: session.id, childSessionIDs: childSessionIDs)
        await approvals.load(host: host, sessionID: session.id, childSessionIDs: childSessionIDs)
    }

    /// The post-send watch (review R2): polls the dock on the bounded
    /// cadence until the request appears, the window closes, or the
    /// view goes away — the same attribution as a refresh, re-read
    /// once at watch start.
    private func startApprovalWatch() {
        approvals.startPostSendWatch(
            host: host,
            sessionID: session.id,
            childSessionIDs: sessions?.descendantSessionIDs(of: session.id, on: host.id) ?? []
        )
    }

    /// S12 dock (W10): pending questions above the composer, with a
    /// count when several exist and the owner session ID on linked
    /// child entries. Opens the detail sheet — never answers anything
    /// by itself.
    @ViewBuilder private var formsDock: some View {
        if forms.hasPending {
            Button {
                showingForm = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(forms.pendingCount > 1
                            ? "\(forms.pendingCount) questions waiting"
                            : "Question waiting")
                            .font(.subheadline.weight(.semibold))
                        if let first = forms.entries.first, first.isLinked {
                            Text("Child session \(first.ownerSessionID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .accessibilityIdentifier("S12.dock")
        }
    }

    /// Refresh-driven question reconciliation, mirroring approvals: the
    /// sessions inventory contributes child attribution when it knows
    /// the descendants. Loading also RECORDS the watch context (no
    /// polling starts) so an answer re-opens the window the same way a
    /// sent prompt does.
    private func loadForms() async {
        let childSessionIDs = sessions?.descendantSessionIDs(of: session.id, on: host.id) ?? []
        forms.recordWatchContext(host: host, sessionID: session.id, childSessionIDs: childSessionIDs)
        await forms.load(host: host, sessionID: session.id, childSessionIDs: childSessionIDs)
    }

    /// The post-send question watch: the host raises a form mid-turn —
    /// after `send` has already returned on durable admission — so the
    /// dock polls on the bounded cadence until the question appears or
    /// the window closes (live events replace this with W16).
    private func startFormWatch() {
        forms.startPostSendWatch(
            host: host,
            sessionID: session.id,
            childSessionIDs: sessions?.descendantSessionIDs(of: session.id, on: host.id) ?? []
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.drafts.isEmpty {
                chips
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker(selection: $photoSelection, maxSelectionCount: 5, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle.angled")
                    }
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Camera", systemImage: "camera")
                        }
                    }
                    if !attachments.drafts.isEmpty {
                        Button {
                            showingTray = true
                        } label: {
                            Label("Attachments", systemImage: "paperclip.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title)
                }
                .accessibilityIdentifier("S09.attach.open")
                TextField("Message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("S08.composer.field")
                Button {
                    Task {
                        let text = draft
                        let files = attachments.readyAttachments()
                        let sentIDs = attachments.drafts.compactMap { item -> UUID? in
                            if case .ready = item.state { return item.id }
                            return nil
                        }
                        // The draft is cleared ONLY when admission is durable
                        // (directly or reconciled) AND the field still holds
                        // what was sent — text typed DURING the send is kept.
                        // Sent attachments leave the tray; failed references
                        // stay put.
                        if await conversation.send(
                            host: host, sessionID: session.id, text: text,
                            files: files.isEmpty ? nil : files
                        ) {
                            if draft == text { draft = "" }
                            attachments.consume(sentIDs)
                            // `send` returns on durable ADMISSION — the
                            // host creates the permission request only
                            // when the agent reaches the guarded tool,
                            // AFTER this returns (and the empty/error
                            // transcript states offer no pull). The watch
                            // must START first: it snapshots the entries on
                            // the dock as its baseline, and the refresh may
                            // already surface the request (the fast case) —
                            // refresh-first would fold that request into the
                            // baseline, it would never look "new", and the
                            // watch would poll its full window (30 ticks
                            // each for approvals and forms) for a dock that
                            // already shows it. recordWatchContext in the
                            // loads re-records the same context without
                            // touching the task. WATCH still covers the
                            // request that does not exist yet (review R2;
                            // live events replace this with W16).
                            startApprovalWatch()
                            startFormWatch()
                            await loadApprovals()
                            await loadForms()
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
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || conversation.isSending
                        // Send waits for pending attachments rather than
                        // sending a partial draft.
                        || attachments.hasPending
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
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Attachment chips beside the draft (S08/S09): name plus honest
    /// per-item state; tapping opens the tray.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments.drafts) { item in
                    Button {
                        showingTray = true
                    } label: {
                        HStack(spacing: 6) {
                            chipStateIcon(item)
                            Text(item.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.footnote)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("S09.chip")
                }
            }
        }
    }

    @ViewBuilder
    private func chipStateIcon(_ draft: AttachmentLibrary.Draft) -> some View {
        switch draft.state {
        case .preparing:
            ProgressView()
        case .uploading:
            ProgressView()
        case .ready:
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    /// The selected model's input capabilities — drives the honest
    /// "can't read directly" labels; nil while the selection is unknown.
    /// The user's claimed selection wins over the session's recorded model
    /// (the record only lands after the host acknowledges a switch), and
    /// model IDs are not unique across providers — match the full ref.
    private var inputCapabilities: Set<String>? {
        guard let modelRef = selection.selectedRef ?? session.model,
              let model = selection.models.first(where: {
                  $0.id == modelRef.id && $0.providerID == modelRef.providerID
              })
        else { return nil }
        return Set(model.capabilities.input)
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
    /// without executing anything; only web links stay tappable
    /// (`MarkdownRendering`).
    private func markdown(_ text: String) -> Text {
        if let attributed = MarkdownRendering.attributed(text) {
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
            return "Context compaction"
        case .move(_, _, let directory):
            return "Move to \(directory ?? "another location")"
        case .unknown(let type, _):
            // A wire type this baseline doesn't model: shown as pending, never
            // claimed as a known kind (SessionMessage's `.unknown` rule).
            return "Pending \(type)"
        }
    }
}
