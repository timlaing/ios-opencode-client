import XCTest
import OpenCodeDomain
import OpenCodeStorage
import OpenCodeTransport
@testable import OpenCodeRemote

/// S02 host-library behavior against an in-memory store, the real device
/// Keychain (simulator), and a canned transport.
@MainActor
final class HostLibraryTests: XCTestCase {
    private struct FakeTransport: OpenCodeTransport {
        var health: Result<APIResponse, TransportError>

        func perform(_ request: APIRequest) async throws -> APIResponse {
            switch health {
            case .success(let response): return response
            case .failure(let error): throw error
            }
        }

        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func makeLibrary(
        health: Result<APIResponse, TransportError>
    ) throws -> (HostLibrary, HostStore, KeychainCredentialStore) {
        let store = try HostStore(inMemory: ())
        let credentials = KeychainCredentialStore(service: "tests.host-library.\(UUID().uuidString)")
        let pairing = HostPairingService(makeTransport: { _ in FakeTransport(health: health) })
        let library = HostLibrary(hostStore: store, credentials: credentials, pairing: pairing)
        return (library, store, credentials)
    }

    private func paired(
        id: String = "H-1",
        name: String = "Lab",
        secret: String = "token-1",
        address: String = "https://lab.example:4096"
    ) throws -> PairedHost {
        PairedHost(
            host: OpenCodeDomain.Host(
                id: HostID(rawValue: id),
                displayName: name,
                address: try XCTUnwrap(URL(string: address))
            ),
            secret: secret
        )
    }

    private func healthy(_ version: String) -> APIResponse {
        APIResponse(statusCode: 200, payload: .json(Data(#"{"version":"\#(version)"}"#.utf8)))
    }

    func testAddPersistsHostAndCredentialThenRefreshReportsReachable() async throws {
        let (library, store, credentials) = try makeLibrary(health: .success(healthy("2.0.25")))

        try library.add(try paired())

        XCTAssertEqual(library.entries.map(\.host.displayName), ["Lab"])
        XCTAssertEqual(try store.hosts().count, 1)
        XCTAssertEqual(try credentials.secret(for: "H-1"), "token-1")

        await library.refreshStates()
        XCTAssertEqual(library.entries.first?.connection, .reachable(version: "2.0.25"))
    }

    func testRefreshReportsReauthRequiredWhenCredentialMissing() async throws {
        let (library, store, _) = try makeLibrary(health: .success(healthy("2.0.25")))
        try store.upsert(try paired().host) // row without a Keychain secret

        library.reload()
        await library.refreshStates()

        XCTAssertEqual(library.entries.first?.connection, .reauthRequired)
    }

    func testRefreshReportsReauthRequiredWhenHostRejectsStoredCredential() async throws {
        let (library, _, credentials) = try makeLibrary(
            health: .failure(.http(status: 401, envelope: nil))
        )
        try library.add(try paired(secret: "stale-token"))

        await library.refreshStates()

        XCTAssertEqual(library.entries.first?.connection, .reauthRequired)
        XCTAssertEqual(try credentials.secret(for: "H-1"), "stale-token", "The secret is kept for re-pairing decisions, not deleted")
    }

    func testRefreshReportsUnreachableOnConnectionFailure() async throws {
        let (library, _, _) = try makeLibrary(health: .failure(.connectionFailed("offline")))
        try library.add(try paired())

        await library.refreshStates()

        XCTAssertEqual(library.entries.first?.connection, .unreachable)
    }

    func testRefreshSurfacesNotOpenCodeInsteadOfUnreachable() async throws {
        // The host ANSWERED with an undocumented status: the connection is
        // working — S02 must not send the user to a network that is fine.
        let (library, _, _) = try makeLibrary(health: .failure(.http(status: 500, envelope: nil)))
        try library.add(try paired())

        await library.refreshStates()

        XCTAssertEqual(library.entries.first?.connection, .invalidResponse)
    }

    func testRepairingTheSameAddressReplacesTheRow() async throws {
        let (library, _, credentials) = try makeLibrary(health: .success(healthy("1.0.0")))
        let first = try paired(secret: "old-token")
        try library.add(first)
        // The pairing flow mints a FRESH HostID every time
        // (completePairing); a re-pair of the same address must still
        // replace the row rather than add a second one.
        let second = try paired(id: "H-2", name: "Renamed Host", secret: "new-token")
        try library.add(second)

        XCTAssertEqual(library.entries.count, 1, "re-pairing one address must not duplicate the row")
        XCTAssertEqual(library.entries.first?.host.id, first.host.id, "the original identity is kept")
        XCTAssertEqual(library.entries.first?.host.displayName, "Renamed Host", "the new proven name is adopted")
        XCTAssertEqual(
            try credentials.secret(for: first.host.id.rawValue), "new-token",
            "the credential is replaced under the same Keychain account"
        )
        XCTAssertNil(try credentials.secret(for: "H-2"), "no orphan secret under the minted id")
    }

    func testRemoveDeletesRowAndCredential() async throws {
        let (library, store, credentials) = try makeLibrary(health: .success(healthy("1.0.0")))
        try library.add(try paired(id: "H-1"))
        // A SECOND host must be a different server — one address is one
        // host (re-pairing an address replaces its row).
        try library.add(try paired(id: "H-2", name: "Office", address: "https://office.example:4096"))

        try library.remove(HostID(rawValue: "H-1"))

        XCTAssertEqual(library.entries.map(\.id.rawValue), ["H-2"])
        XCTAssertEqual(try store.hosts().map(\.id.rawValue), ["H-2"])
        XCTAssertNil(try credentials.secret(for: "H-1"))
        XCTAssertEqual(try credentials.secret(for: "H-2"), "token-1")
    }
}
