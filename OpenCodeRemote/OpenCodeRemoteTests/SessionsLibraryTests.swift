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

    func testFailedHostSearchClearsPreviousTermResults() async throws {
        let one = host("host_one", name: "Mock A")
        let failNext = Flag(false)
        let library = library { request in
            if request.query.contains(where: { $0.key == "search" }) {
                if failNext.value { throw TransportError.http(status: 500, envelope: nil) }
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_match", title: "Deployment target")]))
            }
            return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")]))
        }
        await library.load([entry(one)])
        await library.search("deployment", entries: [entry(one)])
        XCTAssertEqual(library.searchResultsByHost[one.id]?.count, 1)

        failNext.value = true
        await library.search("gone", entries: [entry(one)])

        XCTAssertEqual(library.activeSearch, "gone")
        XCTAssertNil(library.searchResultsByHost[one.id], "a failed host keeps no stale results from the previous term")
        XCTAssertNil(library.errorsByHost[one.id], "a search failure is never a listing failure")
        XCTAssertNotNil(library.searchErrorsByHost[one.id], "the failure is surfaced as a search error")
    }

    func testSearchFailuresNeverPolluteTheListingErrorMap() async throws {
        let one = host("host_one", name: "Mock A")
        let failSearch = Flag(false)
        let library = library { request in
            if request.query.contains(where: { $0.key == "search" }) {
                if failSearch.value { throw TransportError.http(status: 500, envelope: nil) }
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_match")]))
            }
            return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")]))
        }
        await library.load([entry(one)])
        XCTAssertNil(library.errorsByHost[one.id])

        failSearch.value = true
        await library.search("deployment", entries: [entry(one)])

        XCTAssertNil(library.errorsByHost[one.id],
                     "a failed title search must not claim the host could not list sessions")
        XCTAssertEqual(library.searchErrorsByHost[one.id], "The host could not search sessions (HTTP 500).",
                       "search wording, not the listing wording")
        XCTAssertEqual(
            library.visibleErrors(entries: [entry(one)], hostFilter: nil).map { $0.message },
            ["The host could not search sessions (HTTP 500)."]
        )

        await library.search("   ", entries: [entry(one)])
        XCTAssertTrue(library.searchErrorsByHost.isEmpty, "clearing the term clears the search failures")
        XCTAssertTrue(library.visibleErrors(entries: [entry(one)], hostFilter: nil).isEmpty,
                      "no false Host Status survives the cleared search")
    }

    func testSearchSuccessKeepsARealListingFailureVisible() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library { request in
            if request.query.contains(where: { $0.key == "search" }) {
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_match")]))
            }
            throw TransportError.http(status: 503, envelope: nil)
        }
        await library.load([entry(one)])
        XCTAssertEqual(library.errorsByHost[one.id], "The host could not list sessions (HTTP 503).")

        await library.search("deployment", entries: [entry(one)])

        XCTAssertEqual(library.searchResultsByHost[one.id]?.map(\.id), ["ses_match"])
        XCTAssertEqual(library.errorsByHost[one.id], "The host could not list sessions (HTTP 503).",
                       "a successful search is no evidence the inventory exists")
        XCTAssertNil(library.searchErrorsByHost[one.id])
    }

    func testSearchWithoutCredentialClearsStaleResultsAndReportsRePair() async throws {
        let one = host("host_one", name: "Mock A")
        let two = host("host_two", name: "Mock B")
        // Credentials are late-bound, so the test can drop ONE host's
        // between searches the way a Keychain eviction or credential
        // deletion would — the other host stays paired throughout.
        let twoPaired = Flag(true)
        let library = SessionsLibrary(
            service: SessionService(makeTransport: { _ in StubTransport(handler: { request in
                if request.query.contains(where: { $0.key == "search" }) {
                    return Fixtures.response(Fixtures.page([Fixtures.session("ses_match")]))
                }
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")]))
            }) }),
            credentialProvider: { id in
                (id == two.id && !twoPaired.value) ? nil : BasicCredential(secret: "t")
            }
        )

        await library.search("deployment", entries: [entry(one), entry(two)])
        XCTAssertEqual(library.searchResultsByHost[one.id]?.count, 1)
        XCTAssertEqual(library.searchResultsByHost[two.id]?.count, 1, "both hosts hold the first term")

        twoPaired.value = false
        await library.search("gone", entries: [entry(one), entry(two)])

        XCTAssertNil(library.searchResultsByHost[two.id],
                     "a credential-less host keeps no previous term's rows under the new activeSearch")
        XCTAssertEqual(library.searchErrorsByHost[two.id], "Re-pair this host to search its sessions.",
                       "the actual cause is recorded — never a silent skip")
        XCTAssertEqual(library.searchResultsByHost[one.id]?.count, 1,
                       "the still-paired host searches the new term normally")
        XCTAssertNil(library.searchErrorsByHost[one.id])
    }

    func testSearchRunsHostsInParallel() async throws {
        let one = host("host_one", name: "Mock A")
        let two = host("host_two", name: "Mock B")
        let releaseSlow = DispatchSemaphore(value: 0)
        let library = library(
            handler: { request in
                if request.query.contains(where: { $0.key == "search" }) {
                    // host_one's credential rides on the request: block ONLY
                    // its search until the test releases it (the shared
                    // session's real 60 s timeout stands in for the
                    // semaphore in production).
                    if request.credential?.secret == "s1" {
                        _ = releaseSlow.wait(timeout: .now() + 10)
                    }
                    return Fixtures.response(Fixtures.page([Fixtures.session("ses_match")]))
                }
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            },
            credentials: [
                "host_one": BasicCredential(secret: "s1"),
                "host_two": BasicCredential(secret: "s2"),
            ]
        )

        let searching = Task { await library.search("deployment", entries: [entry(one), entry(two)]) }

        // host_one is the FIRST entry and still blocked mid-request: a
        // sequential search would never even ask host_two until the slow
        // host gave up. Only a parallel structure produces host_two's
        // results by now.
        for _ in 0..<10_000 where library.searchResultsByHost[two.id] == nil {
            await Task.yield()
        }
        XCTAssertNotNil(library.searchResultsByHost[two.id],
                        "the second host's results arrive while the first host is still in flight")
        XCTAssertNil(library.searchResultsByHost[one.id], "the blocked host has not written yet")

        releaseSlow.signal()
        await searching.value
        XCTAssertEqual(library.searchResultsByHost[one.id]?.count, 1)
        XCTAssertEqual(library.searchResultsByHost[two.id]?.count, 1)
        XCTAssertTrue(library.searchErrorsByHost.isEmpty, "no host failed")
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

    func testLoadMoreFailureIsNotAListingFailure() async throws {
        let one = host("host_one", name: "Mock A")
        let failMore = Flag(false)
        let library = library { request in
            if Fixtures.query(request)["cursor"] == "opaque-1" {
                if failMore.value { throw TransportError.http(status: 500, envelope: nil) }
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_page2")]))
            }
            return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")], next: "opaque-1"))
        }
        await library.load([entry(one)])
        XCTAssertNil(library.errorsByHost[one.id])

        failMore.value = true
        await library.loadMore(host: one)

        XCTAssertNil(library.errorsByHost[one.id],
                     "page one is on screen — a failed NEXT page must not claim the listing failed")
        XCTAssertTrue(library.visibleErrors(entries: [entry(one)], hostFilter: nil).isEmpty,
                      "no false Host Status row for a failed next-page fetch")
        XCTAssertEqual(library.loadMoreErrorsByHost[one.id], "The host could not load more sessions (HTTP 500).",
                       "the paging failure surfaces at Load More in paging wording")
        XCTAssertEqual(library.sessionsByHost[one.id]?.map(\.id), ["ses_a"],
                       "the listed inventory is untouched by the paging failure")

        // A fresh listing supersedes the paging failure.
        failMore.value = false
        await library.load(host: one)
        XCTAssertNil(library.loadMoreErrorsByHost[one.id], "reload clears the stale paging error")
    }

    func testRefreshSingleFlightsAgainstLoadMoreThroughTheLoadingFlag() async throws {
        let one = host("host_one", name: "Mock A")
        let blockRefresh = Flag(false)
        let refreshInFetch = Flag(false)
        let releaseFetch = DispatchSemaphore(value: 0)
        let cursorRequested = Flag(false)
        let library = library { request in
            if Fixtures.query(request)["cursor"] != nil {
                cursorRequested.value = true
                return Fixtures.response(Fixtures.page([Fixtures.session("ses_page2")]))
            }
            if blockRefresh.value, !refreshInFetch.value {
                refreshInFetch.value = true
                blockRefresh.value = false
                _ = releaseFetch.wait(timeout: .now() + 5)
            }
            return Fixtures.response(Fixtures.page([Fixtures.session("ses_a")], next: "opaque-1"))
        }

        // Establish hasMore, so loadMore's CURSOR precondition passes and
        // only the loadingHosts flag can make it defer below.
        await library.load([entry(one)])
        XCTAssertEqual(library.hasMoreByHost[one.id], true)
        XCTAssertTrue(library.loadingHosts.isEmpty)

        // A refresh in flight: blocked inside its page-one fetch, holding
        // the single-flight flag (this is what load(_:) adds and the
        // refreshable path previously skipped by calling load(host:)).
        blockRefresh.value = true
        let refresh = Task { await library.load([entry(one)]) }
        for _ in 0..<10_000 where !refreshInFetch.value { await Task.yield() }
        XCTAssertTrue(refreshInFetch.value, "the refresh reached its fetch")
        XCTAssertEqual(library.loadingHosts, [one.id], "load(_:) brackets the load with the flag")

        // A Load More arriving now must defer — running it would append an
        // old-cursor page over (or under) the page-one replacement.
        await library.loadMore(host: one)
        XCTAssertFalse(cursorRequested.value,
                       "loadMore defers to the in-flight refresh instead of racing it")

        releaseFetch.signal()
        await refresh.value
        XCTAssertTrue(library.loadingHosts.isEmpty, "the flag drops when the load finishes")
        XCTAssertEqual(library.sessionsByHost[one.id]?.map(\.id), ["ses_a"], "the refresh result stands alone")
        XCTAssertFalse(cursorRequested.value, "the interleaved page was never requested")
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

    func testRemoveDropsDescendantsWithTheParent() async throws {
        let one = host("host_one", name: "Mock A")
        let library = library { request in
            switch request.operationID {
            case "session.list":
                return Fixtures.response(Fixtures.page([
                    Fixtures.session("ses_p", title: "Parent"),
                    Fixtures.session("ses_c", title: "Child", parentID: "ses_p"),
                    Fixtures.session("ses_g", title: "Grandchild", parentID: "ses_c"),
                    Fixtures.session("ses_other", title: "Unrelated"),
                ]))
            case "session.active":
                return Fixtures.response(#"{"data":{}}"#)
            case "session.remove":
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load([entry(one)])

        try await library.remove(host: one, sessionID: "ses_p")

        XCTAssertEqual(
            library.sessionsByHost[one.id]?.map(\.id), ["ses_other"],
            "the server deletes children with the parent — nested descendants drop too"
        )
    }

    // MARK: - Local state

    func testFollowedSessionIDsFlowFromLocalState() async throws {
        // Isolated defaults: the test bundle runs inside the app host, so
        // .standard would carry every follow the app has ever saved on this
        // simulator into the exact-equality assertions below.
        let library = library(handler: { _ in
            XCTFail("no server calls")
            throw TransportError.connectionFailed("should not run")
        }, defaults: freshDefaults)
        let key = SessionKey(hostID: HostID(rawValue: "host_one"), sessionID: "ses_a")

        XCTAssertTrue(library.localState.toggleFollowed(key))
        XCTAssertEqual(library.followedSessionIDs, ["ses_a"], "feeds the push payload's followedSessions")
        XCTAssertFalse(library.localState.toggleFollowed(key))
        XCTAssertTrue(library.followedSessionIDs.isEmpty)
    }
}
