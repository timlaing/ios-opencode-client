import SwiftUI
import OpenCodeDomain
import OpenCodeStorage
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
/// toolbar. W16 streams `/api/event` live: text/reasoning deltas
/// render as a tail row, execution/status events drive the retry
/// indicator, and every other on-screen fact reconciles through its
/// authoritative read.
struct ConversationView: View {
    let host: OpenCodeDomain.Host
    let session: Session
    var sessions: SessionsLibrary?

    @Environment(HostLibrary.self) private var library
    /// Appearance ▸ Spacing (W17 S18): compact tightens the transcript
    /// rhythm; comfortable leaves the system spacing untouched.
    @Environment(SettingsLibrary.self) private var settings
    /// W16 S17: banners are posted only while the app is NOT active —
    /// the scenePhase observer below keeps the notifier's gate fresh.
    @Environment(\.scenePhase) private var scenePhase
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
    /// W17 draft persistence: the durable handle for this
    /// conversation, opened when the subscription starts.
    @State private var composerDrafts: ComposerDraftStore?
    @State private var draftSaveTask: Task<Void, Never>?
    /// The text last known to be PERSISTED — a value that merely
    // re-states it (a restore, the admission clear) schedules no
    /// save, so the retention clock's "last edit" only moves when
    /// the user actually edits (review W17 r1).
    @State private var lastPersistedDraft: String?
    /// The last COMPLETED restore for this conversation — the expiry
    /// caption shows only while the composer still holds exactly that
    /// text (any edit or send hides it; follow-on 4a).
    @State private var restoredDraft: ComposerDraftStore.RestoredDraft?
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
    /// W14/W15 Integrations inspector (S16): effective plugin
    /// inventory and the runtime MCP segment over the session's
    /// location; opens from the trailing toolbar button.
    @State private var showingIntegrations = false
    @State private var integrations = IntegrationsLibrary()
    /// W16 live events (S08): per-host `/api/event` subscription while
    /// this conversation is on screen; the reconciler maps events to
    /// the on-screen reads (docs/api-contract.md W16).
    @State private var events = EventLibrary()
    @State private var reconciler: EventReconciler?
    /// W16 S17 initial local notifications: execution terminal events
    /// banner only when the app is not active, deduplicated by the
    /// server's event id.
    @State private var notifier = ExecutionNotifier()
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingIntegrations = true
                } label: {
                    Label("Integrations", systemImage: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("S16.integrations")
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
                ContextPanelView(conversation: conversation, host: host, session: session, selection: selection)
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
        .sheet(isPresented: $showingIntegrations) {
            NavigationStack {
                IntegrationsView(
                    host: host,
                    sessionDirectory: session.location?.directory,
                    library: integrations
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingIntegrations = false }
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
            integrations.attach(hosts: library)
            events.attach(hosts: library)
            // W17 drafts: open the durable store and restore any
            // text that survived a crash or relaunch (expiry is
            // applied on sight) BEFORE the loads — a keystroke
            // during a load would otherwise schedule a save that
            // overwrites the persisted text the restore never got
            // to (review W17 r1).
            composerDrafts = (try? DraftStore(writingAt: StorageLibrary.defaultDraftsDirectory))
                .map(ComposerDraftStore.init(drafts:))
            if draft.isEmpty,
               let restored = composerDrafts?.restore(
                   hostUUID: host.id.rawValue,
                   sessionID: session.id,
                   settings: settings
               ) {
                lastPersistedDraft = restored.text
                draft = restored.text
                restoredDraft = restored
            }
            await openTranscript()
            await loadApprovals()
            await loadForms()
            notifier.sceneActive = (scenePhase == .active)
            // Cancellation is cooperative: the awaits above complete
            // even after the view disappeared (the OS consent prompt is
            // not cancellation-aware). Never start a subscription the
            // dismiss already stopped (onDisappear ran events.stop() —
            // a loop started afterwards would own nothing).
            guard !Task.isCancelled else { return }
            await startEventStream()
        }
        .onChange(of: scenePhase) { _, phase in
            // The notifier reads this gate at delivery time — a
            // terminal event that arrives while the app is active is
            // watched live, not bannered.
            notifier.sceneActive = (phase == .active)
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
            // W16: the event stream stops with its conversation, and a
            // pending debounced refresh is dropped — a dismissed view
            // schedules no further reads (the .task re-runs on return
            // and re-subscribes).
            events.stop()
            reconciler?.flush()
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
            if case .repairRequired(let message) = events.phase {
                // A stopped subscription is SILENT otherwise: live
                // updates are over until the host is re-paired, and
                // the docs promise this state surfaces (review W16
                // r7).
                Label(message, systemImage: "key.slash")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("S08.banner.repairRequired")
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

    /// Refresh-driven approval reconciliation (W16 events reload it
    /// live too): the sessions inventory contributes child attribution
    /// when it knows the descendants — otherwise only the session's
    /// own entries show.
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
    /// the window closes. W16 events (`form.created`) reload the same
    /// dock immediately; the bounded watch stays as the fallback that
    /// needs no stream.
    private func startFormWatch() {
        forms.startPostSendWatch(
            host: host,
            sessionID: session.id,
            childSessionIDs: sessions?.descendantSessionIDs(of: session.id, on: host.id) ?? []
        )
    }

    /// W16: subscribes this host's `/api/event` stream and reconciles
    /// the ON-SCREEN state from it (docs/api-contract.md W16). The
    /// closures capture the LIBRARIES (class references) and the
    /// host/session VALUES — never the view value itself: capturing
    /// `self` would cycle this view's State storage → reconciler →
    /// closure → State (the exact cycle the onAppear sequencer note
    /// warns about).
    private func startEventStream() async {
        let conversation = self.conversation
        let approvals = self.approvals
        let forms = self.forms
        let integrations = self.integrations
        let sessions = self.sessions
        let host = self.host
        let hostLibrary = self.library
        let activeService = SessionHistoryService(makeTransport: { URLSessionTransport(baseURL: $0) })
        // Stored closures capture the LIBRARY reference and plain
        // values — never the view struct itself (nextHead lesson): the
        // reconciler lives in @State, so capturing self would chain
        // State → reconciler → captured view value → State.
        let notifier = self.notifier
        // Stored closures capture REFERENCES (nextHead lesson): the
        // banner's delivery policy is read from settings at the
        // MOMENT a terminal arrives — never snapshotted when the
        // subscription starts (review W17 r1).
        let settings = self.settings
        // S20 (W17): banner posts and the lazy permission outcome
        // join the redacted diagnostic log.
        notifier.diagnostics = DiagnosticsLogStore()
        let sessionTitle = session.title
        let sessionID = session.id
        let directory = session.location?.directory
        // Consent is asked IN PARALLEL, never in the stream's way
        // (review W16 r7): on the first conversation open the OS
        // alert would otherwise block every delta, dock event and
        // execution status until it is answered. handleTerminal
        // awaits the same single-flight ask if a terminal arrives
        // first (ExecutionNotifier.prepare), so nothing is lost.
        Task { await notifier.prepare() }
        // The subscription must not start for a screen whose
        // onDisappear already stopped it (review W16 r1) — a loop
        // started now would reconnect forever with no owner.
        guard !Task.isCancelled else { return }

        let reconciler = EventReconciler(conversation: conversation, sessionID: sessionID)
        reconciler.refreshTranscript = {
            await conversation.refresh(host: host, sessionID: sessionID)
        }
        reconciler.loadInbox = {
            await conversation.loadInbox(host: host, sessionID: sessionID)
        }
        reconciler.loadUsage = {
            await conversation.loadUsage(host: host, sessionID: sessionID)
        }
        reconciler.loadContext = {
            await conversation.loadContext(host: host, sessionID: sessionID)
        }
        reconciler.loadApprovals = {
            // Same attribution as the view's own loads (child
            // sessions from the sessions inventory).
            let children = sessions?.descendantSessionIDs(of: sessionID, on: host.id) ?? []
            approvals.recordWatchContext(host: host, sessionID: sessionID, childSessionIDs: children)
            await approvals.load(host: host, sessionID: sessionID, childSessionIDs: children)
        }
        reconciler.loadForms = {
            let children = sessions?.descendantSessionIDs(of: sessionID, on: host.id) ?? []
            forms.recordWatchContext(host: host, sessionID: sessionID, childSessionIDs: children)
            await forms.load(host: host, sessionID: sessionID, childSessionIDs: children)
        }
        reconciler.descendantSessionIDs = {
            // Same live attribution as both dock closures above — a
            // descendant's permission/form event may reload them
            // (review W16 r5); every other family never asks.
            sessions?.descendantSessionIDs(of: sessionID, on: host.id) ?? []
        }
        reconciler.reloadIntegrations = {
            // A config.updated refreshes the inventory ONLY if this
            // screen has actually loaded one — never a first fetch for
            // a sheet that was never opened.
            guard integrations.isLoaded else { return }
            await integrations.load(host: host, sessionDirectory: directory)
        }
        events.onEvent = { event in
            await reconciler.handle(event)
        }
        reconciler.onExecutionTerminal = { event in
            // Only this conversation's live terminal events reach the
            // notifier; it applies the active/dedup/consent gates.
            // NEVER awaited on the serial event path (review W16 r9):
            // handleTerminal can await the in-flight consent ask, and
            // while the OS alert is up sceneActive is false — awaiting
            // it here would stall every delta, dock event and refresh
            // behind the user's answer. Event ids are unique (no
            // replay), so the dedup stays correct off-path.
            Task {
                await notifier.handleTerminal(
                    event,
                    sessionTitle: sessionTitle,
                    policy: NotificationDeliveryPolicy(
                        contentPrivacy: settings.state.notificationContentPrivacy,
                        categories: settings.state.notificationCategories
                    )
                )
            }
        }
        reconciler.readActiveSessions = { [weak hostLibrary] in
            // Reconnect reconciliation of the working indicator (review
            // W16 r1): the active-session inventory is the authority
            // for "is this turn still running" — the stream has no
            // replay, so a terminal missed while down left it stale.
            guard let hostLibrary,
                  let credential = hostLibrary.credential(for: host.id) else {
                throw TransportError.connectionFailed("No credential for this host.")
            }
            return try await activeService.activeSessions(at: host.address, credential: credential)
        }
        self.reconciler = reconciler
        events.watch(host: host)
    }

    /// W16 retry footnote copy: names the attempt when the host
    /// reports one, and carries its message verbatim when present.
    private func retryLabel(attempt: Int?, message: String?) -> String {
        var label = "The host is retrying"
        if let attempt {
            label += " (attempt \(attempt))"
        }
        if let message, !message.isEmpty {
            label += " — \(message)"
        }
        return label + "…"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // W16 retry indicator (docs/api-contract.md W16): the
            // canonical working state from session.status events — a
            // transport disconnect never shows completion here.
            if case .retry(let attempt, let message) = conversation.executionStatus {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                    Text(retryLabel(attempt: attempt, message: message))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("S08.status.retry")
            }
            if !attachments.drafts.isEmpty {
                chips
            }
            if let restored = restoredDraft,
               draft == restored.text,
               !draft.isEmpty,
               let expiry = settings.draftExpiry(lastEdit: restored.lastEdit) {
                // The display half of the drafts retention spec ("show
                // expiry date when enabled"): sits beside the restored
                // text until it is edited or sent, and never appears
                // under until-discarded — nil expiry, no caption, no
                // promised display (follow-on 4a).
                Text("Draft restored — expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("S08.composer.draftExpiry")
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
                            if draft == text {
                                // The field now states exactly what is
                                // persisted-and-sent: record that FIRST so
                                // the onChange below cancels any pending
                                // keystroke write and schedules nothing (a
                                // stale write would resurrect the sent text,
                                // a re-save would reset its retention
                                // clock — review W17 r1).
                                lastPersistedDraft = ""
                                draft = ""
                                // Durable admission also deletes the
                                // persisted draft at once — the debounced
                                // path below would leave a sent text
                                // restorable for its 300 ms window.
                                composerDrafts?.save(
                                    "", hostUUID: host.id.rawValue, sessionID: session.id
                                )
                            }
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
                            // W16 events reload the same docks, and the
                            // bounded watch is the no-stream fallback).
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
        // W17 drafts: keystrokes coalesce into one durable write per
        // ~300 ms of quiet; an emptied field (sent, discarded) takes
        // the same path and deletes the record. Cancel FIRST — a
        // pending write must never outlive the value it wrote — and
        // re-stating what is already persisted schedules nothing: a
        // re-save would move the retention clock's "last edit" for a
        // draft nobody edited (review W17 r1).
        .onChange(of: draft) { _, newValue in
            // The expiry caption belongs to the RESTORED text only: any
            // divergence clears it permanently, so a later revert cannot
            // re-show an expiry derived from the pre-edit timestamp (the
            // save path writes a newer updatedAt; review follow-on r1).
            if let restored = restoredDraft, newValue != restored.text {
                restoredDraft = nil
            }
            draftSaveTask?.cancel()
            guard newValue != lastPersistedDraft else { return }
            let hostUUID = host.id.rawValue
            let sessionID = session.id
            draftSaveTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                composerDrafts?.save(newValue, hostUUID: hostUUID, sessionID: sessionID)
                lastPersistedDraft = newValue
            }
        }
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
            // W16 live tail (docs/api-contract.md W16): in-flight
            // assistant text/reasoning straight from the event stream.
            // A row lives here ONLY while the list has not caught up
            // at all — once the host returns the in-progress row, the
            // row renders the overlay IN PLACE of its text/reasoning
            // (review W16 r1: the text is never shown twice, and tool
            // cards from the mid-turn row keep rendering).
            let unlistedStreaming = conversation.streaming.keys.filter { key in
                !conversation.messages.contains { $0.id == key }
            }.sorted()
            if !unlistedStreaming.isEmpty {
                Section {
                    ForEach(unlistedStreaming, id: \.self) { key in
                        streamingRow(conversation.streaming[key], id: key)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Appearance ▸ Spacing (W17 S18): compact tightens the message
        // rhythm; comfortable keeps the system default spacing.
        .listRowSpacing(settings.state.spacing == .compact ? 2 : nil)
    }

    // MARK: - Message rendering

    /// One part's rendering — shared by the tail row (the list has
    /// not caught up at all) and the in-place substitution inside an
    /// assistant row.
    @ViewBuilder
    private func livePartView(_ content: String, isReasoning: Bool) -> some View {
        if isReasoning {
            Text(content)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .italic()
        } else {
            markdown(content)
        }
    }

    /// The tail row's full overlay: reasoning (dimmed) above text, in
    /// ordinal order — parts are independent (review W16 r2), so a
    /// later part never merges into an earlier one's text.
    @ViewBuilder
    private func streamingContent(_ entry: ConversationLibrary.StreamingMessage) -> some View {
        let reasoning = entry.reasoning.sorted { $0.key < $1.key }
            .map(\.value.content).filter { !$0.isEmpty }
        let text = entry.text.sorted { $0.key < $1.key }
            .map(\.value.content).filter { !$0.isEmpty }
        if !reasoning.isEmpty {
            livePartView(reasoning.joined(separator: "\n\n"), isReasoning: true)
        }
        if !text.isEmpty {
            livePartView(text.joined(separator: "\n\n"), isReasoning: false)
        }
    }

    /// W16 live tail row: the assistant's in-flight reasoning and text
    /// as the deltas arrive. Reasoning renders dimmed above the text
    /// (the same thinking treatment as the transcript); an entry with
    /// no content yet is the "responding" placeholder before the first
    /// delta.
    @ViewBuilder
    private func streamingRow(_ entry: ConversationLibrary.StreamingMessage?, id: String) -> some View {
        if let entry {
            let hasContent = entry.text.values.contains { !$0.content.isEmpty }
                || entry.reasoning.values.contains { !$0.content.isEmpty }
            VStack(alignment: .leading, spacing: 6) {
                streamingContent(entry)
                if !hasContent {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Responding…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .accessibilityIdentifier("S08.streaming.\(id)")
        }
    }

    /// The overlay entry for a row while it exists — settled or not:
    /// the `ended` full value is the truth and a row's stale mid-turn
    /// copy must not resurrect over it (or cover for a row that lacks
    /// the part yet). No duplication risk: parts render IN PLACE of
    /// same-index items (never alongside them), trailing parts only
    /// fill items the row does not contain, and
    /// pruneDeliveredStreaming retires the whole entry once every
    /// part settled AND the transcript carries the row (review W16
    /// r3).
    private func liveOverlay(for messageID: String) -> ConversationLibrary.StreamingMessage? {
        conversation.streaming[messageID]
    }

    /// A row's content items with text and reasoning parts numbered
    /// independently 0,1,2… — and that is EXACTLY the host's ordinal
    /// space (review W16 r11): the pinned source numbers ordinals
    /// PER KIND — one `fragments` counter per kind per assistant
    /// message, parts sequential within a kind
    /// (b44eea9e `packages/core/src/session/runner/publish-llm-event.ts`,
    /// `let nextOrdinal = 0` inside each `fragments` instance) — so
    /// a text part's ordinal IS its index among the row's text
    /// items, and tool parts never shift it. A message's content can
    /// interleave text and tools, so each part renders in its own
    /// position, never combined (review W16 r2).
    private struct PositionedItem {
        var item: SessionMessage.ContentItem
        var textIndex: Int?
        var reasoningIndex: Int?
    }

    private func positioned(_ content: [SessionMessage.ContentItem]) -> [PositionedItem] {
        var text = 0
        var reasoning = 0
        return content.map { item in
            switch item.type {
            case "text":
                defer { text += 1 }
                return PositionedItem(item: item, textIndex: text, reasoningIndex: nil)
            case "reasoning":
                defer { reasoning += 1 }
                return PositionedItem(item: item, textIndex: nil, reasoningIndex: reasoning)
            default:
                return PositionedItem(item: item, textIndex: nil, reasoningIndex: nil)
            }
        }
    }

    /// The streamed part a row item renders INSTEAD of its own
    /// content: the overlay's part at the item's index within its
    /// kind. An empty part does not supersede (there is nothing to
    /// show), and tool/unknown items are never superseded. Settled
    /// parts DO supersede: the ended full value outranks the row's
    /// mid-turn copy until the entry is pruned (review W16 r3).
    private func livePartReplacement(
        _ position: PositionedItem,
        live: ConversationLibrary.StreamingMessage?
    ) -> String? {
        guard let live else { return nil }
        if let textIndex = position.textIndex,
           let segment = live.text[textIndex],
           !segment.content.isEmpty {
            return segment.content
        }
        if let reasoningIndex = position.reasoningIndex,
           let segment = live.reasoning[reasoningIndex],
           !segment.content.isEmpty {
            return segment.content
        }
        return nil
    }

    /// Parts the row has not caught up with at all (indexes past the
    /// row's items of that kind, including ones already settled while
    /// no list read has landed) — rendered after the row's content,
    /// in ordinal order.
    @ViewBuilder
    private func trailingLiveParts(
        _ entry: ConversationLibrary.StreamingMessage,
        textCount: Int,
        reasoningCount: Int
    ) -> some View {
        let trailingReasoning = entry.reasoning
            .filter { $0.key >= reasoningCount }
            .sorted { $0.key < $1.key }
            .map(\.value.content)
            .filter { !$0.isEmpty }
        let trailingText = entry.text
            .filter { $0.key >= textCount }
            .sorted { $0.key < $1.key }
            .map(\.value.content)
            .filter { !$0.isEmpty }
        ForEach(Array(trailingReasoning.enumerated()), id: \.offset) { _, part in
            livePartView(part, isReasoning: true)
        }
        ForEach(Array(trailingText.enumerated()), id: \.offset) { _, part in
            livePartView(part, isReasoning: false)
        }
    }

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
            // W16: while this message still has an overlay entry, the
            // row's items may be the host's stale mid-turn snapshot —
            // the streamed parts render IN PLACE of the row's
            // same-index items (review W16 r1: never both) at the
            // item's OWN position, so the text/tool interleaving is
            // kept (review W16 r2); tool and unknown items always stay
            // authoritative from the list.
            let live = liveOverlay(for: message.id)
            let positions = positioned(content)
            VStack(alignment: .leading, spacing: 6) {
                Text([agent, model.map { "\($0.providerID)/\($0.id)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(positions.enumerated()), id: \.offset) { _, position in
                    if let replacement = livePartReplacement(position, live: live) {
                        livePartView(replacement, isReasoning: position.reasoningIndex != nil)
                    } else {
                        contentItemView(position.item)
                    }
                }
                if let live {
                    trailingLiveParts(
                        live,
                        textCount: content.filter { $0.type == "text" }.count,
                        reasoningCount: content.filter { $0.type == "reasoning" }.count
                    )
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
/// S14 usage/context inspector (W13, docs/navigation-screens.md S14):
/// last-REPORTED step usage from message tokens plus the selected
/// model's context limit, session-cumulative cost/tokens from
/// `session.get`, and compaction state with the manual Compact action.
///
/// Honesty rules (docs/api-contract.md W13): costs are labelled
/// estimated, an absent limit shows "Unknown", token categories the
/// host did not report show "Not reported", and context utilisation is
/// NEVER fabricated between reports — every figure here is one the host
/// sent.
struct ContextPanelView: View {
    let conversation: ConversationLibrary
    let host: OpenCodeDomain.Host
    let session: Session
    let selection: SelectionLibrary

    /// The freshest cumulative info the library holds (from
    /// `session.get`); the passed-in snapshot is also host-reported —
    /// just older, from the sessions list.
    private var usage: Session { conversation.usageInfo ?? session }

    /// The last STEP's reported tokens: the newest message carrying any
    /// — assistant steps and completed compactions both report tokens.
    /// Never extrapolated between reports.
    private var lastReportedStep: (rawType: String, tokens: Session.TokenUsage)? {
        for message in conversation.messages.reversed() {
            if let tokens = message.tokens { return (message.rawType, tokens) }
        }
        return nil
    }

    /// The selected model's context limit, resolved through the host's
    /// inventory; unknown when no matching model is loaded — never
    /// guessed.
    private var contextLimit: Int? {
        let ref = selection.selectedRef ?? usage.model
        guard let ref else { return nil }
        return selection.models
            .first { $0.id == ref.id && $0.providerID == ref.providerID }?
            .limit.context
    }

    /// The newest compaction transition in the transcript, if any.
    private var lastCompaction: SessionMessage.Kind? {
        conversation.messages.reversed().first {
            if case .compaction = $0.kind { return true }
            return false
        }?.kind
    }

    /// A compaction the host ADMITTED but has not yet delivered as a
    /// transcript transition — admission is not completion.
    private var pendingCompactionAdmission: Bool {
        conversation.inboxItems.contains {
            if case .compaction = $0.kind { return true }
            return false
        }
    }

    private var modelLabel: String? {
        guard let ref = usage.model else { return nil }
        if let variant = ref.variant { return "\(ref.providerID)/\(ref.id) (\(variant))" }
        return "\(ref.providerID)/\(ref.id)"
    }

    private func tokenRows(_ tokens: Session.TokenUsage) -> some View {
        Group {
            LabeledContent("Input", value: Self.count(tokens.input))
            LabeledContent("Output", value: Self.count(tokens.output))
            LabeledContent("Reasoning", value: Self.count(tokens.reasoning))
            LabeledContent("Cache Read", value: Self.count(tokens.cache?.read))
            LabeledContent("Cache Write", value: Self.count(tokens.cache?.write))
        }
    }

    private static func count(_ value: Int?) -> String {
        guard let value else { return "Not reported" }
        return value.formatted()
    }

    private var countsByType: [(type: String, count: Int)] {
        Dictionary(grouping: conversation.activeContext, by: \.rawType)
            .map { (type: $0.key, count: $0.value.count) }
            .sorted { $0.type < $1.type }
    }

    var body: some View {
        List {
            if conversation.isLoadingContext || conversation.isLoadingUsage {
                Section { ProgressView("Loading Context…") }
            }
            if let error = conversation.contextError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            if let error = conversation.usageError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            if let error = conversation.compactionError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            Section {
                if let step = lastReportedStep {
                    tokenRows(step.tokens)
                        .accessibilityIdentifier("S14.usage.step")
                } else {
                    Text("No usage reported yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Last Reported Step")
            } footer: {
                if lastReportedStep != nil {
                    Text("Reported by the newest message carrying usage. Context use between reports is never estimated.")
                }
            }
            Section("Model & Context Limit") {
                LabeledContent("Model", value: modelLabel ?? "Unknown")
                LabeledContent("Context Limit") {
                    if let limit = contextLimit {
                        Text("\(limit.formatted()) tokens")
                    } else {
                        Text("Unknown").foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("S14.usage.limit")
            }
            Section("Cumulative Session") {
                if let cost = usage.cost {
                    LabeledContent("Cost") {
                        Text("Estimated \(cost.formatted(.currency(code: "USD")))")
                    }
                    .accessibilityIdentifier("S14.usage.cost")
                } else {
                    LabeledContent("Cost", value: "Not reported")
                        .accessibilityIdentifier("S14.usage.cost")
                }
                if let tokens = usage.tokens {
                    tokenRows(tokens)
                        .accessibilityIdentifier("S14.usage.tokens")
                } else {
                    LabeledContent("Tokens", value: "Not reported")
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
            Section {
                Button {
                    Task {
                        await conversation.compact(host: host, sessionID: session.id)
                    }
                } label: {
                    if conversation.isCompacting {
                        ProgressView("Requesting…")
                    } else {
                        Label("Compact Context", systemImage: "rectangle.compress.vertical")
                    }
                }
                .disabled(conversation.isCompacting)
                .accessibilityIdentifier("S14.compaction.button")
            } header: {
                Text("Compaction")
            } footer: {
                compactionFooter
            }
        }
        .task {
            await conversation.loadContext(host: host, sessionID: session.id)
            await conversation.loadUsage(host: host, sessionID: session.id)
            if conversation.inboxItems.isEmpty {
                await conversation.loadInbox(host: host, sessionID: session.id)
            }
        }
    }

    @ViewBuilder
    private var compactionFooter: some View {
        if pendingCompactionAdmission {
            Text("Requested — admitted, waiting for the next step boundary.")
        } else if case .compaction(let status, let reason, _, let errorMessage) = lastCompaction {
            switch status {
            case "completed":
                Text("Last compaction completed. The full transcript is preserved.")
            case "running":
                Text("Compaction running — the transcript stays intact.")
            case "failed":
                Text("Last compaction failed\(reason.map { ": \($0)" } ?? "")\(errorMessage.map { " — \($0)" } ?? "").")
            default:
                Text("Last compaction reported status “\(status)”.")
            }
        } else {
            Text("Compacts context at the next step boundary. The full transcript is preserved.")
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
