import XCTest
@testable import OpenCodeRemote
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W10 question-dock tests against a canned transport: session/linked
/// reconciliation with owner preservation, distinct 204 / 409 / 404 /
/// 400 outcomes behind S12's settled states, and the bounded post-send
/// watch with the same hardening S11's went through (R2–R4): a
/// pre-existing question never ends the window, a cancelled caller
/// publishes nothing, and a dismissed watch is not revived by an
/// in-flight answer.
@MainActor
final class FormLibraryTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [APIRequest] = []
        func record(_ request: APIRequest) { lock.lock(); recorded.append(request); lock.unlock() }
        var requests: [APIRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    /// Handler responses tests can swap mid-flight (watch surfacing,
    /// refresh failures).
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

    /// Atomic call counter — race tests recognise their in-flight
    /// request by call number instead of sleeping.
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
    ) -> FormLibrary {
        FormLibrary(
            service: FormService(makeTransport: { _ in
                StubTransport(recorder: recorder, responses: responses, hook: hook)
            }),
            credentialProvider: { _ in credential }
        )
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    private func noContent() -> APIResponse {
        APIResponse(statusCode: 204, payload: .empty)
    }

    /// The joined form items shared by both envelope shapes — one
    /// boolean field is enough for every dock test.
    private func itemsJSON(_ pairs: [(id: String, sessionID: String)]) -> String {
        pairs
            .map { #"{"id":"\#($0.id)","sessionID":"\#($0.sessionID)","title":"Question","fields":[{"key":"ok","type":"boolean"}]}"# }
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

    private let ownList = [(id: "frm_own", sessionID: "ses_current")]

    // MARK: - Reconciliation

    func testLoadShowsOwnFormsFirstThenLinkedChildren() async {
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
            "form.list": .success(json(locatedJSON([
                (id: "frm_child", sessionID: "ses_child"),
                (id: "frm_other", sessionID: "ses_elsewhere"),
            ]))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: ["ses_child"])

        XCTAssertEqual(library.entries.map(\.id), ["frm_own", "frm_child"],
                       "own first, then attributed descendants — never an unattributable form")
        XCTAssertEqual(library.entries[0].isLinked, false)
        XCTAssertEqual(library.entries[1].isLinked, true)
        XCTAssertEqual(library.entries[1].ownerSessionID, "ses_child",
                       "the owner ID on a linked entry stays the child's — attribution is by filtering, not rewriting")
        XCTAssertNil(library.refreshError)
    }

    func testFailedLocationWideSweepKeepsOnlyCurrentDescendants() async {
        let responses = Responses([
            "session.form.list": .success(json(listJSON([]))),
            "form.list": .success(json(locatedJSON([
                (id: "frm_child", sessionID: "ses_child"),
                (id: "frm_former", sessionID: "ses_former"),
            ]))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current",
                           childSessionIDs: ["ses_child", "ses_former"])
        XCTAssertEqual(Set(library.entries.map(\.id)), ["frm_child", "frm_former"])

        // The owner left the subtree and the sweep now fails: the kept
        // entries must be scoped to what is CURRENTLY known — and the
        // failure stays visible while nothing is dropped silently.
        responses.set("form.list", .failure(.http(status: 500, envelope: nil)))
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: ["ses_child"])

        XCTAssertEqual(library.entries.map(\.id), ["frm_child"],
                       "an owner that left the subtree must not linger in this dock")
        XCTAssertEqual(library.refreshError, "The host returned an error (HTTP 500).")
    }

    // MARK: - Submission outcomes

    func testAcceptedReplySettlesAndARestartCannotResurrectIt() async throws {
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
            "session.form.reply": .success(noContent()),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let entry = try XCTUnwrap(library.entries.first)

        let outcome = await library.submit(entry, answer: ["ok": .boolean(true)], host: host)

        XCTAssertEqual(outcome, .accepted, "204 is authoritative — the entry settles locally")
        XCTAssertTrue(library.entries.isEmpty)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        XCTAssertTrue(library.entries.isEmpty, "a settled form never returns to the dock")
    }

    func testAlreadySettledReplySettlesTheEntry() async throws {
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
            "session.form.reply": .failure(.http(status: 409, envelope: nil)),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let entry = try XCTUnwrap(library.entries.first)

        let outcome = await library.submit(entry, answer: ["ok": .boolean(true)], host: host)

        XCTAssertEqual(outcome, .alreadySettled,
                       "409 settles — the host's state is authoritative, and local input is never claimed as submitted")
        XCTAssertTrue(library.entries.isEmpty)
    }

    func testGoneReplySettlesTheEntry() async throws {
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
            "session.form.reply": .failure(.http(status: 404, envelope: nil)),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let entry = try XCTUnwrap(library.entries.first)

        let outcome = await library.submit(entry, answer: ["ok": .boolean(true)], host: host)

        XCTAssertEqual(outcome, .gone)
        XCTAssertTrue(library.entries.isEmpty, "a form the host no longer has must not linger")
    }

    func testRejectedAnswerKeepsTheEntryAndSurfacesTheHostMessage() async throws {
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
            "session.form.reply": .failure(.http(status: 400, envelope: APIErrorEnvelope(
                tag: "FormInvalidAnswerError",
                message: "Answer fails synthetic field validation",
                details: ["id": .string("frm_own")]
            ))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let entry = try XCTUnwrap(library.entries.first)

        let outcome = await library.submit(entry, answer: ["ok": .boolean(true)], host: host)

        XCTAssertEqual(outcome, .failed("Answer fails synthetic field validation"),
                       "the host's rejection message is what the field-level UI shows")
        XCTAssertEqual(library.entries.map(\.id), ["frm_own"],
                       "a rejected answer keeps the entry (and the draft it validates) on screen")
    }

    func testPlain400IsNeverClaimedAsAValidationMessage() async throws {
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
            "session.form.reply": .failure(.http(status: 400, envelope: APIErrorEnvelope(
                tag: "InvalidRequestError",
                message: "malformed request"
            ))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let entry = try XCTUnwrap(library.entries.first)

        let outcome = await library.submit(entry, answer: [:], host: host)

        XCTAssertEqual(outcome, .failed("The host returned an error (HTTP 400)."),
                       "only FormInvalidAnswerError maps to a validation message — any other 400 stays a transport error")
    }

    func testLinkedFormsReplyUnderTheirOwnerSession() async {
        let responses = Responses([
            "session.form.list": .success(json(listJSON([]))),
            "form.list": .success(json(locatedJSON([
                (id: "frm_child", sessionID: "ses_child"),
            ]))),
            "session.form.reply": .success(noContent()),
        ])
        let recorder = Recorder()
        let library = library(responses, recorder: recorder)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: ["ses_child"])
        guard let linked = library.entries.first else {
            return XCTFail("the linked form loads")
        }
        XCTAssertTrue(linked.isLinked)

        let outcome = await library.submit(linked, answer: ["ok": .boolean(true)], host: host)
        XCTAssertEqual(outcome, .accepted)

        let reply = recorder.requests.first { $0.operationID == "session.form.reply" }
        XCTAssertEqual(reply?.path, "/api/session/ses_child/form/frm_child/reply",
                       "linked forms reply under their OWN owner session, never the viewer's")
    }

    func testCancelCarriesTheMessageAndSettlesOn204() async throws {
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
            "session.form.cancel": .success(noContent()),
        ])
        let recorder = Recorder()
        let library = library(responses, recorder: recorder)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let entry = try XCTUnwrap(library.entries.first)

        let outcome = await library.cancel(entry, message: "not now", host: host)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertTrue(library.entries.isEmpty)
        let request = try XCTUnwrap(recorder.requests.first { $0.operationID == "session.form.cancel" })
        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.path, "/api/session/ses_current/form/frm_own")
        XCTAssertEqual(request.query, [QueryPair(key: "message", value: "not now")],
                       "the user's optional message rides the query")
        XCTAssertNil(request.body, "cancellation carries no payload")
    }

    func testAlreadySettledCancelSettlesTheEntry() async throws {
        // DELETE carries FormAlreadySettledError in the pinned contract:
        // cancelling a form answered/cancelled elsewhere must settle it
        // with its own outcome — never a generic failure that leaves the
        // entry sitting editable in the dock.
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
            "session.form.cancel": .failure(.http(status: 409, envelope: nil)),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let entry = try XCTUnwrap(library.entries.first)

        let outcome = await library.cancel(entry, message: nil, host: host)

        XCTAssertEqual(outcome, .alreadySettled)
        XCTAssertTrue(library.entries.isEmpty,
                      "a form settled elsewhere must not linger as pending")
    }

    // MARK: - Detail re-read

    func testDetailReadsTheOwnerFormAndMapsGone() async {
        let detailJSON = #"{"data":{"id":"frm_own","sessionID":"ses_child","title":"Question","state":{"status":"pending"},"fields":[{"key":"ok","type":"boolean"}]}}"#
        let responses = Responses([
            "session.form.get": .success(json(detailJSON)),
        ])
        let recorder = Recorder()
        let library = library(responses, recorder: recorder)

        let outcome = await library.detail(host: host, sessionID: "ses_child", formID: "frm_own")
        guard case .loaded(let detail) = outcome else {
            return XCTFail("the detail loads")
        }
        XCTAssertEqual(detail.state, .pending)
        XCTAssertEqual(recorder.requests.first?.path, "/api/session/ses_child/form/frm_own",
                       "the detail targets the OWNER session — plain string, no prefix rule")

        responses.set("session.form.get", .failure(.http(status: 404, envelope: nil)))
        let gone = await library.detail(host: host, sessionID: "ses_child", formID: "frm_gone")
        XCTAssertEqual(gone, .gone, "a stale 404 maps to .gone — the sheet shows the settled state")
    }

    func testSettleGoneDropsTheDockEntryPermanently() async {
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        XCTAssertEqual(library.entries.map(\.id), ["frm_own"])

        library.settleGone("frm_own")
        XCTAssertTrue(library.entries.isEmpty)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        XCTAssertTrue(library.entries.isEmpty,
                      "a form the sheet found gone never returns to the dock")
    }

    // MARK: - Post-send watch

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

    func testWatchSurfacesAFormCreatedAfterTheOneOffRefresh() async {
        // The host raises the form only when the agent decides to ask —
        // AFTER `send` returned on durable admission, so the one-off
        // refresh saw an empty list.
        let responses = Responses([
            "session.form.list": .success(json(listJSON([]))),
        ])
        let library = library(responses)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        XCTAssertTrue(library.entries.isEmpty, "the one-off refresh is routinely too early")

        responses.set("session.form.list", .success(json(listJSON(ownList))))
        library.startPostSendWatch(host: host, sessionID: "ses_current",
                                   childSessionIDs: [],
                                   attempts: 10, intervalNanoseconds: 10_000_000)
        await waitUntil { library.hasPending }
        library.stopPostSendWatch()
        XCTAssertEqual(library.entries.map(\.id), ["frm_own"],
                       "the raised question surfaces within the window")
    }

    func testWatchKeepsWatchingWhileAnEarlierFormIsPending() async {
        // A send lands while an earlier question is still on the dock:
        // the pre-existing entry must not end the watch — the prompt's
        // OWN question must still surface.
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
        ])
        let calls = Counter()
        let bothJSON = json(listJSON([
            (id: "frm_own", sessionID: "ses_current"),
            (id: "frm_second", sessionID: "ses_current"),
        ]))
        let library = library(responses, hook: { request in
            guard request.operationID == "session.form.list" else { return }
            // Call 1 is the manual load; the prompt's question exists
            // only from the watch's SECOND poll on.
            if calls.next() == 2 {
                responses.set("session.form.list", .success(bothJSON))
            }
        })
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        XCTAssertEqual(library.entries.map(\.id), ["frm_own"])

        library.startPostSendWatch(host: host, sessionID: "ses_current",
                                   childSessionIDs: [],
                                   attempts: 10, intervalNanoseconds: 10_000_000)
        await waitUntil { library.entries.count == 2 }
        library.stopPostSendWatch()
        XCTAssertEqual(library.entries.map(\.id), ["frm_own", "frm_second"],
                       "a pre-existing question does not end the window before the prompt's own arrives")
    }

    func testStoppingTheWatchDiscardsAnInFlightPoll() async {
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
        ])
        let calls = Counter()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let library = library(responses, hook: { request in
            guard request.operationID == "session.form.list" else { return }
            if calls.next() == 1 {
                enteredContinuation.yield()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        })
        library.startPostSendWatch(host: host, sessionID: "ses_current",
                                   childSessionIDs: [],
                                   attempts: 10, intervalNanoseconds: 10_000_000)
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        library.stopPostSendWatch()

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(library.entries.isEmpty,
                      "a stopped watch's in-flight poll must not publish")
    }

    func testAnsweringAPreexistingFormReopensTheRecordedWatch() async throws {
        // A conversation opened onto a question that predates any send
        // here: answering it settles the host's turn, which may raise
        // the NEXT question — so the load-recorded context re-opens the
        // window, without polling in the meantime.
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
            "session.form.reply": .success(noContent()),
        ])
        let recorder = Recorder()
        let library = library(responses, recorder: recorder)
        library.recordWatchContext(host: host, sessionID: "ses_current",
                                   childSessionIDs: [],
                                   attempts: 10, intervalNanoseconds: 10_000_000)
        XCTAssertTrue(recorder.requests.isEmpty, "recording the context polls nothing")

        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let first = try XCTUnwrap(library.entries.first)
        responses.set("session.form.list", .success(json(listJSON([
            (id: "frm_next", sessionID: "ses_current"),
        ]))))

        let outcome = await library.submit(first, answer: ["ok": .boolean(true)], host: host)
        XCTAssertEqual(outcome, .accepted)

        await waitUntil { library.entries.map(\.id) == ["frm_next"] }
        library.stopPostSendWatch()
        XCTAssertEqual(library.entries.map(\.id), ["frm_next"],
                       "an answer with no prior send re-opens the load-recorded watch")
    }

    func testDismissalIsNotRevivedByAnInFlightAnswer() async throws {
        let responses = Responses([
            "session.form.list": .success(json(listJSON(ownList))),
            "session.form.reply": .success(noContent()),
        ])
        let recorder = Recorder()
        let (replyEntered, replyContinuation) = AsyncStream<Void>.makeStream()
        let library = library(responses, recorder: recorder, hook: { request in
            guard request.operationID == "session.form.reply" else { return }
            replyContinuation.yield()
            try? await Task.sleep(nanoseconds: 250_000_000)
        })
        library.recordWatchContext(host: host, sessionID: "ses_current",
                                   childSessionIDs: [],
                                   attempts: 5, intervalNanoseconds: 10_000_000)
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        let pending = try XCTUnwrap(library.entries.first)

        let answering = Task { await library.submit(pending, answer: ["ok": .boolean(true)], host: host) }
        var iterator = replyEntered.makeAsyncIterator()
        _ = await iterator.next()
        library.stopPostSendWatch()               // the view went away mid-reply
        let outcome = await answering.value
        XCTAssertEqual(outcome, .accepted)

        let settled = recorder.requests.count
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(recorder.requests.count, settled,
                       "an in-flight answer must not revive a watch for a dock nobody can see")
    }

    // MARK: - Load generation

    func testStaleLoadCannotOverwriteANewerOne() async {
        let responses = Responses([
            "session.form.list": .success(json(listJSON([
                (id: "frm_old", sessionID: "ses_current"),
            ]))),
        ])
        let calls = Counter()
        let newResponse = json(listJSON([
            (id: "frm_new", sessionID: "ses_current"),
        ]))
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let library = library(responses, hook: { request in
            guard request.operationID == "session.form.list" else { return }
            // Call 1 is the stale load: hold it open AFTER swapping the
            // canned payload for the newer load to observe.
            if calls.next() == 1 {
                responses.set("session.form.list", .success(newResponse))
                enteredContinuation.yield()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        })

        let stale = Task { await library.load(host: host, sessionID: "ses_current", childSessionIDs: []) }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        await library.load(host: host, sessionID: "ses_current", childSessionIDs: [])
        await stale.value

        XCTAssertEqual(library.entries.map(\.id), ["frm_new"],
                       "a superseded load finishing late writes nothing")
    }
}
