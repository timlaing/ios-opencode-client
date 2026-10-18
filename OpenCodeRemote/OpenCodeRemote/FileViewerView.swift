import PDFKit
import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S13 Files inspector (docs/navigation-screens.md S13–S16): a read-only
/// browser + preview over the session's workspace. Reuses `FolderNavigation`
/// (the location-relative descend/up semantics) and the W02 fs.list / fs.find
/// calls for the tree and filename search, and reads file bytes with the W11
/// `fs.read`. Filename search and within-file text search are two SEPARATE
/// labelled controls; the file is read-only — no Save/Edit control is exposed,
/// and Attach to Draft hands the existing draft a remote `file:` reference
/// without downloading or re-uploading bytes (docs/api-contract.md W11).
///
/// Preview rendering follows the file-preview defaults
/// (docs/implementation-defaults.md): native text, image, PDF and Markdown
/// previews with no script/HTML execution. Text and Markdown fetch ONE byte
/// range first (1 MiB, `FileViewerLibrary`'s budget) and grow only via Load
/// More; images and PDFs fetch the whole file because a partial media file
/// cannot decode at all. Copy and Share always operate on the COMPLETE file —
/// they transparently fetch the remaining ranges first, so a partial preview
/// is never exported as if it were the whole file.
struct FileViewerView: View {
    let host: OpenCodeDomain.Host
    let credential: BasicCredential?
    /// Absolute directory the inspector starts at (the session's location
    /// directory). Entries are location-relative, exactly as in S05.
    let startDirectory: String
    /// Attach to Draft: called with the host-absolute path so the caller can
    /// build a remote `file:` reference into its EXISTING draft, no send.
    var onAttachToDraft: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var service = ProjectService(makeTransport: { URLSessionTransport(baseURL: $0) })
    @State private var viewer = FileViewerLibrary()

    // Browse state (shared shape with FolderBrowserView).
    @State private var navigation = FolderNavigation()
    @State private var entries: [FileSystemEntry] = []
    @State private var message: String?

    // Filename search (a NAME query over the location, via fs.find).
    @State private var filenameQuery = ""
    @State private var searchResults: [FileSystemEntry]?

    // Within-file text search (over the decoded content, via FileViewerLibrary).
    @State private var textQuery = ""
    @State private var textHits: [FileViewerLibrary.SearchHit] = []

    // The open file, its preview kind, and read state.
    @State private var openFile: FileSystemEntry?
    @State private var openKind: FileViewerLibrary.Kind = .text
    @State private var isLoading = false
    /// Failures of a Load More / Copy / Share follow-up read: shown INLINE so
    /// the preview the user already has is never thrown away by a later error.
    @State private var loadMoreError: String?

    // Markdown mode and image zoom (preview-only affordances).
    @State private var markdownShowsSource = false
    @State private var zoom: CGFloat = 1

    // Line navigation: the scroll proxy for the preview list.
    @State private var scrollProxy: ScrollViewProxy?
    @State private var pendingScrollLine: Int?

    // Share: a temp copy of the COMPLETE file handed to the share sheet.
    @State private var shareItem: ShareItem?

    /// A temp file prepared for the system share sheet (which offers Save to
    /// Files — the "Save" half of S13's progressive Load More/Save).
    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            Group {
                if let message {
                    ContentUnavailableView {
                        Label("File Unavailable", systemImage: "exclamationmark.doc")
                    } description: {
                        Text(message)
                    } actions: {
                        // Either the listing or the preview read failed —
                        // reload() clears the message and re-lists the
                        // directory, returning to the file list.
                        Button("Back to Files") {
                            Task { await reload() }
                        }
                        .accessibilityIdentifier("S13.backToFiles")
                    }
                } else if let openFile {
                    filePreview(openFile)
                } else {
                    entryList
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if openFile != nil {
                    // Back from the preview to the entry list — the browser
                    // navigation stack is untouched, so Up still returns to
                    // the parent folder.
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            openFile = nil
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("S13.back")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            onAttachToDraft(openFilePath)
                        } label: {
                            Label("Attach to Draft", systemImage: "paperclip")
                        }
                        .accessibilityIdentifier("S13.attach")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        fileMenu
                    }
                }
            }
            .searchable(text: $filenameQuery, prompt: "Search file names")
        }
        .task { await reload() }
        .onChange(of: filenameQuery) { _, _ in
            Task { await runFilenameSearch() }
        }
        .onChange(of: textQuery) { _, _ in
            textHits = viewer.search(textQuery)
        }
        // A searched line may sit beyond the current line budget; reveal it
        // first, then scroll once SwiftUI has laid its row out.
        .onChange(of: viewer.renderedLineBudget) { _, _ in
            if let line = pendingScrollLine {
                pendingScrollLine = nil
                DispatchQueue.main.async { [scrollProxy] in
                    scrollProxy?.scrollTo(line, anchor: .top)
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(url: item.url)
        }
    }

    // MARK: - Toolbar actions (Copy / Share operate on the COMPLETE file)

    private var fileMenu: some View {
        Menu {
            if openKind.isRanged {
                Button {
                    Task { await copyLoadedText() }
                } label: {
                    Label("Copy File Text", systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("S13.copy")
            }
            Button {
                Task { await prepareShare() }
            } label: {
                Label("Share File…", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("S13.share")
        } label: {
            Label("File Actions", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Entry list (browse + filename search)

    private var entryList: some View {
        List {
            if navigation.canGoUp {
                Button {
                    Task { await goUp() }
                } label: {
                    Label("Back to \(backTargetName)", systemImage: "arrow.up")
                }
            }
            if let searchResults {
                Section("Filename Matches") {
                    ForEach(searchResults, id: \.path) { entry in
                        row(entry)
                    }
                }
            } else {
                Section {
                    ForEach(entries, id: \.path) { entry in
                        row(entry)
                    }
                } header: {
                    if isLoading { ProgressView() }
                }
            }
        }
        .refreshable { await reload() }
    }

    @ViewBuilder
    private func row(_ entry: FileSystemEntry) -> some View {
        switch entry.type {
        case .directory:
            Button {
                Task { await descend(into: entry.path) }
            } label: {
                Label(entry.path, systemImage: "folder")
            }
        case .file:
            Button {
                Task { await open(entry) }
            } label: {
                Label(entry.path, systemImage: "doc")
            }
        }
    }

    // MARK: - File preview (read-only, kind-aware)

    @ViewBuilder
    private func filePreview(_ entry: FileSystemEntry) -> some View {
        switch openKind {
        case .image:
            imagePreview
        case .pdf:
            pdfPreview
        case .text, .markdown:
            textPreview(entry)
        case .binary:
            binaryPreview
        }
    }

    /// The read-only banner + partial-progress note shared by every kind.
    private var previewBanner: some View {
        Section {
            Label(entryPathLabel, systemImage: "lock.doc")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("S13.readonly")
            if let loadMoreError {
                Label(loadMoreError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("S13.loadmoreerror")
            }
            if let loaded = viewer.totalByteCount, viewer.needsMoreBytes {
                Text("Previewing \(ByteCountFormatter.string(fromByteCount: Int64(viewer.fetchedByteCount), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(loaded), countStyle: .file)). Load More extends it; Share saves the whole file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("S13.progress")
            }
        }
    }

    /// Text and Markdown: monospaced, line-numbered rows with within-file
    /// search and line navigation, grown only by Load More.
    private func textPreview(_ entry: FileSystemEntry) -> some View {
        // The reader must CONTAIN the List it scrolls: scrollTo addresses
        // scroll views inside the reader, so a reader placed inside a
        // Section can never move the enclosing List (S13 line navigation).
        ScrollViewReader { proxy in
            // Captured so searched-line navigation can scroll after the line
            // budget grows to include the target row.
            fileList(for: entry)
                .onAppear { scrollProxy = proxy }
        }
    }

    private func fileList(for entry: FileSystemEntry) -> some View {
        List {
            previewBanner
            if openKind == .markdown {
                Section {
                    Picker("Preview", selection: $markdownShowsSource) {
                        Text("Rendered").tag(false)
                        Text("Source").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("S13.markdownmode")
                }
            }
            // Within-file search is a SOURCE-mode control: its hits address
            // numbered source lines, which a rendered Markdown view does not
            // show — so it appears for text always, and for Markdown only in
            // Source mode (S13: filename and within-file search are separate
            // labelled controls).
            if openKind != .markdown || markdownShowsSource {
                Section("Within-file Search") {
                    TextField("Search this file", text: $textQuery)
                        .accessibilityIdentifier("S13.textsearch")
                    if !textHits.isEmpty {
                        ForEach(textHits) { hit in
                            Button {
                                navigateToLine(hit.line)
                            } label: {
                                Text("\(hit.line): \(hit.text)")
                                    .font(.system(.footnote, design: .monospaced))
                            }
                            .accessibilityIdentifier("S13.hit.\(hit.line)")
                        }
                    } else if !textQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No lines match.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Rendered Markdown shows in Rendered mode; Source mode (and all
            // text files) show the numbered source lines.
            if openKind == .markdown, !markdownShowsSource {
                renderedMarkdownSection
            } else {
                previewLinesSection
            }
        }
        .refreshable { await open(entry, force: true) }
    }

    private var previewLinesSection: some View {
        Section {
            if isLoading, viewer.content == nil {
                ProgressView("Reading…")
            } else {
                ForEach(Array(viewer.visibleLines().enumerated()), id: \.offset) { index, line in
                    lineRow(number: index + 1, text: line)
                }
                if viewer.hasMore {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Label("Load More", systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("S13.loadmore")
                }
                if isLoading {
                    ProgressView()
                }
            }
        }
    }

    private func lineRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(number))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("S13.line.\(number)")
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        }
        .id(number)
    }

    /// Rendered Markdown: the fetched (possibly still partial) text rendered
    /// as Markdown. Never executes embedded HTML/scripts — `AttributedString`
    /// markdown parsing produces text attributes only, and malformed input
    /// falls back to the source text verbatim.
    private var renderedMarkdownSection: some View {
        Section("Rendered") {
            if let text = viewer.content?.text {
                if let rendered = try? AttributedString(
                    markdown: text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(rendered)
                } else {
                    Text(text)
                }
            }
            if viewer.hasMore {
                Button {
                    Task { await loadMore() }
                } label: {
                    Label("Load More", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("S13.loadmore")
            }
        }
    }

    /// Image: the whole file (fetched without a Range) rendered zoomable.
    private var imagePreview: some View {
        List {
            previewBanner
            Section {
                if isLoading, viewer.completeBytes == nil {
                    ProgressView("Reading…")
                } else if let data = viewer.completeBytes, let image = UIImage(data: data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(zoom)
                            .gesture(
                                MagnifyGesture()
                                    .onChanged { value in zoom = max(1, min(value.magnification, 8)) }
                                    .onEnded { value in zoom = max(1, min(value.magnification, 8)) }
                            )
                            .accessibilityIdentifier("S13.preview.image")
                    }
                } else {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "photo",
                        description: Text("The host returned bytes this app cannot render as an image. Share the file to open it elsewhere.")
                    )
                }
            }
        }
        .refreshable { await open(openFile, force: true) }
    }

    /// PDF: the whole file rendered by PDFKit, whose native scrolling gives
    /// page navigation without any custom viewer code.
    private var pdfPreview: some View {
        List {
            previewBanner
            Section {
                if isLoading, viewer.completeBytes == nil {
                    ProgressView("Reading…")
                } else if let data = viewer.completeBytes, PDFDocument(data: data) != nil {
                    PDFKitPreview(data: data)
                        .frame(minHeight: 500)
                        .accessibilityIdentifier("S13.preview.pdf")
                } else {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "doc.richtext",
                        description: Text("The host returned bytes this app cannot render as a PDF. Share the file to open it elsewhere.")
                    )
                }
            }
        }
        .refreshable { await open(openFile, force: true) }
    }

    /// Binary: no inline preview exists (archives, executables, media — the
    /// app renders no bytes for these kinds on purpose). Nothing is fetched
    /// on open; Share pulls the whole file on demand, and Attach hands the
    /// draft a remote `file:` reference without downloading anything.
    private var binaryPreview: some View {
        List {
            previewBanner
            Section {
                ContentUnavailableView(
                    "No Preview",
                    systemImage: "archivebox",
                    description: Text("This file type has no inline preview. Share to open it in another app, or attach a reference to the draft.")
                )
            }
        }
    }

    // MARK: - Browse / read actions

    private func reload() async {
        message = nil
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await service.listDirectory(
                at: host.address,
                credential: credential,
                directory: startDirectory,
                path: navigation.current.isEmpty ? "." : navigation.current
            )
            .sorted { lhs, rhs in
                if lhs.type != rhs.type { return lhs.type == .directory }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }
            searchResults = nil
        } catch {
            message = Self.message(for: error)
        }
    }

    private func descend(into entryPath: String) async {
        navigation.descend(to: entryPath)
        await reload()
    }

    private func goUp() async {
        navigation.goUp()
        await reload()
    }

    private func runFilenameSearch() async {
        let query = filenameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            searchResults = try await service.find(
                at: host.address,
                credential: credential,
                directory: startDirectory,
                query: query,
                limit: 50
            )
        } catch {
            message = Self.message(for: error)
        }
    }

    /// Opens a file. Text and Markdown ask for ONE byte range first (the
    /// 1 MiB preview budget); images and PDFs read the whole file because a
    /// partial media file cannot decode at all (docs/implementation-defaults.md
    /// file-preview rules).
    private func open(_ entry: FileSystemEntry?, force: Bool = false) async {
        guard let entry else { return }
        if !force, openFile == entry { return }
        openFile = entry
        openKind = FileViewerLibrary.kind(forPath: entry.path)
        textQuery = ""
        textHits = []
        message = nil
        loadMoreError = nil
        markdownShowsSource = false
        zoom = 1
        viewer.beginFile(kind: openKind)
        // Binary has no preview at all, so nothing is fetched on open —
        // Share pulls the whole file on demand, Attach needs no bytes.
        guard openKind != .binary else { return }
        isLoading = true
        defer { isLoading = false }
        let range = viewer.initialRange()
        do {
            let file: ProjectService.ReadFile
            do {
                file = try await read(entry, range: range)
            } catch TransportError.http(let status, _) where (status == 416 && range != nil) {
                // The host rejected the computed range outright (file size
                // changed since the listing, or an empty-file edge): retry
                // ONCE with no Range header — a whole-file read cannot be
                // 416 — instead of declaring the file unreadable.
                file = try await read(entry, range: nil)
            }
            viewer.adopt(file)
        } catch {
            openFile = nil
            message = Self.message(for: error)
        }
    }

    /// One Load More press grows BOTH progressive budgets where they have
    /// room (docs/navigation-screens.md S13 — large previews are progressive,
    /// never permanently truncated): the line budget renders more of what is
    /// already fetched, and the next byte range fetches more of the file. A
    /// failed follow-up read is reported INLINE — the preview stays put.
    private func loadMore() async {
        loadMoreError = nil
        if viewer.needsMoreLines {
            viewer.loadMore()
        }
        guard let entry = openFile, let range = viewer.nextRange() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let file = try await read(entry, range: range)
            // A changed entity tag means the host file changed between ranged
            // reads; splicing the slices would fabricate content that never
            // existed, so the preview restarts from byte 0 instead.
            guard viewer.continuesCurrentEntity(file) else {
                await open(entry, force: true)
                return
            }
            viewer.adopt(file)
        } catch {
            loadMoreError = Self.message(for: error)
        }
    }

    /// Line navigation: grow the budget to include the target line (search
    /// only matches already-fetched lines, so its bytes exist). If the budget
    /// had to grow, the row appears on the next layout pass and the scroll
    /// happens via the `renderedLineBudget` onChange; if the line was already
    /// rendered, scroll immediately.
    private func navigateToLine(_ line: Int) {
        let budgetBefore = viewer.renderedLineBudget
        viewer.reveal(line: line)
        if viewer.renderedLineBudget == budgetBefore {
            pendingScrollLine = nil
            DispatchQueue.main.async { [scrollProxy] in
                scrollProxy?.scrollTo(line, anchor: .top)
            }
        } else {
            pendingScrollLine = line
        }
    }

    // MARK: - Copy / Share (COMPLETE file only)

    /// Fetches any missing ranges first so the copy is the whole file, then
    /// puts its text on the pasteboard. A partial preview is never copied as
    /// if it were complete.
    private func copyLoadedText() async {
        guard await fetchWholeFileIfNeeded(), let text = viewer.content?.text else { return }
        UIPasteboard.general.string = text
    }

    /// Prepares a temp copy of the COMPLETE file and opens the share sheet,
    /// whose actions include Save to Files — S13's "Load More/Save" pair.
    private func prepareShare() async {
        guard await fetchWholeFileIfNeeded(),
              let entry = openFile,
              let bytes = viewer.completeBytes
        else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(lastPathSegment(entry.path))
        do {
            try bytes.write(to: url)
            shareItem = ShareItem(url: url)
        } catch {
            loadMoreError = "The file could not be prepared for sharing. \(error.localizedDescription)"
        }
    }

    /// Ensures every byte of the file is held (an unranged read returns the
    /// whole file) so Copy/Share export the complete file: partial text
    /// previews AND never-opened binaries (which fetch nothing on open) both
    /// complete here, on the user's explicit action. Returns false, with an
    /// inline error, when the completing read fails.
    private func fetchWholeFileIfNeeded() async -> Bool {
        if viewer.completeBytes != nil { return true }
        guard let entry = openFile else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let file = try await read(entry, range: nil)
            guard viewer.continuesCurrentEntity(file) else {
                await open(entry, force: true)
                // A ranged kind reopens at its initial range only; a file
                // larger than that is still incomplete — report honestly
                // instead of a silent no-op tap.
                if viewer.completeBytes == nil {
                    loadMoreError = "The file changed on the host. Try again to copy or share the new version."
                    return false
                }
                return true
            }
            viewer.adopt(file)
            return true
        } catch {
            loadMoreError = Self.message(for: error)
            return false
        }
    }

    private func read(_ entry: FileSystemEntry, range: String?) async throws -> ProjectService.ReadFile {
        try await service.readFile(
            at: host.address,
            credential: credential,
            directory: startDirectory,
            path: entry.path,
            range: range
        )
    }

    // MARK: - Presentation helpers

    private var title: String {
        if let openFile { return lastPathSegment(openFile.path) }
        return navigation.current.isEmpty ? lastPathSegment(startDirectory) : lastPathSegment(navigation.current)
    }

    private var entryPathLabel: String {
        guard let openFile else { return "" }
        return openFile.path
    }

    private var openFilePath: String {
        guard let openFile else { return "" }
        return FolderNavigation.absolute(of: openFile.path, startDirectory: startDirectory)
    }

    private var backTargetName: String {
        let previous = navigation.stack.last ?? ""
        return previous.isEmpty ? lastPathSegment(startDirectory) : lastPathSegment(previous)
    }

    private func lastPathSegment(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Maps a transport failure to user text. When the host sent an error
    /// envelope its message is the server's ACTUAL outcome (permission
    /// failures, symlink resolution, missing files) and is shown verbatim —
    /// S13 requires the server's outcome, not a synthesized story.
    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, let envelope):
            if let envelope, !envelope.message.isEmpty {
                return envelope.message
            }
            return "The host refused this request (HTTP \(status)). Check the path and your access."
        case TransportError.connectionFailed:
            return "The host is unreachable. Check the network and try again."
        default:
            return "This file could not be read. \(error.localizedDescription)"
        }
    }
}

/// PDFKit renderer for the whole-file PDF preview: native page navigation
/// (scrolling, page thumbnails via the document model) without custom code.
private struct PDFKitPreview: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data {
            view.document = PDFDocument(data: data)
        }
    }
}

/// System share sheet over the prepared temp copy (offers Save to Files).
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
