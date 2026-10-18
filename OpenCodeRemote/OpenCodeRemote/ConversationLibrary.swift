import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// S08 transcript model (W04): reads a host's conversation history via
/// `session.message.list` and its active model context via
/// `session.context` (docs/navigation-screens.md S08/S14,
/// docs/api-contract.md W04).
///
/// Paging: the first page is the NEWEST (`order: .descending`, limit 50)
/// and displays reversed (oldest → newest). Older pages walk the opaque
/// `next` cursor; the contract forbids combining cursor + order, so cursor
/// pages drop `order` (enforced in `SessionHistoryService`). Records are
/// merged by ID so overlapping refreshes/pages never duplicate a message
/// on screen.
///
/// Every message stays in the list — bookkeeping variants render as
/// compact transition rows, and unknown variants keep their raw payload
/// rather than silently dropping a gap in the transcript.
@MainActor
@Observable
final class ConversationLibrary {
    typealias CredentialProvider = @MainActor (HostID) -> BasicCredential?

    private let service: SessionHistoryService
    private var credentialProvider: CredentialProvider?

    /// Transcript in display order: oldest → newest.
    private(set) var messages: [SessionMessage] = []
    /// Active model context (messages since the last compaction) — kept
    /// separate from the full transcript.
    private(set) var activeContext: [SessionMessage] = []
    private(set) var error: String?
    private(set) var contextError: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isLoadingContext = false
    /// Opaque cursor for the next OLDER page; nil when history is
    /// exhausted.
    private(set) var nextCursor: String?
    private(set) var hasMore = false
    /// The session whose transcript is loaded — paging reuses it.
    private(set) var loadedSessionID: String?

    init(
        service: SessionHistoryService? = nil,
        credentialProvider: CredentialProvider? = nil
    ) {
        self.service = service ?? SessionHistoryService(makeTransport: { URLSessionTransport(baseURL: $0) })
        self.credentialProvider = credentialProvider
    }

    /// Late-binds credential access to the host library (SwiftUI creates
    /// view state before the environment is available).
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] in hosts?.credential(for: $0) }
    }

    /// Opens a transcript with the newest page, displayed oldest first.
    func open(host: OpenCodeDomain.Host, sessionID: String) async {
        guard !isLoading else { return }
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to read its messages."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.messages(
                at: host.address, credential: credential, sessionID: sessionID
            )
            messages = Self.ordered(Self.deduped(page.data))
            nextCursor = page.cursor?.next
            hasMore = page.cursor?.next != nil
            loadedSessionID = sessionID
            error = nil
        } catch {
            if !Self.isSilent(error) { self.error = Self.message(for: error) }
        }
    }

    /// Fetches the next OLDER page via the opaque cursor (no order) and
    /// prepends it to the display list.
    func loadOlder(host: OpenCodeDomain.Host) async {
        guard let sessionID = loadedSessionID else { return }
        guard let cursor = nextCursor, !isLoadingMore, !isLoading else { return }
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to read its messages."
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.messages(
                at: host.address, credential: credential, sessionID: sessionID, cursor: cursor
            )
            let older = Self.ordered(Self.deduped(page.data))
            let existingIDs = Set(messages.map(\.id))
            messages = older.filter { !existingIDs.contains($0.id) } + messages
            nextCursor = page.cursor?.next
            hasMore = page.cursor?.next != nil
        } catch {
            if !Self.isSilent(error) { self.error = Self.message(for: error) }
        }
    }

    /// Re-fetches the newest page and merges it: fresh records replace by
    /// ID, older records are kept, and a server-side deletion is honoured
    /// (anything absent from the newest page and already seen is dropped
    /// only when it sorts INTO that page's range — outside it, it stays).
    func refresh(host: OpenCodeDomain.Host, sessionID: String) async {
        guard let credential = credentialProvider?(host.id) else {
            error = "Re-pair this host to read its messages."
            return
        }
        do {
            let page = try await service.messages(
                at: host.address, credential: credential, sessionID: sessionID
            )
            let fresh = Self.ordered(Self.deduped(page.data))
            let freshIDs = Set(fresh.map(\.id))
            // The newest page only overlaps what it covers. Without ANY
            // overlap (first load failed here, another session, or >1 page
            // of arrivals) the loaded transcript cannot be joined
            // honestly — a splice would hide the gap AND leave a cursor
            // that walks from the wrong position, so replace instead.
            let overlaps = messages.contains { freshIDs.contains($0.id) }
            if messages.isEmpty || !overlaps || loadedSessionID != sessionID {
                messages = fresh
                nextCursor = page.cursor?.next
                hasMore = page.cursor?.next != nil
            } else {
                // Overlap guarantees contiguity at the seam. Records the
                // fresh page covers are owned by it (arrivals absorbed,
                // in-range deletions honoured); records BELOW its oldest
                // are unobservable at this depth, so they stay.
                let older = messages.filter { message in
                    guard !freshIDs.contains(message.id) else { return false }
                    return Self.sortKey(message) < Self.sortKey(fresh.first)
                }
                messages = older + fresh
            }
            loadedSessionID = sessionID
            error = nil
        } catch {
            if !Self.isSilent(error) { self.error = Self.message(for: error) }
        }
    }

    /// Loads the active model context (messages since the last
    /// compaction) for the S14 panel.
    func loadContext(host: OpenCodeDomain.Host, sessionID: String) async {
        guard !isLoadingContext else { return }
        guard let credential = credentialProvider?(host.id) else {
            contextError = "Re-pair this host to read its context."
            return
        }
        isLoadingContext = true
        defer { isLoadingContext = false }
        do {
            activeContext = Self.ordered(Self.deduped(
                try await service.context(at: host.address, credential: credential, sessionID: sessionID)
            ))
            contextError = nil
        } catch {
            if !Self.isSilent(error) { contextError = Self.message(for: error) }
        }
    }

    // MARK: - Transcript helpers

    /// Display order: oldest → newest (server order is newest first).
    private static func ordered(_ page: [SessionMessage]) -> [SessionMessage] {
        Array(page.reversed())
    }

    /// Keeps the FIRST record for each ID in page order.
    private static func deduped(_ page: [SessionMessage]) -> [SessionMessage] {
        var seen: Set<String> = []
        return page.filter { seen.insert($0.id).inserted }
    }

    /// Server sort key (time.created, id) ascending — mirrors the host's
    /// ordering so merge boundaries are honest.
    private static func sortKey(_ message: SessionMessage?) -> (Int64, String) {
        guard let message else { return (.min, "") }
        return (message.time.created, message.id)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TransportError.http(let status, _):
            return "The host could not load messages (HTTP \(status))."
        case TransportError.connectionFailed:
            return "The host is unreachable right now. Pull to refresh to try again."
        default:
            return "Messages could not be loaded from this host."
        }
    }

    /// Cancellation is routine (view dismissed, request superseded) and
    /// never surfaced as a failure.
    private static func isSilent(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case TransportError.cancelled = error { return true }
        return false
    }
}
