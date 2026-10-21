import Foundation
import Observation
import OpenCodeDomain
import OpenCodeStorage
import OpenCodeTransport

/// S02 app state: the persisted host list plus live connection/version/auth
/// state per host (docs/navigation-screens.md). Credentials live in the
/// Keychain; this type only ever holds host IDs, never secrets.
@MainActor
@Observable
final class HostLibrary {
    enum LibraryError: Error {
        case storageUnavailable
    }

    enum ConnectionState: Equatable {
        case checking
        case reachable(version: String?)
        case unreachable
        /// The host rejected the stored credential: re-pair required.
        case reauthRequired
        /// The host answered, but not as an OpenCode server (no such
        /// path, non-JSON body, or an undocumented status): the network
        /// is fine — "Unreachable" would blame a working connection.
        case invalidResponse
    }

    struct Entry: Identifiable {
        var id: HostID { host.id }
        let host: OpenCodeDomain.Host
        var connection: ConnectionState
    }

    private let hostStore: HostStore?
    private let credentials: KeychainCredentialStore
    private let pairing: HostPairingService

    private(set) var entries: [Entry] = []
    private(set) var storageError: String?

    init(
        hostStore: HostStore? = nil,
        credentials: KeychainCredentialStore = KeychainCredentialStore(),
        pairing: HostPairingService = HostPairingService()
    ) {
        self.credentials = credentials
        self.pairing = pairing
        if let hostStore {
            self.hostStore = hostStore
        } else {
            do {
                self.hostStore = try HostStore(writingAt: Self.databaseDirectory)
            } catch {
                self.hostStore = nil
                storageError = "Device storage could not be opened, so hosts cannot be saved."
            }
        }
        reload()
    }

    /// Re-reads persisted hosts. Hosts still present KEEP their known
    /// connection state — an add or remove reload must not blank every
    /// other row back to a spinner (the Servers tab only probes in its
    /// task/pull-to-refresh, so a reset would stick until then). Hosts
    /// with no previous state start at `checking`; call `refreshStates()`
    /// to probe them.
    func reload() {
        guard let hostStore else { return }
        let previous = Dictionary(
            entries.map { ($0.id, $0.connection) },
            uniquingKeysWith: { first, _ in first }
        )
        do {
            entries = try hostStore.hosts().map {
                Entry(host: $0, connection: previous[$0.id] ?? .checking)
            }
            // One transient read failure must not be permanent: the next
            // successful read clears it, so pull-to-refresh recovers the
            // list. (The INIT failure is different — hostStore is nil
            // there, reload() returns before this, and that error stays
            // until the app can open its storage again.)
            storageError = nil
        } catch {
            storageError = "Hosts could not be read from device storage."
        }
    }

    /// Persists a paired host and its credential. The credential is written
    /// first so a host row never exists without its secret; a failed row write
    /// removes the just-saved secret again. The new row starts in the
    /// `reachable` state the pairing health check just proved, rather than
    /// waiting for the next refresh cycle.
    func add(_ paired: PairedHost) throws {
        guard let hostStore else { throw LibraryError.storageUnavailable }
        var paired = paired
        let existing = entries.first(where: { Self.isSameServer($0.host.address, paired.host.address) })
        if let existing {
            // RE-PAIR of a known server: the host keeps its identity
            // (id + createdAt), so the new credential replaces the old
            // one under the same Keychain account, no duplicate row
            // appears for one address, and every per-host surface —
            // projects, sessions, approvals, local-state caches, the
            // push provider's `secretsByHost` comparison (its comment
            // assumes exactly this) — sees a credential CHANGE, not a
            // new host. The freshly proven displayName/version from
            // THIS pairing are still adopted below.
            paired.host.id = existing.host.id
            paired.host.createdAt = existing.host.createdAt
        }
        do {
            try credentials.save(secret: paired.secret, for: paired.host.id.rawValue)
        } catch {
            // Surface every storage failure (Keychain included) as the same
            // user-facing LibraryError, never as a raw StoreError.
            throw LibraryError.storageUnavailable
        }
        do {
            try hostStore.upsert(paired.host)
        } catch {
            // Roll back ONLY a brand-new host's just-saved secret. A
            // re-pair reuses the EXISTING row's id: the old secret was
            // already replaced above, so deleting here would leave a
            // credential-less row behind — and the secret being kept is
            // the one this pairing just health-proved.
            if existing == nil {
                try? credentials.deleteSecret(for: paired.host.id.rawValue)
            }
            throw LibraryError.storageUnavailable
        }
        reload()
        if let index = entries.firstIndex(where: { $0.id == paired.host.id }) {
            entries[index] = Entry(host: paired.host, connection: .reachable(version: paired.host.lastVersion))
        }
    }

    /// Same server? Scheme, host, port and path — case-insensitive on
    /// scheme/host, trailing-slash-insensitive on the path — so a
    /// re-pair scanned from the same QR or typed with cosmetic
    /// differences still matches. Deliberately NOT `URL ==`, which is
    /// byte-exact and would miss "http://h:4096" vs "http://h:4096/".
    private static func isSameServer(_ lhs: URL, _ rhs: URL) -> Bool {
        func norm(_ path: String) -> String {
            path == "/" ? "" : String(path.dropLast(path.hasSuffix("/") ? 1 : 0))
        }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
            && norm(lhs.path) == norm(rhs.path)
    }

    /// Removes the host row and its stored credential from this device. The
    /// host server itself is unchanged (docs/navigation-screens.md removal
    /// semantics).
    func remove(_ id: HostID) throws {
        guard let hostStore else { throw LibraryError.storageUnavailable }
        // Credential first, reload always: a Keychain failure then leaves
        // both the row and the secret in place, and `entries` can never
        // show a host the store no longer has.
        defer { reload() }
        try credentials.deleteSecret(for: id.rawValue)
        try hostStore.deleteHost(id: id)
    }

    /// The stored Basic credential for a host, or nil when this device no
    /// longer holds one (re-pair required). The secret never leaves the
    /// caller; it is never stored on entries or logged.
    func credential(for id: HostID) -> BasicCredential? {
        let secret = (try? credentials.secret(for: id.rawValue)) ?? nil
        return secret.map(BasicCredential.init(secret:))
    }

    /// Probes every host with its stored credential and records the result.
    /// Entries are re-located by ID after every await: a concurrent
    /// add/remove reloads the array mid-refresh, so holding an index across
    /// an await would write to the wrong row or trap out of bounds.
    func refreshStates() async {
        for index in entries.indices {
            entries[index].connection = .checking
        }
        let hosts = entries.map(\.host)
        // Parallel: the shared session allows 60 s per request, so one
        // unreachable host must not hold every later host at .checking.
        // Results re-locate their entry by ID, so completion order is
        // irrelevant and a concurrent add/remove stays safe.
        await withTaskGroup(of: (HostID, ConnectionState).self) { group in
            for host in hosts {
                group.addTask { (host.id, await self.state(of: host)) }
            }
            for await (id, result) in group {
                if let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index].connection = result
                }
            }
        }
    }

    private func state(of host: OpenCodeDomain.Host) async -> ConnectionState {
        // A missing item is the normal "restored device, re-pair" case; a
        // Keychain read failure is treated the same way rather than crashing.
        let secret = (try? credentials.secret(for: host.id.rawValue)) ?? nil
        guard let secret else { return .reauthRequired }
        do {
            let info = try await pairing.healthCheck(at: host.address, secret: secret)
            return .reachable(version: info.version)
        } catch HostPairingService.Failure.rejectedCredential {
            return .reauthRequired
        } catch HostPairingService.Failure.invalidResponse {
            // Reached, but the answer was not an OpenCode one (no such
            // path, non-JSON body, 5xx): the network is working — calling
            // it "Unreachable" would send the user to a connection that is
            // fine and change nothing.
            return .invalidResponse
        } catch {
            return .unreachable
        }
    }

    /// The host registry directory: the app's own Application Support
    /// store (no other process opens it), with an equivalent fallback
    /// if location resolution ever fails.
    private static var databaseDirectory: URL {
        (try? SharedStoreLocation.directory()) ?? appLocalFallback
    }

    private static var appLocalFallback: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenCodeRemote", isDirectory: true)
    }
}
