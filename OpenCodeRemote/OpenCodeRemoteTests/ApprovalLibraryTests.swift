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

    private struct StubTransport: OpenCodeTransport {
        let recorder: Recorder
        let responses: Responses

        func perform(_ request: APIRequest) async throws -> APIResponse {
            recorder.record(request)
            guard let result = responses.get(request.operationID) else {
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
        credential: BasicCredential? = BasicCredential(secret: "token")
    ) -> ApprovalLibrary {
        ApprovalLibrary(
            service: PermissionService(makeTransport: { _ in
                StubTransport(recorder: recorder, responses: responses)
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
}
