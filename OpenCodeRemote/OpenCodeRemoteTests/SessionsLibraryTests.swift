import XCTest
import OpenCodeDomain
import OpenCodeTransport
@testable import OpenCodeRemote

/// S07 inventory tests (docs/navigation-screens.md S07, docs/api-contract.md
/// W03): per-host loading with active probing, server title search kept
/// separate from the inventory, scope/hidden/marker row rules, opaque
/// cursor paging, and mutations that only touch local state after the
/// server confirms.
@MainActor
final class SessionsLibraryTests: XCTestCase {
    /// Non-isolated fixtures: transport handlers run off the main actor.
    private enum Fixtures {
        static func response(_ body: String, status: Int = 200) -> APIResponse {
            APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
        }

        static func empty(_ status: Int = 204) -> APIResponse {
            APIResponse(statusCode: status, payload: .empty)
        }

        /// `time.updated` is 1000 with no `viewed` — unread until acknowledged.
        static func session(
            _ id: String,
            project: String = "project_harbour",
            title: String = "A session",
            outcome: String? = nil,
            parentID: String? = nil
        ) -> String {
            // Note: `""#` — the first `"` is content (closing the JSON
            // value); the second `"` + `#` closes the raw string.
            let outcomeJSON = outcome.map { #", "outcome":"\#($0)""# } ?? ""
            let parentJSON = parentID.map { #", "parentID":"\#($0)""# } ?? ""
            return #"{"id":"\#(id)","projectID":"\#(project)","title":"\#(title)"\#(outcomeJSON)\#(parentJSON),"cost":0.01,"tokens":{"input":10,"output":5,"reasoning":0},"time":{"created":900,"updated":1000},"location":{"directory":"/srv/demo/harbour"}}"#
        }

        static func page(_ sessions: [String], next: String? = nil) -> String {
            let cursor = next.map { #", "cursor":{"next":"\#($0)"}"# } ?? ""
            return #"{"data":[\#(sessions.joined(separator: ","))]\#(cursor)}"#
        }

        static let activeJSON = #"{"data":{"ses_a":{"type":"running"}}}"#

        static func query(_ request: APIRequest) -> [String: String] {
            Dictionary(uniqueKeysWithValues: request.query.map { ($0.key, $0.value) })
        }
    }

    /// Captured-var mutation is not allowed in `@Sendable` handlers.
    private final class Flag: @unchecked Sendable {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private final class RecordedIdle: @unchecked Sendable {
        var value: Int64?
    }

    private struct StubTransport: OpenCodeTransport {
        var handler: @Sendable (APIRequest) throws -> APIResponse

        func perform(_ request: APIRequest) async throws -> APIResponse {
            try handler(request)
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

    private func library(
        handler: @escaping @Sendable (APIRequest) throws -> APIResponse,
        credentials: [String: BasicCredential?] = ["host_one": BasicCredential(secret: "t")],
        defaults: UserDefaults? = nil
    ) -> SessionsLibrary {
        SessionsLibrary(
            service: SessionService(makeTransport: { _ in StubTransport(handler: handler) }),
            credentialProvider: { id in credentials[id.rawValue] ?? nil },
            localState: defaults.map { SessionLocalStateStore(defaults: $0) }
        )
    }

    private var freshDefaults: UserDefaults {
        let suite = "SessionsLibraryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Loading

    func testLoadStoresInventoryAndRunningSet() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library { request in
            switch request.operationID {
            case "session.list":
                return Fixtures.response(Fixtures.page([
                    Fixtures.session("ses_a"),
                    Fixtures.session("ses_b", project: "project_orbit", title: "Second"),
                ]))
            case "session.active":
                return Fixtures.response(Fixtures.activeJSON)
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load([entry(one)])

        XCTAssertEqual(library.sessionsByHost[one.id]?.map(\.id), ["ses_a", "ses_b"], "server order preserved")
        XCTAssertEqual(library.activeByHost[one.id], ["ses_a"])
        XCTAssertNil(library.errorsByHost[one.id])
        XCTAssertEqual(library.hasMoreByHost[one.id], false, "no cursor -> no further page")
    }

    func testActiveProbeFailureKeepsInventoryVisible() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library { request in
            switch request.operationID {
            case "session.list":
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")]))
            case "session.active":
                throw TransportError.connectionFailed("active down")
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load([entry(one)])

        XCTAssertEqual(library.sessionsByHost[one.id]?.count, 1, "display-only probe never blanks the inventory")
        XCTAssertEqual(library.activeByHost[one.id], [], "degrades to no markers")
        XCTAssertNil(library.errorsByHost[one.id])
    }

    func testMissingCredentialReportsRePairInsteadOfSilence() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library(handler: { _ in
            XCTFail("no request should be sent")
            throw TransportError.connectionFailed("should not run")
        }, credentials: [:])

        await library.load([entry(one)])

        XCTAssertEqual(library.errorsByHost[one.id], "Re-pair this host to list its sessions.")
        XCTAssertNil(library.sessionsByHost[one.id])
    }

    func testServerErrorSurfacesHTTPStatus() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library { request in
            if request.operationID == "session.list" {
                throw TransportError.http(status: 503, envelope: nil)
            }
            throw TransportError.connectionFailed("unstubbed \(request.operationID)")
        }

        await library.load([entry(one)])

        XCTAssertEqual(library.errorsByHost[one.id], "The host could not list sessions (HTTP 503).")
    }

    func testServerTitleSearchIsSeparateAndClearingRestoresInventory() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library { request in
            if request.query.contains(where: { $0.key == "search" }) {
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_match", title: "Deployment target")]))
            }
            return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")]))
        }

        await library.load([entry(one)])
        await library.search("deployment", entries: [entry(one)])

        XCTAssertEqual(library.activeSearch, "deployment")
        XCTAssertEqual(library.searchResultsByHost[one.id]?.map(\.id), ["ses_match"])
        XCTAssertEqual(library.sessionsByHost[one.id]?.map(\.id), ["ses_a"], "inventory untouched by search")

        await library.search("   ", entries: [entry(one)])
        XCTAssertNil(library.activeSearch, "clearing restores the unfiltered inventory")
        XCTAssertTrue(library.searchResultsByHost.isEmpty)
    }

    // MARK: - Rows, scopes, markers

    func testRowsApplyProjectScopeHiddenFilterAndMarkers() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library(handler: { request in
            switch request.operationID {
            case "session.list":
                return Fixtures.response(Fixtures.page([
                    Fixtures.session("ses_a", title: "Failed execution", outcome: "failed"),
                    Fixtures.session("ses_b", project: "project_orbit", title: "Orbit work"),
                ]))
            case "session.active":
                return Fixtures.response(Fixtures.activeJSON)
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }, defaults: freshDefaults)

        await library.load([entry(one)])

        let scoped = library.rows(entries: [entry(one)], hostFilter: nil, projectFilter: "project_harbour", hiddenFilter: false)
        XCTAssertEqual(scoped.map { $0.session.id }, ["ses_a"], "project scope narrows rows")
        XCTAssertEqual(scoped.first?.running, true, "active probing marks running")
        XCTAssertEqual(scoped.first?.needsAttention, true, "failed outcome needs attention")
        XCTAssertEqual(scoped.first?.unread, true, "no viewed epoch yet")

        let everything = library.rows(entries: [entry(one)], hostFilter: nil, projectFilter: nil, hiddenFilter: false)
        XCTAssertEqual(everything.count, 2)

        library.localState.toggleHidden(SessionKey(hostID: one.id, sessionID: "ses_b"))
        let hiddenOnly = library.rows(entries: [entry(one)], hostFilter: nil, projectFilter: nil, hiddenFilter: true)
        XCTAssertEqual(hiddenOnly.map { $0.session.id }, ["ses_b"], "hidden filter shows ONLY hidden sessions")
        XCTAssertEqual(hiddenOnly.first?.hidden, true)
        XCTAssertEqual(hiddenOnly.first?.unread, false, "hidden rows are not surfaced as unread")
    }

    func testVisibleErrorsKeyHostStatusToTheFilter() async throws {
        let one = host("host_one", name: "Mock A")
        let two = host("host_two", name: "Mock B")
        let library = library { request in
            if request.operationID == "session.list" {
                throw TransportError.connectionFailed("down")
            }
            throw TransportError.connectionFailed("unstubbed \(request.operationID)")
        }
        await library.load([entry(one)])

        XCTAssertEqual(library.visibleErrors(entries: [entry(one), entry(two)], hostFilter: nil).map(\.id), [one.id])
        XCTAssertEqual(
            library.visibleErrors(entries: [entry(one), entry(two)], hostFilter: two.id).map(\.id),
            [],
            "the filtered scope hides other hosts' errors"
        )
    }

    // MARK: - Paging

    func testLoadMoreAppendsTheNextOpaqueCursorPage() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library { request in
            if Fixtures.query(request)["cursor"] == "opaque-1" {
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_page2")]))
            }
            return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")], next: "opaque-1"))
        }

        await library.load([entry(one)])
        XCTAssertEqual(library.hasMoreByHost[one.id], true)

        await library.loadMore(host: one)
        XCTAssertEqual(library.sessionsByHost[one.id]?.map(\.id), ["ses_a", "ses_page2"], "pages append in order")
        XCTAssertFalse(library.hasMoreByHost[one.id] ?? true, "second page had no further cursor")
    }

    // MARK: - Mutations

    func testRenameUpdatesLocalTitleOnlyAfterServerAccepts() async throws {
        let one = host("host_one", name: "Mock A")
        let reject = Flag(false)
        let library = library { request in
            switch request.operationID {
            case "session.list":
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")]))
            case "session.active":
                return Fixtures.response(Fixtures.activeJSON)
            case "session.update":
                if reject.value { throw TransportError.http(status: 409, envelope: nil) }
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load([entry(one)])

        try await library.rename(host: one, sessionID: "ses_a", title: "Renamed")
        XCTAssertEqual(library.sessionsByHost[one.id]?.first?.title, "Renamed")

        reject.value = true
        do {
            try await library.rename(host: one, sessionID: "ses_a", title: "Should not stick")
            XCTFail("expected rejection")
        } catch let TransportError.http(status, _) {
            XCTAssertEqual(status, 409)
        }
        XCTAssertEqual(library.sessionsByHost[one.id]?.first?.title, "Renamed", "local state only moves on server success")
    }

    func testMarkViewedPostsServerEpochAndReflectsItLocally() async throws {
        let one = host("host_one", name: "Mock A")
        let posted = RecordedIdle()
        let library = library { request in
            switch request.operationID {
            case "session.list":
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")]))
            case "session.active":
                return Fixtures.response(Fixtures.activeJSON)
            case "session.view":
                let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
                posted.value = (body?["idle"] as? NSNumber)?.int64Value
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load([entry(one)])
        let loaded = try XCTUnwrap(library.sessionsByHost[one.id]?.first)
        XCTAssertTrue(loaded.isUnread)

        await library.markViewed(host: one, session: loaded)

        XCTAssertEqual(posted.value, 1000, "server-observed time.updated, never the phone clock")
        XCTAssertEqual(library.sessionsByHost[one.id]?.first?.time?.viewed, 1000)
        XCTAssertFalse(library.sessionsByHost[one.id]?.first?.isUnread ?? true)
    }

    func testMarkViewedWithoutAnyObservedTimeSendsNothing() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library { request in
            switch request.operationID {
            case "session.list":
                return Fixtures.response(#"{"data":[{"id":"ses_bare","projectID":"p","cost":0,"tokens":{},"location":{"directory":"/x"}}]}"#)
            case "session.active":
                return Fixtures.response(#"{"data":{}}"#)
            case "session.view":
                XCTFail("no honest epoch exists; nothing may be sent")
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load([entry(one)])
        let bare = try XCTUnwrap(library.sessionsByHost[one.id]?.first)
        await library.markViewed(host: one, session: bare)
        XCTAssertNil(library.sessionsByHost[one.id]?.first?.time?.viewed, "left untouched")
    }

    func testCreateInsertsAndRemoveDropsOnlyAfter204() async throws {
        let one = host("host_one", name: "Mock A")
        let reject = Flag(false)
        let library = library { request in
            switch request.operationID {
            case "session.list":
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")]))
            case "session.active":
                return Fixtures.response(Fixtures.activeJSON)
            case "session.create":
                return Fixtures.response(#"{"data":\#(Fixtures.session("ses_new", title: "Telescope"))}"#)
            case "session.remove":
                if reject.value { throw TransportError.http(status: 500, envelope: nil) }
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load([entry(one)])

        let created = try await library.create(host: one, directory: "/Telescope", title: "Telescope")
        XCTAssertEqual(created.id, "ses_new")
        XCTAssertEqual(library.sessionsByHost[one.id]?.map(\.id), ["ses_new", "ses_a"], "newest first")

        reject.value = true
        do {
            try await library.remove(host: one, sessionID: "ses_a")
            XCTFail("expected rejection")
        } catch {}
        XCTAssertEqual(library.sessionsByHost[one.id]?.count, 2, "failed delete never drops the row")

        reject.value = false
        try await library.remove(host: one, sessionID: "ses_a")
        XCTAssertEqual(library.sessionsByHost[one.id]?.map(\.id), ["ses_new"])
    }

    // MARK: - Local state

    func testFollowedSessionIDsFlowFromLocalState() async throws {
        let library = library { _ in
            XCTFail("no server calls")
            throw TransportError.connectionFailed("should not run")
        }
        let key = SessionKey(hostID: HostID(rawValue: "host_one"), sessionID: "ses_a")

        XCTAssertTrue(library.localState.toggleFollowed(key))
        XCTAssertEqual(library.followedSessionIDs, ["ses_a"], "feeds the push payload's followedSessions")
        XCTAssertFalse(library.localState.toggleFollowed(key))
        XCTAssertTrue(library.followedSessionIDs.isEmpty)
    }
}
