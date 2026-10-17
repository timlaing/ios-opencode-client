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

    /// Re-reads persisted hosts. Connection state resets to `checking`; call
    /// `refreshStates()` to probe each host.
    func reload() {
        guard let hostStore else { return }
        do {
            entries = try hostStore.hosts().map { Entry(host: $0, connection: .checking) }
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
            try? credentials.deleteSecret(for: paired.host.id.rawValue)
            throw LibraryError.storageUnavailable
        }
        reload()
        if let index = entries.firstIndex(where: { $0.id == paired.host.id }) {
            entries[index] = Entry(host: paired.host, connection: .reachable(version: paired.host.lastVersion))
        }
    }

    /// Removes the host row and its stored credential from this device. The
    /// host server itself is unchanged (docs/navigation-screens.md removal
    /// semantics).
    func remove(_ id: HostID) throws {
        guard let hostStore else { throw LibraryError.storageUnavailable }
        try hostStore.deleteHost(id: id)
        try credentials.deleteSecret(for: id.rawValue)
        reload()
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
        for host in hosts {
            let result = await state(of: host)
            if let index = entries.firstIndex(where: { $0.id == host.id }) {
                entries[index].connection = result
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
        } catch {
            return .unreachable
        }
    }

    /// The shared store directory — the same location the local-push
    /// extension resolves (docs/local-push-implementation.md §"Architecture
    /// and ownership"), so both processes see one host registry. Falls back
    /// to the app's own Application Support directory until the App Group
    /// entitlement exists; that future path change needs a one-time
    /// migration (see SharedStoreLocation's note for the entitlement slice).
    private static var databaseDirectory: URL {
        (try? SharedStoreLocation.directory()) ?? appLocalFallback
    }

    private static var appLocalFallback: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenCodeRemote", isDirectory: true)
    }
}
