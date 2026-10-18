import Foundation
import OpenCodeDomain

/// A host-scoped session identity for app-local preferences. Server session
/// IDs are only unique per server, so local pin/hide/follow state is keyed
/// by host + session (docs/navigation-screens.md S07: local states are
/// separate from server state).
struct SessionKey: Hashable, Codable, Sendable {
    var hostID: HostID
    var sessionID: String

    init(hostID: HostID, sessionID: String) {
        self.hostID = hostID
        self.sessionID = sessionID
    }

    /// Stable persisted form, `"<hostID>/<sessionID>"`.
    var storage: String { "\(hostID.rawValue)/\(sessionID)" }

    init?(storage: String) {
        guard let cut = storage.firstIndex(of: "/") else { return nil }
        let host = String(storage[..<cut])
        let session = String(storage[storage.index(after: cut)...])
        guard !host.isEmpty, !session.isEmpty else { return nil }
        self.init(hostID: HostID(rawValue: host), sessionID: session)
    }
}

/// Device-local session preferences (S07): pinned, followed and hidden
/// are APP-LOCAL — never sent to the server, never presented as archive
/// or server-side state (docs/navigation-screens.md S07, docs/api-contract.md
/// W03 confirmed gap).
struct SessionLocalState: Codable, Equatable, Sendable {
    var pinned: Set<String> = []
    var followed: Set<String> = []
    var hidden: Set<String> = []
}

/// Persists `SessionLocalState` in `UserDefaults`. Followed session IDs
/// are the app-side source consumed by `LocalPushConfigurationController.followedSessions`
/// when the S17 eligibility owner runs reconciliation (W17, pending the
/// push entitlement).
@MainActor
final class SessionLocalStateStore {
    static let defaultsKey = "session.localstate.v1"

    private let defaults: UserDefaults
    private(set) var state: SessionLocalState

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(SessionLocalState.self, from: data) {
            state = decoded
        } else {
            state = SessionLocalState()
        }
    }

    func isPinned(_ key: SessionKey) -> Bool { state.pinned.contains(key.storage) }
    func isFollowed(_ key: SessionKey) -> Bool { state.followed.contains(key.storage) }
    func isHidden(_ key: SessionKey) -> Bool { state.hidden.contains(key.storage) }

    @discardableResult func togglePinned(_ key: SessionKey) -> Bool { toggle(\.pinned, key.storage) }
    @discardableResult func toggleFollowed(_ key: SessionKey) -> Bool { toggle(\.followed, key.storage) }
    @discardableResult func toggleHidden(_ key: SessionKey) -> Bool { toggle(\.hidden, key.storage) }

    /// Session IDs followed across any host, for the push payload. The
    /// payload carries BARE session IDs — events reference `sessionID`
    /// directly — so the per-host storage keys are unwrapped here.
    var followedSessionIDs: Set<String> {
        Set(state.followed.compactMap { SessionKey(storage: $0)?.sessionID })
    }

    /// Read-modify-write via key path — `save()` must not run while an
    /// exclusive inout access to `state` is live (Swift exclusivity
    /// checking traps on that overlap).
    private func toggle(_ keyPath: WritableKeyPath<SessionLocalState, Set<String>>, _ member: String) -> Bool {
        var set = state[keyPath: keyPath]
        let nowPresent: Bool
        if set.contains(member) {
            set.remove(member)
            nowPresent = false
        } else {
            set.insert(member)
            nowPresent = true
        }
        state[keyPath: keyPath] = set
        save()
        return nowPresent
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
