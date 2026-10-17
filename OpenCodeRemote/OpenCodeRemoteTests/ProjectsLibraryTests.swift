import XCTest
import OpenCodeDomain
import OpenCodeTransport
@testable import OpenCodeRemote

/// S04 inventory tests (docs/navigation-screens.md): per-host loading with
/// credential gating, per-host error isolation, host-scoped search over
/// names and paths, and local recent-folder tracking.
@MainActor
final class ProjectsLibraryTests: XCTestCase {
    private struct StubTransport: OpenCodeTransport {
        var responses: [String: Result<APIResponse, TransportError>] = [:]

        func perform(_ request: APIRequest) async throws -> APIResponse {
            guard let result = responses[request.operationID] else {
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
            switch result {
            case .success(let response): return response
            case .failure(let error): throw error
            }
        }

        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func host(_ id: String, name: String) -> OpenCodeDomain.Host {
        OpenCodeDomain.Host(
            id: HostID(rawValue: id),
            displayName: name,
            address: URL(string: "http://\(id).local:4097")!,
            createdAt: Date(timeIntervalSince1970: 0),
            lastVersion: nil
        )
    }

    private func entry(_ host: OpenCodeDomain.Host) -> HostLibrary.Entry {
        HostLibrary.Entry(host: host, connection: .reachable(version: nil))
    }

    private func json(_ body: String) -> Result<APIResponse, TransportError> {
        .success(APIResponse(statusCode: 200, payload: .json(Data(body.utf8))))
    }

    private let harbourJSON = #"[{"id":"project_b","canonical":"/srv/demo/harbour-beta","name":"Beta Tool"},{"id":"project_a","canonical":"/srv/demo/harbour","name":"Alpha Tool"}]"#
    private let orbitJSON = #"[{"id":"project_orbit","canonical":"/srv/demo/orbit","name":"Orbit Demo"}]"#

    private func library(
        responses: [String: Result<APIResponse, TransportError>],
        credentials: [String: BasicCredential?] = ["host_one": BasicCredential(secret: "t"), "host_two": BasicCredential(secret: "t")]
    ) -> ProjectsLibrary {
        let transport = StubTransport(responses: responses)
        return ProjectsLibrary(
            service: ProjectService(makeTransport: { _ in transport }),
            credentialProvider: { id in credentials[id.rawValue] ?? nil }
        )
    }

    func testLoadStoresInventorySortedByNamePerHost() async throws {
        let one = host("host_one", name: "Mock A")
        let two = host("host_two", name: "Mock B")
        let library = library(responses: ["project.list": json(harbourJSON)])

        // One shared stub serves both hosts here; per-host failure
        // isolation is covered separately.
        await library.load([entry(one), entry(two)])

        XCTAssertEqual(library.projectsByHost[one.id]?.map { $0.name ?? "" }, ["Alpha Tool", "Beta Tool"], "sorted by display name")
        XCTAssertEqual(library.projectsByHost[two.id]?.count, 2, "each host keeps its own inventory")
        XCTAssertNil(library.errorsByHost[one.id])
        XCTAssertNil(library.errorsByHost[two.id])
    }

    func testMissingCredentialReportsRePairWithoutAnyRequest() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library(responses: [:], credentials: [:])

        await library.load([entry(one)])

        XCTAssertEqual(library.errorsByHost[one.id], "Re-pair this host to list its projects.")
        XCTAssertTrue(library.projectsByHost.isEmpty)
    }

    func testOneHostFailureDoesNotBlankAnotherHostsInventory() async throws {
        let one = host("host_one", name: "Mock A")
        let two = host("host_two", name: "Mock B")
        // Distinct transports per host address: host_one's fails, host_two's serves.
        let failing = StubTransport(responses: [:])
        let orbit = StubTransport(responses: ["project.list": json(orbitJSON)])
        let library = ProjectsLibrary(
            service: ProjectService(makeTransport: { url in
                url.host?.contains("host_two") == true ? orbit : failing
            }),
            credentialProvider: { _ in BasicCredential(secret: "t") }
        )

        await library.load([entry(one), entry(two)])

        XCTAssertNotNil(library.errorsByHost[one.id], "the failing host reports an error")
        XCTAssertEqual(library.projectsByHost[two.id]?.first?.name, "Orbit Demo", "other inventories survive")
        XCTAssertNil(library.errorsByHost[two.id])
    }

    func testSearchFiltersByNameAndPathWithinHostFilter() async throws {
        let one = host("host_one", name: "Mock A")
        let two = host("host_two", name: "Mock B")
        let transport = StubTransport(responses: ["project.list": json(harbourJSON)])
        let orbitTransport = StubTransport(responses: ["project.list": json(orbitJSON)])
        let library = ProjectsLibrary(
            service: ProjectService(makeTransport: { url in
                url.host?.contains("host_two") == true ? orbitTransport : transport
            }),
            credentialProvider: { _ in BasicCredential(secret: "t") }
        )
        await library.load([entry(one), entry(two)])

        let byName = library.rows(entries: [entry(one), entry(two)], hostFilter: nil, search: "alpha")
        XCTAssertEqual(byName.map(\.project.id), ["project_a"], "case-insensitive name search across hosts")

        let byPath = library.rows(entries: [entry(one), entry(two)], hostFilter: nil, search: "/srv/demo/orbit")
        XCTAssertEqual(byPath.map(\.project.id), ["project_orbit"], "path search finds unlisted-name projects")

        let scoped = library.rows(entries: [entry(one), entry(two)], hostFilter: two.id, search: "demo")
        XCTAssertEqual(scoped.map(\.project.id), ["project_orbit"], "host filter scopes rows to one host")

        let excluded = library.rows(entries: [entry(one), entry(two)], hostFilter: one.id, search: "orbit")
        XCTAssertEqual(excluded.map(\.project.id), [], "matching projects on other hosts stay excluded")
    }

    func testRecentLocationsDedupeMoveToFrontAndCap() throws {
        let one = host("host_one", name: "Mock A")
        let library = library(responses: [:])

        for index in 0..<12 {
            let directory = "/srv/demo/p\(index)"
            library.noteRecent(host: one, location: ResolvedLocation(
                directory: directory,
                project: .init(id: "p\(index)", directory: directory, canonical: directory)
            ))
        }
        XCTAssertEqual(library.recentLocations.count, 10, "capped")
        XCTAssertEqual(library.recentLocations.first?.location.directory, "/srv/demo/p11", "newest first")

        library.noteRecent(host: one, location: ResolvedLocation(
            directory: "/srv/demo/p3",
            project: .init(id: "p3", directory: "/srv/demo/p3", canonical: "/srv/demo/p3")
        ))
        XCTAssertEqual(library.recentLocations.count, 10, "revisiting does not grow the list")
        XCTAssertEqual(library.recentLocations.first?.location.directory, "/srv/demo/p3", "moved to front")
    }
}
