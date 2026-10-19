import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// S07 app state: the per-host session inventory behind the Sessions tab
/// (docs/navigation-screens.md S07, docs/api-contract.md W03). Server
/// title search and the project/host scopes are native filters; pinned,
/// followed and hidden states are device-local via
/// `SessionLocalStateStore` and never presented as server state.
@MainActor
@Observable
final class SessionsLibrary {
    typealias CredentialProvider = @MainActor (HostID) -> BasicCredential?

    /// Distinct from a connection failure: the fix is re-pairing the host,
    /// not waiting for the network — callers must not report it as
    /// unreachable (users would retry forever against the real cause).
    enum LibraryError: Error {
        case missingCredential
    }

    private let service: SessionService
    private var credentialProvider: CredentialProvider?
    let localState: SessionLocalStateStore

    private(set) var sessionsByHost: [HostID: [Session]] = [:]
    /// Server-reported actively-drained sessions per host.
    private(set) var activeByHost: [HostID: Set<String>] = [:]
    private(set) var errorsByHost: [HostID: String] = [:]
    /// Title-search failures live apart from listing failures: a search
    /// that fails does NOT mean the host could not list sessions, and a
    /// search that succeeds must never erase a still-missing inventory's
    /// error (the same discipline `markViewed` documents).
    private(set) var searchErrorsByHost: [HostID: String] = [:]
    /// NEXT-page fetch failures, kept apart from listing failures for the
    /// reason `searchErrorsByHost` documents: page one IS on screen, so
    /// these must never reach `errorsByHost` / `visibleErrors` — Host
    /// Status would claim "could not list sessions" beside rows that ARE
    /// listed, and the false error would stick until the next successful
    /// load. Surfaced at the Load More control instead.
    private(set) var loadMoreErrorsByHost: [HostID: String] = [:]
    private(set) var loadingHosts: Set<HostID> = []

    /// Results of the last server-side TITLE search, kept separate so
    /// clearing the search restores the unfiltered inventory.
    private(set) var searchResultsByHost: [HostID: [Session]] = [:]
    /// The term `searchResultsByHost` corresponds to; nil = not searching.
    private(set) var activeSearch: String?
    /// Hosts have more pages behind an opaque cursor (consumed as-is).
    private(set) var hasMoreByHost: [HostID: Bool] = [:]

    init(
        service: SessionService? = nil,
        credentialProvider: CredentialProvider? = nil,
        localState: SessionLocalStateStore? = nil
    ) {
        self.service = service ?? SessionService(makeTransport: { URLSessionTransport(baseURL: $0) })
        self.credentialProvider = credentialProvider
        self.localState = localState ?? SessionLocalStateStore()
    }

    /// Late-binds credential access to the host library (SwiftUI creates
    /// tab state before the environment is available).
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] in hosts?.credential(for: $0) }
    }

    /// Session IDs followed on any host — the value the push payload
    /// carries once S17 eligibility reconciliation runs (W17).
    var followedSessionIDs: Set<String> { localState.followedSessionIDs }

    // MARK: - Loading

    func load(_ entries: [HostLibrary.Entry]) async {
        let targets = entries.filter { !loadingHosts.contains($0.id) }
        for entry in targets { loadingHosts.insert(entry.id) }
        // Parallel: the shared session allows 60 s per request, so one
        // unreachable host must not delay every later host's inventory.
        // Each host's loading flag drops when that host finishes, and all
        // results are keyed per host ID, so completion order is irrelevant.
        await withTaskGroup(of: HostID.self) { group in
            for entry in targets {
                group.addTask {
                    await self.load(host: entry.host)
                    return entry.id
                }
            }
            for await id in group {
                loadingHosts.remove(id)
            }
        }
    }

    /// Loads the host-wide inventory (newest page first). Project scoping
    /// is applied client-side in `rows()` — replacing this cache with a
    /// project-scoped page would corrupt the cursor chain and survive
    /// until the next unscoped refresh.
    func load(host: OpenCodeDomain.Host) async {
        // A fresh listing attempt supersedes any paging failure recorded
        // for this host.
        loadMoreErrorsByHost[host.id] = nil
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            errorsByHost[host.id] = "Re-pair this host to list its sessions."
            return
        }
        do {
            let page = try await service.sessions(at: host.address, credential: credential)
            sessionsByHost[host.id] = page.data
            hasMoreByHost[host.id] = page.cursor?.next != nil
            nextCursors[host.id] = page.cursor?.next
            errorsByHost[host.id] = nil
        } catch {
            errorsByHost[host.id] = Self.message(for: error)
            return
        }
        // Active probing is display-only: a failure degrades to "no
        // running markers" without blanking the loaded inventory, and
        // absence never claims completion (W03 contract).
        activeByHost[host.id] = (try? await service.activeSessionIDs(at: host.address, credential: credential)) ?? []
    }

    /// Appends the next opaque-cursor page for one host.
    func loadMore(host: OpenCodeDomain.Host) async {
        guard !loadingHosts.contains(host.id),
              hasMoreByHost[host.id] == true,
              let credentialProvider, let credential = credentialProvider(host.id)
        else { return }
        loadingHosts.insert(host.id)
        defer { loadingHosts.remove(host.id) }
        // A retry starts clean: the control's previous failure clears the
        // moment a new attempt begins.
        loadMoreErrorsByHost[host.id] = nil
        do {
            let page = try await service.sessions(at: host.address, credential: credential, cursor: cursorForNextPage(host: host))
            sessionsByHost[host.id, default: []].append(contentsOf: page.data)
            hasMoreByHost[host.id] = page.cursor?.next != nil
            nextCursors[host.id] = page.cursor?.next
        } catch {
            // A failed NEXT page is not a listing failure — page one is on
            // screen (the discipline `search` and `markViewed` follow); it
            // belongs beside Load More, in paging wording.
            loadMoreErrorsByHost[host.id] = Self.loadMoreMessage(for: error)
        }
    }

    /// Server-side title search across the visible hosts. Results replace
    /// neither the inventory nor each other per host — one term at a time.
    /// Parallel for the reason `load(_:)` gives: the shared session allows
    /// 60 s per request, so one unreachable host must not delay every later
    /// host's results until its timeout expires.
    func search(_ term: String, entries: [HostLibrary.Entry]) async {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            activeSearch = nil
            searchResultsByHost = [:]
            searchErrorsByHost = [:]
            return
        }
        activeSearch = needle
        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                guard let credentialProvider, let credential = credentialProvider(entry.id) else {
                    // No credential means the host is SKIPPED, not searched:
                    // without this clear, rows() would keep presenting the
                    // previous term's sessions under the new activeSearch —
                    // silently, with no error. The re-pair cause is recorded
                    // as a SEARCH failure, mirroring load(host:)'s own
                    // credential guard.
                    searchResultsByHost[entry.id] = nil
                    searchErrorsByHost[entry.id] = "Re-pair this host to search its sessions."
                    continue
                }
                group.addTask {
                    await self.searchOne(credential: credential, entry: entry, needle: needle)
                }
            }
        }
    }

    /// One host's title search. Writes only while `needle` is still the
    /// current term — a slower overlapping request must not overwrite newer
    /// results, and a cancelled task must not surface errors.
    private func searchOne(credential: BasicCredential, entry: HostLibrary.Entry, needle: String) async {
        do {
            let page = try await service.sessions(
                at: entry.host.address, credential: credential, search: needle
            )
            guard activeSearch == needle, !Task.isCancelled else { return }
            searchResultsByHost[entry.id] = page.data
            // Only the SEARCH error clears here — a successful search
            // is no evidence the inventory exists.
            searchErrorsByHost[entry.id] = nil
        } catch {
            guard activeSearch == needle, !Task.isCancelled else { return }
            // A failed host shows no stale results from the previous
            // term — its own error is surfaced instead, in search
            // wording, never painted as a listing failure.
            searchResultsByHost[entry.id] = nil
            searchErrorsByHost[entry.id] = Self.searchMessage(for: error)
        }
    }

    // MARK: - Rows and markers

    struct SessionRow: Identifiable {
        var id: String { "\(host.id.rawValue)/\(session.id)" }
        let host: OpenCodeDomain.Host
        let session: Session
        let pinned: Bool
        let followed: Bool
        let hidden: Bool
        let running: Bool
        let unread: Bool
        let needsAttention: Bool
    }

    /// Rows for the current scopes. `projectFilter` narrows to one
    /// project's sessions; `search` rows come from server title search;
    /// the hidden filter SHOWS ONLY sessions hidden on this device when
    /// enabled, and excludes them otherwise.
    func rows(
        entries: [HostLibrary.Entry],
        hostFilter: HostID?,
        projectFilter: String?,
        hiddenFilter: Bool
    ) -> [SessionRow] {
        var rows: [SessionRow] = []
        for entry in entries where hostFilter == nil || entry.id == hostFilter {
            let source: [Session]
            if activeSearch != nil {
                source = searchResultsByHost[entry.id] ?? []
            } else {
                source = sessionsByHost[entry.id] ?? []
            }
            for session in source {
                guard projectFilter == nil || session.projectID == projectFilter else { continue }
                let key = SessionKey(hostID: entry.id, sessionID: session.id)
                let hidden = localState.isHidden(key)
                guard hiddenFilter ? hidden : !hidden else { continue }
                rows.append(SessionRow(
                    host: entry.host,
                    session: session,
                    pinned: localState.isPinned(key),
                    followed: localState.isFollowed(key),
                    hidden: hidden,
                    running: activeByHost[entry.id]?.contains(session.id) ?? false,
                    unread: !hidden && session.isUnread,
                    needsAttention: Self.needsAttention(session)
                ))
            }
        }
        return rows
    }

    /// Failed or interrupted executions need attention; succeeded or
    /// still-running sessions do not.
    private static func needsAttention(_ session: Session) -> Bool {
        session.outcome == "failed" || session.outcome == "interrupted"
    }

    func hasLoaded(hostID: HostID) -> Bool {
        sessionsByHost[hostID] != nil || errorsByHost[hostID] != nil
    }

    /// Visible errors for the current host filter (never rendered as
    /// "no sessions"). While a title search is active, its OWN failures
    /// lead — a listing failure stays reachable underneath for hosts the
    /// search skipped, and returns alone the moment the search clears
    /// (search outcomes never erase it).
    func visibleErrors(entries: [HostLibrary.Entry], hostFilter: HostID?) -> [(id: HostID, name: String, message: String)] {
        entries
            .filter { hostFilter == nil || $0.id == hostFilter }
            .compactMap { entry in
                let message = activeSearch == nil
                    ? errorsByHost[entry.id]
                    : searchErrorsByHost[entry.id] ?? errorsByHost[entry.id]
                guard let message else { return nil }
                return (entry.id, entry.host.displayName, message)
            }
    }

    // MARK: - Mutations (server-confirmed before local state changes)

    func create(host: OpenCodeDomain.Host, directory: String, title: String?) async throws -> Session {
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            throw LibraryError.missingCredential
        }
        let created = try await service.createSession(
            at: host.address, credential: credential, directory: directory,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        sessionsByHost[host.id, default: []].insert(created, at: 0)
        return created
    }

    func rename(host: OpenCodeDomain.Host, sessionID: String, title: String) async throws {
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            throw LibraryError.missingCredential
        }
        try await service.rename(at: host.address, credential: credential, sessionID: sessionID, title: title)
        updateLocal(sessionID: sessionID, in: host.id) { $0.title = title }
        if let index = searchResultsByHost[host.id]?.firstIndex(where: { $0.id == sessionID }) {
            searchResultsByHost[host.id]?[index].title = title
        }
    }

    func remove(host: OpenCodeDomain.Host, sessionID: String) async throws {
        guard let credentialProvider, let credential = credentialProvider(host.id) else {
            throw LibraryError.missingCredential
        }
        try await service.remove(at: host.address, credential: credential, sessionID: sessionID)
        // The server deletes child sessions with the parent (W03); drop
        // every locally-known descendant so no stale row survives to a
        // failed session.get. Traversal covers inventory + search results.
        var removed = descendantSessionIDs(of: sessionID, on: host.id)
        removed.insert(sessionID)
        sessionsByHost[host.id]?.removeAll { removed.contains($0.id) }
        searchResultsByHost[host.id]?.removeAll { removed.contains($0.id) }
    }

    /// Every known DESCENDANT of `sessionID` on this host (inventory +
    /// search results): attribution for linked child-session approvals
    /// (S11). Empty when the inventory has never seen children —
    /// attribution unavailable means no linked entries, never guessed.
    func descendantSessionIDs(of sessionID: String, on hostID: HostID) -> Set<String> {
        let known = (sessionsByHost[hostID] ?? []) + (searchResultsByHost[hostID] ?? [])
        var descendants: Set<String> = []
        var frontier: Set<String> = [sessionID]
        while !frontier.isEmpty {
            let children = Set(known
                .filter { ($0.parentID.map(frontier.contains) ?? false) && !descendants.contains($0.id) }
                .map(\.id))
            frontier = children
            descendants.formUnion(children)
        }
        return descendants
    }

    /// Marks a session read using a server-observed epoch — the session's
    /// last `time.updated` this client has seen, never the phone clock.
    /// Sessions without any observed time cannot be honestly acknowledged
    /// and are left untouched.
    func markViewed(host: OpenCodeDomain.Host, session: Session) async {
        guard let observed = session.time?.updated ?? session.time?.created else { return }
        guard let credentialProvider, let credential = credentialProvider(host.id) else { return }
        do {
            try await service.markViewed(
                at: host.address, credential: credential,
                sessionID: session.id, observedIdleEpoch: observed
            )
            updateLocal(sessionID: session.id, in: host.id) { $0.time?.viewed = observed }
        } catch {
            // A failed session.view is NOT a listing failure: the listing
            // had already succeeded. Writing it into errorsByHost would
            // paint "could not list sessions" on the Sessions tab every
            // time a conversation opened against a flaking host, and the
            // false error would persist until the next successful load.
            // Unread state is display-only — the badge stays as it was.
        }
    }

    /// Applies a HOST-CONFIRMED (204) W06 agent/model selection to the
    /// local caches so no other view shows a stale selection — both the
    /// inventory and the active title-search results, exactly like
    /// `rename`. Called only after the switch succeeded, never
    /// optimistically.
    func noteSelection(
        host: OpenCodeDomain.Host,
        sessionID: String,
        agent: String?,
        model: Session.ModelRef?
    ) {
        updateLocal(sessionID: sessionID, in: host.id) { session in
            if let agent { session.agent = agent }
            if let model { session.model = model }
        }
        if let index = searchResultsByHost[host.id]?.firstIndex(where: { $0.id == sessionID }) {
            if let agent { searchResultsByHost[host.id]?[index].agent = agent }
            if let model { searchResultsByHost[host.id]?[index].model = model }
        }
    }

    private func updateLocal(sessionID: String, in hostID: HostID, _ mutate: (inout Session) -> Void) {
        if let index = sessionsByHost[hostID]?.firstIndex(where: { $0.id == sessionID }) {
            mutate(&sessionsByHost[hostID]![index])
        }
    }

    private func cursorForNextPage(host: OpenCodeDomain.Host) -> String? {
        // Cursor bookkeeping is kept per host alongside the inventory;
        // pages beyond the first are fetched from the stored cursor.
        nextCursors[host.id]
    }

    private var nextCursors: [HostID: String] = [:]

    /// Search failures get SEARCH wording — "could not list sessions"
    /// would claim the inventory is broken when only the title search
    /// failed.
    private static func searchMessage(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not search sessions (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable right now. Pull to refresh to try again."
        default:
            return "Sessions could not be searched on this host."
        }
    }

    /// Next-page failures get PAGING wording — "could not list sessions"
    /// would claim the inventory is broken when page one is on screen and
    /// only the follow-up fetch failed (same discipline as search).
    private static func loadMoreMessage(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not load more sessions (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable right now. Pull to refresh to try again."
        default:
            return "More sessions could not be loaded from this host."
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not list sessions (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable right now. Pull to refresh to try again."
        default:
            return "Sessions could not be loaded from this host."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
