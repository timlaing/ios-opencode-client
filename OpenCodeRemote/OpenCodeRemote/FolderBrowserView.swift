import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// Pure navigation state for the S05 folder browser.
///
/// Entry paths from `fs.list`/`fs.find` are **relative to the reviewed
/// location** (docs/api-contract.md W02), so descending REPLACES the level
/// path instead of appending to it — otherwise the second level duplicates
/// path segments (`src` + `src/lib`). Root handling keeps `"/"` intact.
struct FolderNavigation: Equatable {
    /// Location-relative path of the current level (`""` = the location).
    var current = ""
    private(set) var stack: [String] = []

    var canGoUp: Bool { !stack.isEmpty }

    /// Entry paths are location-relative: the new level path is the entry
    /// path itself.
    mutating func descend(to locationRelativePath: String) {
        stack.append(current)
        current = locationRelativePath
    }

    mutating func goUp() {
        current = stack.popLast() ?? ""
    }

    /// Absolute path of a location-relative level, preserving `"/"` as the
    /// root and never emitting a double slash.
    static func absolute(of relative: String, startDirectory: String) -> String {
        let root = startDirectory.count > 1 && startDirectory.hasSuffix("/")
            ? String(startDirectory.dropLast())
            : startDirectory
        if relative.isEmpty { return root }
        return root == "/" ? "/" + relative : root + "/" + relative
    }
}

/// S05 Folder browser (docs/navigation-screens.md): remote directories with
/// parent navigation, directory-only selection, filename search, and
/// readable permission/network errors. Entries are relative to the reviewed
/// location; the tree is navigation, never server authorization —
/// resolution happens server-side through `location.get` on Choose Folder.
struct FolderBrowserView: View {
    let host: OpenCodeDomain.Host
    let credential: BasicCredential?
    /// Absolute directory the browser starts at (a project's canonical
    /// path, or "/" for browsing unlisted locations).
    let startDirectory: String
    var onChoose: (ResolvedLocation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var service = ProjectService(makeTransport: { URLSessionTransport(baseURL: $0) })
    @State private var navigation = FolderNavigation()
    @State private var entries: [FileSystemEntry] = []
    @State private var searchText = ""
    @State private var searchResults: [FileSystemEntry]?
    @State private var message: String?
    @State private var isLoading = false
    @State private var isChoosing = false
    @State private var showingNewFolder = false

    var body: some View {
        NavigationStack {
            Group {
                if let message {
                    ContentUnavailableView {
                        Label("Folder Unavailable", systemImage: "exclamationmark.folder")
                    } description: {
                        Text(message)
                    } actions: {
                        // The listing failed (offline flap, transient 5xx) —
                        // retrying in place beats dismissing the whole picker.
                        Button("Try Again") {
                            Task { await reload() }
                        }
                        .accessibilityIdentifier("S13.tryAgain")
                    }
                } else {
                    entryList
                }
            }
            .navigationTitle(navigation.current.isEmpty ? lastPathSegment(startDirectory) : lastPathSegment(navigation.current))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .disabled(isLoading || isChoosing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await chooseCurrentFolder() }
                    } label: {
                        if isChoosing {
                            ProgressView()
                        } else {
                            Text("Choose Folder")
                        }
                    }
                    .disabled(isLoading || isChoosing)
                }
            }
            .searchable(text: $searchText, prompt: "Search file names")
            .sheet(isPresented: $showingNewFolder) {
                NewProjectView(
                    host: host,
                    credential: credential,
                    parentDirectory: currentAbsolutePath
                ) { resolved in
                    showingNewFolder = false
                    onChoose(resolved)
                    dismiss()
                }
            }
        }
        .task { await reload() }
        .onChange(of: searchText) { _, _ in
            Task { await runSearch() }
        }
    }

    private var currentAbsolutePath: String {
        FolderNavigation.absolute(of: navigation.current, startDirectory: startDirectory)
    }

    private var entryList: some View {
        List {
            if navigation.canGoUp {
                Button {
                    Task { await goUp() }
                } label: {
                    // Label the ACTUAL target (previous stack level), which
                    // can differ from the path parent after a search-result
                    // jump into a deep directory.
                    Label("Back to \(backTargetName)", systemImage: "arrow.up")
                }
            }
            if let searchResults {
                Section("Search Results") {
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
            Label(entry.path, systemImage: "doc")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

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
        // Entry paths are already location-relative (see FolderNavigation).
        navigation.descend(to: entryPath)
        await reload()
    }

    private func goUp() async {
        navigation.goUp()
        await reload()
    }

    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Resolves the reviewed directory server-side before handing it back
    /// (docs/api-contract.md W02 step 2: store the resolved identity).
    private func chooseCurrentFolder() async {
        isChoosing = true
        defer { isChoosing = false }
        do {
            let resolved = try await service.resolveLocation(
                at: host.address,
                credential: credential,
                directory: currentAbsolutePath
            )
            onChoose(resolved)
            dismiss()
        } catch {
            message = Self.message(for: error)
        }
    }

    // MARK: - Presentation helpers

    /// Name of the level `goUp()` returns to: the previous stack level, or
    /// the location root when the stack top is the root level.
    private var backTargetName: String {
        let previous = navigation.stack.last ?? ""
        return previous.isEmpty ? lastPathSegment(startDirectory) : lastPathSegment(previous)
    }

    private func lastPathSegment(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host refused this folder listing (HTTP \(status)). Check the path and your access."
        case TransportError.connectionFailed:
            return "The host is unreachable. Check the network and try again."
        default:
            return "This folder could not be listed."
        }
    }
}
