import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

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
    /// Path levels visited below `startDirectory` (relative, `""` = root).
    @State private var stack: [String] = []
    @State private var current = ""
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
                    ContentUnavailableView(
                        "Folder Unavailable",
                        systemImage: "exclamationmark.folder",
                        description: Text(message)
                    )
                } else {
                    entryList
                }
            }
            .navigationTitle(current.isEmpty ? lastPathSegment(startDirectory) : lastPathSegment(current))
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
                    parentDirectory: absolutePath(of: current)
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

    private var entryList: some View {
        List {
            if !current.isEmpty {
                Button {
                    Task { await goUp() }
                } label: {
                    Label("Back to \(lastPathSegment(parentOf(current)))", systemImage: "arrow.up")
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
                path: current.isEmpty ? "." : current
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

    private func descend(into relativePath: String) async {
        stack.append(current)
        current = join(current, relativePath)
        await reload()
    }

    private func goUp() async {
        current = stack.popLast() ?? ""
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
                directory: absolutePath(of: current)
            )
            onChoose(resolved)
            dismiss()
        } catch {
            message = Self.message(for: error)
        }
    }

    // MARK: - Paths (relative levels anchored at the reviewed location)

    private func join(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        return base + "/" + component
    }

    private func parentOf(_ relative: String) -> String {
        guard let cut = relative.lastIndex(of: "/") else { return "" }
        return String(relative[..<cut])
    }

    private func absolutePath(of relative: String) -> String {
        let root = startDirectory.hasSuffix("/") ? String(startDirectory.dropLast()) : startDirectory
        return relative.isEmpty ? root : root + "/" + relative
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
