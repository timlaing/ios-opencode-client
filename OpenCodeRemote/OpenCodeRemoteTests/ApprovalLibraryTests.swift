import XCTest
@testable import OpenCodeRemote
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W09 approval-dock tests against a canned transport: session/linked
/// reconciliation with owner preservation, honest refresh failures
/// (entries stay until the host says otherwise), and the 204 / stale
/// 404 / failed reply outcomes behind S11's settled states.
@MainActor
final class ApprovalLibraryTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [APIRequest] = []
        func record(_ request: APIRequest) { lock.lock(); recorded.append(request); lock.unlock() }
        var requests: [APIRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    /// Handler responses tests can swap mid-flight (refresh failures).
    private final class Responses: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Result<APIResponse, TransportError>]

        init(_ initial: [String: Result<APIResponse, TransportError>] = [:]) {
            storage = initial
        }

        func set(_ operation: String, _ result: Result<APIResponse, TransportError>) {
            lock.lock(); storage[operation] = result; lock.unlock()
        }

        func get(_ operation: String) -> Result<APIResponse, TransportError>? {
            lock.lock(); defer { lock.unlock() }
            return storage[operation]
        }
    }

    /// Atomic call counter — the out-of-order-load test needs to
    /// recognise its first in-flight request.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private struct StubTransport: OpenCodeTransport {
        let recorder: Recorder
        let responses: Responses
        var hook: (@Sendable (APIRequest) async -> Void)?

        func perform(_ request: APIRequest) async throws -> APIResponse {
            recorder.record(request)
            // Snapshot the response at CALL time, so a hook's delay can
            // reorder completions without changing earlier payloads.
            guard let result = responses.get(request.operationID) else {
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
            await hook?(request)
            switch result {
            case .success(let response): return response
            case .failure(let error): throw error
            }
        }

        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private let host = OpenCodeDomain.Host(
        id: HostID(rawValue: "host_one"),
        displayName: "Mock A",
        address: URL(string: "http://host_one.local:4097")!,
        createdAt: Date(timeIntervalSince1970: 0),
        lastVersion: nil
    )

    private func library(
        _ responses: Responses,
        recorder: Recorder = Recorder(),
        credential: BasicCredential? = BasicCredential(secret: "token"),
        hook: (@Sendable (APIRequest) async -> Void)? = nil
    ) -> ApprovalLibrary {
        ApprovalLibrary(
            service: PermissionService(makeTransport: { _ in
                StubTransport(recorder: recorder, responses: responses, hook: hook)
            }),
            credentialProvider: { _ in credential }
        )
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    /// The joined request items shared by both envelope shapes.
    private func itemsJSON(_ pairs: [(id: String, sessionID: String)]) -> String {
        pairs
            .map { #"{"id":"\#($0.id)","sessionID":"\#($0.sessionID)","action":"shell","resources":["python3 -m unittest"]}"# }
            .joined(separator: ",")
    }

    /// `{"data":[…]}` — the session-scoped list envelope.
    private func listJSON(_ pairs: [(id: String, sessionID: String)]) -> String {
        #"{"data":[\#(itemsJSON(pairs))]}"#
    }

    /// The location-wide located envelope: `location` rides ALONGSIDE
    /// the data array, never inside it.
    private func locatedJSON(_ pairs: [(id: String, sessionID: String)]) -> String {
        #"{"location":{"directory":"/srv/demo/harbour"},"data":[\#(itemsJSON(pairs))]}"#
    }

    private let okList = [(id: "per_own", sessionID: "ses_current")]

    // MARK: - Load

    func testLoadShowsOwnEntriesFirstThenLinkedChildren() async {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
            "permission.request.list": .success(json(locatedJSON([
                (id: "per_child", sessionID: "ses_child"),
                (id: "per_other", sessionID: "ses_elsewhere"),
            ]))),
        ])
        let library = library(responses)

        await library.load(host: host, sessionID: "ses_current", childSessionIDs: ["ses_child"])

        XCTAssertEqual(library.entries.map(\.id), ["per_own", "per_child"],
                       "own approvals lead; only ATTRIBUTED children follow")
        XCTAssertEqual(library.entries.map(\.isLinked), [false, true])
        XCTAssertNil(library.refreshError)
        XCTAssertTrue(library.hasPending)
        XCTAssertEqual(library.pendingCount, 2)
    }

    func testLoadWithoutChildAttributionSkipsTheLocationWideCall() async {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
        ])
        let recorder = Recorder()
        let library = library(responses, recorder: recorder)

        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])

        XCTAssertEqual(library.entries.map(\.id), ["per_own"])
        XCTAssertEqual(recorder.requests.map(\.operationID), ["session.permission.list"],
                       "no inventory attribution → no location-wide sweep")
    }

    func testMissingCredentialFailsHonestly() async {
        let library = library(Responses(), credential: nil)

        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])

        XCTAssertFalse(library.hasPending)
        XCTAssertEqual(library.refreshError, "Re-pair this host to check approvals.")
    }

    func testFailedRefreshKeepsEntriesAlreadyOnScreen() async {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        XCTAssertEqual(library.entries.map(\.id), ["per_own"])

        responses.set("session.permission.list", .failure(.http(status: 500, envelope: nil)))
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])

        XCTAssertEqual(library.entries.map(\.id), ["per_own"],
                       "a failed refresh never clears pending approvals")
        XCTAssertEqual(library.refreshError, "The host returned an error (HTTP 500).")
    }

    // MARK: - Submit

    private func entry(id: String = "per_own", sessionID: String = "ses_current") -> ApprovalLibrary.Entry {
        ApprovalLibrary.Entry(
            request: PermissionRequest(
                id: id, sessionID: sessionID, action: "shell",
                resources: ["python3 -m unittest"], save: ["python3 -m unittest*"]
            ),
            isLinked: sessionID != "ses_current"
        )
    }

    func testAcceptedReplyRemovesTheEntryAndPostsTheDecision() async throws {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
            "session.permission.reply": .success(APIResponse(statusCode: 204, payload: .empty)),
        ])
        let recorder = Recorder()
        let library = library(responses, recorder: recorder)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let pending = try XCTUnwrap(library.entries.first)

        let outcome = await library.submit(
            pending, decision: .once, message: nil, host: host
        )

        XCTAssertEqual(outcome, .accepted)
        XCTAssertTrue(library.entries.isEmpty)
        let request = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(request.path, "/api/session/ses_current/permission/per_own/reply")
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.body), as: UTF8.self),
                       #"{"decision":"once"}"#)
    }

    func testStaleReplySettlesAsAnsweredElsewhereNotSuccess() async throws {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
            "session.permission.reply": .failure(.http(status: 404, envelope: APIErrorEnvelope(
                tag: "PermissionNotFoundError", message: "Permission not found",
                details: ["requestID": .string("per_own")]
            ))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let pending = try XCTUnwrap(library.entries.first)

        let outcome = await library.submit(
            pending, decision: .once, message: nil, host: host
        )

        XCTAssertEqual(outcome, .answeredElsewhere)
        XCTAssertTrue(library.entries.isEmpty,
                      "the host says it is gone — the entry settles either way")
    }

    func testFailedReplyKeepsTheEntryPending() async throws {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
            "session.permission.reply": .failure(.http(status: 500, envelope: nil)),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let pending = try XCTUnwrap(library.entries.first)

        let outcome = await library.submit(
            pending, decision: .once, message: "why not", host: host
        )

        guard case .failed(let reason) = outcome else {
            return XCTFail("expected a failed outcome, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("HTTP 500"))
        XCTAssertEqual(library.entries.map(\.id), ["per_own"],
                       "an unconfirmed reply never removes a pending approval")
    }

    func testLinkedChildEntryRepliesUnderItsOwnOwnerSession() async throws {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON([]))),
            "permission.request.list": .success(json(locatedJSON([
                (id: "per_child", sessionID: "ses_child"),
            ]))),
            "session.permission.reply": .success(APIResponse(statusCode: 204, payload: .empty)),
        ])
        let recorder = Recorder()
        let library = library(responses, recorder: recorder)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: ["ses_child"])
        let linked = try XCTUnwrap(library.entries.first)

        let outcome = await library.submit(
            linked, decision: .always, message: nil, host: host
        )

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(recorder.requests.last?.path,
                       "/api/session/ses_child/permission/per_child/reply",
                       "owner IDs are preserved — the viewing session never answers in their place")
    }

    // MARK: - Refresh races (review R1)

    func testLinkedEntriesSurviveAFailedLocationWideRefresh() async {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
            "permission.request.list": .success(json(locatedJSON([
                (id: "per_child", sessionID: "ses_child"),
            ]))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: ["ses_child"])
        XCTAssertEqual(library.entries.map(\.id), ["per_own", "per_child"])

        // The location-wide call now fails: the child's approval is
        // still pending on the host, so it must not drop off the dock.
        responses.set("permission.request.list", .failure(.http(status: 500, envelope: nil)))
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: ["ses_child"])

        XCTAssertEqual(library.entries.map(\.id), ["per_own", "per_child"],
                       "a failed location-wide refresh keeps attributed child entries")
        XCTAssertEqual(library.refreshError, "The host returned an error (HTTP 500).")
    }

    func testSettledApprovalsNeverReturnFromARefresh() async throws {
        // The host's list still contains the just-answered request
        // (server lag): a refresh must not resurrect it in the dock.
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
            "session.permission.reply": .success(APIResponse(statusCode: 204, payload: .empty)),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let pending = try XCTUnwrap(library.entries.first)

        let outcome = await library.submit(pending, decision: .once, message: nil, host: host)
        XCTAssertEqual(outcome, .accepted)
        XCTAssertTrue(library.entries.isEmpty)

        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        XCTAssertTrue(library.entries.isEmpty,
                      "a settled approval never returns, whatever the list still says")
    }

    func testStaleLoadCannotOverwriteANewerOne() async {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON([
                (id: "per_old", sessionID: "ses_current"),
            ]))),
        ])
        let calls = Counter()
        let newResponse = json(listJSON([(id: "per_new", sessionID: "ses_current")]))
        // The hook signals when the FIRST call has snapshotted its
        // (stale) payload — no fixed sleeps to order the two loads.
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let library = library(responses, hook: { request in
            guard request.operationID == "session.permission.list" else { return }
            // Hold the FIRST call mid-flight: its payload was already
            // snapshotted as the stale one before the swap.
            if calls.next() == 1 {
                responses.set("session.permission.list", .success(newResponse))
                enteredContinuation.yield()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        })

        let stale = Task { [host] in
            await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        }
        // Start the newer load only once the stale one has its payload.
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])

        await stale.value
        XCTAssertEqual(library.entries.map(\.id), ["per_new"],
                       "a superseded load finishing late writes nothing")
    }

    // MARK: - Retained-attribution scope (review R2, minor)

    func testFailedLocationWideRefreshDropsFormerDescendants() async {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
            "permission.request.list": .success(json(locatedJSON([
                (id: "per_child", sessionID: "ses_child"),
            ]))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: ["ses_child"])
        XCTAssertEqual(library.entries.map(\.id), ["per_own", "per_child"])

        // The location-wide refresh fails AND the attribution changed:
        // the former descendant's approval may no longer belong to
        // this conversation's dock at all.
        responses.set("permission.request.list", .failure(.http(status: 500, envelope: nil)))
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: ["ses_grandchild"])

        XCTAssertEqual(library.entries.map(\.id), ["per_own"],
                       "entries kept through a failed sweep are filtered to CURRENT descendants")
        XCTAssertEqual(library.refreshError, "The host returned an error (HTTP 500).")
    }

    // MARK: - Post-send watch (review R2, major)

    /// Waits (bounded) for a condition the watch makes true.
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testWatchSurfacesARequestCreatedAfterTheOneOffRefresh() async {
        // The host creates the permission request only when the agent
        // reaches the guarded tool — AFTER `send` returned on
        // admission, so the one-off refresh saw an empty list.
        let responses = Responses([
            "session.permission.list": .success(json(listJSON([]))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        XCTAssertTrue(library.entries.isEmpty, "the one-off refresh is too early")

        // The request exists from the next poll on.
        responses.set("session.permission.list", .success(json(listJSON(okList))))
        library.startPostSendWatch(
            host: host, sessionID: "ses_current", childSessionIDs: [],
            attempts: 50, intervalNanoseconds: 20_000_000
        )
        await waitUntil { library.hasPending }
        library.stopPostSendWatch()

        XCTAssertEqual(library.entries.map(\.id), ["per_own"],
                       "the watch surfaces the request the one-off refresh could not see")
    }

    func testWatchEndsOnceTheRequestIsOnTheDock() async {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
        ])
        let recorder = Recorder()
        let library = library(responses, recorder: recorder)
        library.startPostSendWatch(
            host: host, sessionID: "ses_current", childSessionIDs: [],
            attempts: 100, intervalNanoseconds: 10_000_000
        )
        await waitUntil { library.hasPending }

        // The dock has it — the watch must stop polling, however long
        // the (unused) window would have run.
        let settled = recorder.requests.filter { $0.operationID == "session.permission.list" }.count
        try? await Task.sleep(nanoseconds: 100_000_000)
        library.stopPostSendWatch()
        let after = recorder.requests.filter { $0.operationID == "session.permission.list" }.count

        XCTAssertEqual(after, settled,
                       "the watch stops polling once the request is on the dock")
    }

    func testStoppingTheWatchEndsItsPolling() async {
        let responses = Responses([
            "session.permission.list": .success(json(listJSON([]))),
        ])
        let recorder = Recorder()
        let library = library(responses, recorder: recorder)
        library.startPostSendWatch(
            host: host, sessionID: "ses_current", childSessionIDs: [],
            attempts: 100, intervalNanoseconds: 10_000_000
        )
        // Stop only once a tick has demonstrably landed.
        await waitUntil { !recorder.requests.isEmpty }
        library.stopPostSendWatch()
        let settled = recorder.requests.filter { $0.operationID == "session.permission.list" }.count
        try? await Task.sleep(nanoseconds: 100_000_000)
        let after = recorder.requests.filter { $0.operationID == "session.permission.list" }.count

        XCTAssertGreaterThanOrEqual(settled, 1, "the watch polled before it was stopped")
        XCTAssertEqual(after, settled, "a dismissed view's watch polls no further")
    }

    func testAnsweringAnApprovalReopensTheWatch() async throws {
        // The turn continues after an answer and may raise the NEXT
        // request with the same admission-late timing — the reopened
        // watch must find it.
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
            "session.permission.reply": .success(APIResponse(statusCode: 204, payload: .empty)),
        ])
        let library = library(responses)
        library.startPostSendWatch(
            host: host, sessionID: "ses_current", childSessionIDs: [],
            attempts: 10, intervalNanoseconds: 10_000_000
        )
        await waitUntil { library.hasPending }
        let first = try XCTUnwrap(library.entries.first)

        // The released turn's next request — a fresh ID, so the
        // settled set must not filter it.
        responses.set("session.permission.list", .success(json(listJSON([
            (id: "per_second", sessionID: "ses_current"),
        ]))))
        let outcome = await library.submit(first, decision: .once, message: nil, host: host)
        XCTAssertEqual(outcome, .accepted)

        await waitUntil { library.entries.map(\.id) == ["per_second"] }
        library.stopPostSendWatch()
        XCTAssertEqual(library.entries.map(\.id), ["per_second"],
                       "answering reopens the watch — the turn's next request still surfaces")
    }

    func testAnsweringAPreexistingApprovalReopensTheRecordedWatch() async throws {
        // Opened onto an approval from an earlier turn (no send in
        // this view): only the load-recorded context can reopen the
        // watch on answer (review R3). Recording must NOT poll.
        let responses = Responses([
            "session.permission.list": .success(json(listJSON(okList))),
            "session.permission.reply": .success(APIResponse(statusCode: 204, payload: .empty)),
        ])
        let recorder = Recorder()
        let library = library(responses, recorder: recorder)
        library.recordWatchContext(
            host: host, sessionID: "ses_current", childSessionIDs: [],
            attempts: 10, intervalNanoseconds: 10_000_000
        )
        XCTAssertTrue(recorder.requests.isEmpty, "recording the context polls nothing")

        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let first = try XCTUnwrap(library.entries.first)

        // The released turn's next request — the same admission-late
        // timing as a sent prompt's, but no send started a watch.
        responses.set("session.permission.list", .success(json(listJSON([
            (id: "per_next", sessionID: "ses_current"),
        ]))))
        let outcome = await library.submit(first, decision: .once, message: nil, host: host)
        XCTAssertEqual(outcome, .accepted)

        await waitUntil { library.entries.map(\.id) == ["per_next"] }
        library.stopPostSendWatch()
        XCTAssertEqual(library.entries.map(\.id), ["per_next"],
                       "an answer without a prior send reopens the load-recorded watch")
    }
}
