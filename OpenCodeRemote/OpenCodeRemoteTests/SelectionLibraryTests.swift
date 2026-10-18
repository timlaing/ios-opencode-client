import XCTest
import OpenCodeDomain
import OpenCodeTransport
@testable import OpenCodeRemote

/// S10 selection tests (docs/navigation-screens.md S10,
/// docs/api-contract.md W06): inventories load independently (one
/// failing never erases the other), "no default" is honest absence,
/// and local selection + the sessions store are claimed ONLY after the
/// host's 204 — a rejected switch keeps the previous selection.
@MainActor
final class SelectionLibraryTests: XCTestCase {
    /// Non-isolated fixtures: transport handlers run off the main actor.
    private enum Fixtures {
        static func response(_ body: String, status: Int = 200) -> APIResponse {
            APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
        }

        static func empty(_ status: Int = 204) -> APIResponse {
            APIResponse(statusCode: status, payload: .empty)
        }

        static func located(_ data: String) -> String {
            #"{"location":{"directory":"/srv/demo"},"data":\#(data)}"#
        }

        static let modelJSON = #"{"id":"demo-code","modelID":"demo-code","providerID":"synthetic","name":"Demo Code","capabilities":{"tools":true,"input":["text","image"],"output":["text"]},"variants":[{"id":"fast"}],"time":{"released":0},"cost":[],"status":"active","enabled":true,"limit":{"context":128000,"output":8192}}"#

        static let modelsList = located("[\(modelJSON)]")

        static let agentsList = #"[{"id":"build","name":"Build","description":"Dev agent","mode":"primary","hidden":false},{"id":"reviewer","name":"Reviewer","mode":"subagent","hidden":false},{"id":"secret","name":"Secret","mode":"primary","hidden":true}]"#

        static let commandsList = #"[{"name":"review","description":"Synthetic review command"}]"#
        static let skillsList = #"[{"id":"demo-review","name":"Demo review","path":"/srv/demo/.opencode/skills/review.md","content":"Review generated files only."}]"#
        static let emptyActions = located("[]")

        static let sessionJSON = #"{"id":"ses_a","title":"Demo","agent":"plan","model":{"id":"old-model","providerID":"other"}}"#
        static let sessionList = #"{"data":[\#(sessionJSON)]}"#
        static let active = #"{"data":{}}"#
    }

    /// Captured-var mutation is not allowed in `@Sendable` handlers.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [APIRequest] = []
        func record(_ request: APIRequest) {
            lock.lock(); recorded.append(request); lock.unlock()
        }
        var requests: [APIRequest] {
            lock.lock(); defer { lock.unlock() }; return recorded
        }
    }

    /// A one-shot async gate: `wait()` suspends until `signal()`, so a
    /// test can hold one request in flight and interleave other calls.
    private actor Latch {
        private var continuation: CheckedContinuation<Void, Never>?
        private var hasArrived = false
        private var hasResumed = false

        func wait() async {
            hasArrived = true
            if hasResumed { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func signal() {
            hasResumed = true
            continuation?.resume()
            continuation = nil
        }

        var isArrived: Bool { hasArrived }
    }

    /// A lock-guarded toggle so a handler can change behavior between
    /// two sequential loads (host change).
    private final class Phase: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false

        func failActionLists() {
            lock.lock(); failing = true; lock.unlock()
        }

        var actionListsFail: Bool {
            lock.lock(); defer { lock.unlock() }; return failing
        }
    }

    private struct StubTransport: OpenCodeTransport {
        var recorder: Recorder
        var handler: @Sendable (APIRequest) throws -> APIResponse
        var hook: (@Sendable (APIRequest) async -> Void)?

        func perform(_ request: APIRequest) async throws -> APIResponse {
            recorder.record(request)
            await hook?(request)
            return try handler(request)
        }

        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private let one = OpenCodeDomain.Host(
        id: HostID(rawValue: "host_one"),
        displayName: "Mock A",
        address: URL(string: "http://host_one.local:4097")!,
        createdAt: Date(timeIntervalSince1970: 0),
        lastVersion: nil
    )

    private let two = OpenCodeDomain.Host(
        id: HostID(rawValue: "host_two"),
        displayName: "Mock B",
        address: URL(string: "http://host_two.local:4097")!,
        createdAt: Date(timeIntervalSince1970: 0),
        lastVersion: nil
    )

    private let seededSession = Session(
        id: "ses_a", parentID: nil, projectID: nil, title: "Demo",
        agent: "plan", model: Session.ModelRef(id: "old-model", providerID: "other")
    )

    private func makeLibrary(
        recorder: Recorder,
        handler: @escaping @Sendable (APIRequest) throws -> APIResponse,
        hook: (@Sendable (APIRequest) async -> Void)? = nil,
        credentials: [String: BasicCredential?] = ["host_one": BasicCredential(secret: "t")]
    ) -> SelectionLibrary {
        let stub: @Sendable () -> StubTransport = {
            StubTransport(recorder: recorder, handler: handler, hook: hook)
        }
        return SelectionLibrary(
            service: ModelAgentService(makeTransport: { _ in stub() }),
            actionService: SkillCommandService(makeTransport: { _ in stub() }),
            credentialProvider: { id in credentials[id.rawValue] ?? nil }
        )
    }

    private func makeSessionsStore(
        handler: @escaping @Sendable (APIRequest) throws -> APIResponse
    ) -> SessionsLibrary {
        let stub: @Sendable () -> StubTransport = { StubTransport(recorder: Recorder(), handler: handler) }
        return SessionsLibrary(
            service: SessionService(makeTransport: { _ in stub() }),
            credentialProvider: { _ in BasicCredential(secret: "t") }
        )
    }

    private func entry(_ host: OpenCodeDomain.Host) -> HostLibrary.Entry {
        HostLibrary.Entry(host: host, connection: .reachable(version: nil))
    }

    // MARK: - Load

    func testLoadSeedsSessionSelectionAndInventories() async throws {
        let library = makeLibrary(recorder: Recorder()) { request in
            switch request.operationID {
            case "model.list":
                return Fixtures.response(Fixtures.located("[\(Fixtures.modelJSON)]"))
            case "model.default":
                return Fixtures.response(Fixtures.located(Fixtures.modelJSON))
            case "agent.list":
                return Fixtures.response(Fixtures.located(Fixtures.agentsList))
            case "command.list":
                return Fixtures.response(Fixtures.located(Fixtures.commandsList))
            case "skill.list":
                return Fixtures.response(Fixtures.located(Fixtures.skillsList))
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load(host: one, session: seededSession)

        XCTAssertNil(library.error)
        XCTAssertEqual(library.models.map(\.id), ["demo-code"])
        XCTAssertEqual(library.defaultModel?.id, "demo-code")
        XCTAssertEqual(library.agents.map(\.id), ["build", "reviewer", "secret"],
                       "the raw inventory is kept; the VIEW filters offerable agents")
        XCTAssertEqual(library.selectedRef?.id, "old-model", "selection is seeded from the session")
        XCTAssertEqual(library.selectedAgentID, "plan")
        XCTAssertEqual(library.commands.map(\.id), ["review"], "W07 action discovery joins the inventories")
        XCTAssertEqual(library.skills.map(\.id), ["demo-review"])
        XCTAssertFalse(library.isLoading)
    }

    func testLoadIsolatesInventoryFailuresAndTreatsDefault503AsAbsence() async throws {
        let library = makeLibrary(recorder: Recorder()) { request in
            switch request.operationID {
            case "model.list":
                return Fixtures.response(Fixtures.located("[\(Fixtures.modelJSON)]"))
            case "model.default":
                // No default configured — absence, never a failure.
                throw TransportError.http(status: 503, envelope: nil)
            case "agent.list":
                throw TransportError.http(status: 500, envelope: nil)
            case "command.list":
                return Fixtures.response(Fixtures.located(Fixtures.commandsList))
            case "skill.list":
                return Fixtures.response(Fixtures.located(Fixtures.skillsList))
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load(host: one, session: seededSession)

        XCTAssertEqual(library.models.map(\.id), ["demo-code"], "a failing agent list must not erase the models")
        XCTAssertNil(library.defaultModel)
        XCTAssertTrue(library.agents.isEmpty)
        XCTAssertEqual(library.commands.map(\.id), ["review"], "action inventories load independently too")
        XCTAssertEqual(library.skills.map(\.id), ["demo-review"])
        XCTAssertEqual(library.error, "The host rejected the request (HTTP 500).",
                       "503 contributes no error; the real failure surfaces alone")
    }

    func testLoadWithoutCredentialFailsClosed() async throws {
        let library = makeLibrary(
            recorder: Recorder(),
            handler: { _ in Fixtures.response(Fixtures.located("[]")) },
            credentials: [:]
        )

        await library.load(host: one, session: seededSession)

        XCTAssertEqual(library.error, "Re-pair this host to choose a model or agent.")
        XCTAssertTrue(library.models.isEmpty)
        XCTAssertTrue(library.agents.isEmpty)
    }

    // MARK: - Switching

    func testSelectModelClaimsOnlyAfter204AndPatchesSessionsStore() async throws {
        let handler: @Sendable (APIRequest) throws -> APIResponse = { request in
            switch request.operationID {
            case "model.list":
                return Fixtures.response(Fixtures.located("[\(Fixtures.modelJSON)]"))
            case "model.default":
                return Fixtures.response(Fixtures.located(Fixtures.modelJSON))
            case "agent.list":
                return Fixtures.response(Fixtures.located(Fixtures.agentsList))
            case "command.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "skill.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "session.list":
                return Fixtures.response(Fixtures.sessionList)
            case "session.active":
                return Fixtures.response(Fixtures.active)
            case "session.switchModel":
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        let store = makeSessionsStore(handler: handler)
        await store.load(host: one)
        XCTAssertEqual(store.sessionsByHost[one.id]?.first?.model?.id, "old-model", "precondition")
        // A title search is active while the switch happens — its cache
        // feeds rows() and must be patched exactly like the inventory.
        await store.search("demo", entries: [entry(one)])
        XCTAssertEqual(store.searchResultsByHost[one.id]?.count, 1, "precondition: search cache holds the session")

        let library = makeLibrary(recorder: Recorder(), handler: handler)
        await library.load(host: one, session: seededSession)
        let model = try XCTUnwrap(library.models.first)

        let accepted = await library.selectModel(host: one, sessionID: "ses_a", model: model, sessions: store)

        XCTAssertTrue(accepted, "204 is the authority")
        XCTAssertEqual(library.selectedRef?.id, "demo-code")
        XCTAssertNil(library.selectedRef?.variant, "Model.Ref carries id+providerID; variant only when chosen")
        XCTAssertNil(library.error)
        let stored = store.sessionsByHost[one.id]?.first { $0.id == "ses_a" }
        XCTAssertEqual(stored?.model?.id, "demo-code", "the store is patched only after the host confirmed")
        XCTAssertEqual(stored?.agent, "plan", "an unrelated selection is untouched")
        XCTAssertEqual(store.searchResultsByHost[one.id]?.first?.model?.id, "demo-code",
                       "the active search cache never shows a stale selection")
    }

    func testReloadKeepsHostConfirmedSelectionOverStaleSnapshot() async throws {
        let handler: @Sendable (APIRequest) throws -> APIResponse = { request in
            switch request.operationID {
            case "model.list":
                return Fixtures.response(Fixtures.located("[\(Fixtures.modelJSON)]"))
            case "model.default":
                return Fixtures.response(Fixtures.located(Fixtures.modelJSON))
            case "agent.list":
                return Fixtures.response(Fixtures.located(Fixtures.agentsList))
            case "command.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "skill.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "session.switchModel":
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        let library = makeLibrary(recorder: Recorder(), handler: handler)
        await library.load(host: one, session: seededSession)
        XCTAssertEqual(library.selectedRef?.id, "old-model", "precondition: seeded from the snapshot")

        let model = try XCTUnwrap(library.models.first)
        let accepted = await library.selectModel(host: one, sessionID: "ses_a", model: model)
        XCTAssertTrue(accepted)
        XCTAssertEqual(library.selectedRef?.id, "demo-code")

        // The sheet reopens with the SAME immutable session snapshot.
        await library.load(host: one, session: seededSession)

        XCTAssertEqual(library.selectedRef?.id, "demo-code",
                       "a reopen must not roll the confirmed selection back to the stale snapshot")
        XCTAssertEqual(library.selectedAgentID, "plan")
    }

    func testReturningToASessionPreservesConfirmedSelection() async throws {
        let handler: @Sendable (APIRequest) throws -> APIResponse = { request in
            switch request.operationID {
            case "model.list":
                return Fixtures.response(Fixtures.located("[\(Fixtures.modelJSON)]"))
            case "model.default":
                return Fixtures.response(Fixtures.located(Fixtures.modelJSON))
            case "agent.list":
                return Fixtures.response(Fixtures.located(Fixtures.agentsList))
            case "command.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "skill.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "session.switchModel":
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        let library = makeLibrary(recorder: Recorder(), handler: handler)
        let sessionB = Session(
            id: "ses_b", parentID: nil, projectID: nil, title: "Other",
            agent: "plan", model: Session.ModelRef(id: "other-model", providerID: "x")
        )

        // Confirm a switch in session A.
        await library.load(host: one, session: seededSession)
        let model = try XCTUnwrap(library.models.first)
        let accepted = await library.selectModel(host: one, sessionID: "ses_a", model: model)
        XCTAssertTrue(accepted)
        XCTAssertEqual(library.selectedRef?.id, "demo-code")

        // Visit session B — it seeds from ITS snapshot.
        await library.load(host: one, session: sessionB)
        XCTAssertEqual(library.selectedRef?.id, "other-model")

        // Returning to A must restore A's CONFIRMED selection — its
        // immutable snapshot still says "old-model".
        await library.load(host: one, session: seededSession)
        XCTAssertEqual(library.selectedRef?.id, "demo-code",
                       "returning to a session never restores its stale snapshot")
        XCTAssertEqual(library.selectedAgentID, "plan")
    }

    func testSeedingIsScopedToTheHostAndSessionPair() async throws {
        let handler: @Sendable (APIRequest) throws -> APIResponse = { request in
            switch request.operationID {
            case "model.list":
                return Fixtures.response(Fixtures.located("[\(Fixtures.modelJSON)]"))
            case "model.default":
                return Fixtures.response(Fixtures.located(Fixtures.modelJSON))
            case "agent.list":
                return Fixtures.response(Fixtures.located(Fixtures.agentsList))
            case "command.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "skill.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "session.switchModel":
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        let library = makeLibrary(recorder: Recorder(), handler: handler, credentials: [
            "host_one": BasicCredential(secret: "t"),
            "host_two": BasicCredential(secret: "t"),
        ])
        let sharedIDA = Session(
            id: "ses_x", parentID: nil, projectID: nil, title: "A's",
            agent: "plan", model: Session.ModelRef(id: "old-a", providerID: "x")
        )
        let sharedIDB = Session(
            id: "ses_x", parentID: nil, projectID: nil, title: "B's",
            agent: "plan", model: Session.ModelRef(id: "old-b", providerID: "y")
        )

        await library.load(host: one, session: sharedIDA)
        XCTAssertEqual(library.selectedRef?.id, "old-a", "precondition")
        let model = try XCTUnwrap(library.models.first)
        let acceptedOnX = await library.selectModel(host: one, sessionID: "ses_x", model: model)
        XCTAssertTrue(acceptedOnX)
        XCTAssertEqual(library.selectedRef?.id, "demo-code")

        // The SAME session ID on ANOTHER host is a different selection:
        // it seeds from its own snapshot, never inherits host one's.
        await library.load(host: two, session: sharedIDB)
        XCTAssertEqual(library.selectedRef?.id, "old-b",
                       "session identity is the (host, session) pair")
    }

    func testSwitchCompletingAfterMovingToAnotherSessionUpdatesOnlyItsOwnSession() async throws {
        let latch = Latch()
        let handler: @Sendable (APIRequest) throws -> APIResponse = { request in
            switch request.operationID {
            case "model.list":
                return Fixtures.response(Fixtures.located("[\(Fixtures.modelJSON)]"))
            case "model.default":
                return Fixtures.response(Fixtures.located(Fixtures.modelJSON))
            case "agent.list":
                return Fixtures.response(Fixtures.located(Fixtures.agentsList))
            case "command.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "skill.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "session.switchModel":
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        // The model switch for session A stays in flight until the test
        // releases it — long enough for the sheet to move to session B.
        let library = makeLibrary(recorder: Recorder(), handler: handler, hook: { request in
            if request.operationID == "session.switchModel" {
                await latch.wait()
            }
        })
        let sessionB = Session(
            id: "ses_b", parentID: nil, projectID: nil, title: "Other",
            agent: "reviewer", model: Session.ModelRef(id: "other-model", providerID: "x")
        )

        await library.load(host: one, session: seededSession)
        XCTAssertEqual(library.selectedRef?.id, "old-model", "precondition")
        let model = try XCTUnwrap(library.models.first)

        // Start A's switch and wait (bounded) until it is genuinely in
        // flight, then move the sheet to session B before releasing it.
        // The wait is timed: if selectModel never reaches the hook the
        // test must fail — not spin forever — and the latch is released
        // so the pending task can finish instead of leaking.
        let pending = Task { await library.selectModel(host: one, sessionID: "ses_a", model: model) }
        var arrived = false
        for _ in 0..<100 {
            if await latch.isArrived { arrived = true; break }
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms → ~2s worst case
        }
        if !arrived {
            await latch.signal()
            _ = await pending.value
            XCTFail("the model switch never reached the transport hook")
            return
        }
        await library.load(host: one, session: sessionB)
        XCTAssertEqual(library.selectedRef?.id, "other-model", "precondition: the sheet shows B")

        await latch.signal()
        let accepted = await pending.value
        XCTAssertTrue(accepted, "the host confirmed A's switch")

        // A's confirmed model must not paint into B's visible selection…
        XCTAssertEqual(library.selectedRef?.id, "other-model")
        XCTAssertEqual(library.selectedAgentID, "reviewer", "B keeps its own agent")

        // …and returning to A restores A's confirmed MODEL and A's own
        // AGENT — B's agent never leaked into A's cached selection.
        await library.load(host: one, session: seededSession)
        XCTAssertEqual(library.selectedRef?.id, "demo-code")
        XCTAssertEqual(library.selectedAgentID, "plan")
    }

    func testOfflineInventoryFailuresCollapseToASingleMessage() async throws {
        let library = makeLibrary(recorder: Recorder()) { _ in
            throw TransportError.connectionFailed("down")
        }

        await library.load(host: one, session: seededSession)

        XCTAssertEqual(library.error, "Connection failed — the host may be unreachable.",
                       "one host, one problem — identical failures collapse to a single message")
    }

    func testRejectedSwitchesKeepPreviousSelection() async throws {
        let handler: @Sendable (APIRequest) throws -> APIResponse = { request in
            switch request.operationID {
            case "model.list":
                return Fixtures.response(Fixtures.located("[\(Fixtures.modelJSON)]"))
            case "agent.list":
                return Fixtures.response(Fixtures.located(Fixtures.agentsList))
            case "command.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "skill.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "model.default":
                throw TransportError.http(status: 503, envelope: nil)
            case "session.list":
                return Fixtures.response(Fixtures.sessionList)
            case "session.active":
                return Fixtures.response(Fixtures.active)
            case "session.switchModel", "session.switchAgent":
                throw TransportError.http(status: 400, envelope: nil)
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        let store = makeSessionsStore(handler: handler)
        await store.load(host: one)
        XCTAssertEqual(store.sessionsByHost[one.id]?.first?.model?.id, "old-model", "precondition")

        let library = makeLibrary(recorder: Recorder(), handler: handler)
        await library.load(host: one, session: seededSession)
        let model = try XCTUnwrap(library.models.first)
        let agent = try XCTUnwrap(library.agents.first)

        let modelAccepted = await library.selectModel(host: one, sessionID: "ses_a", model: model, sessions: store)
        XCTAssertFalse(modelAccepted)
        XCTAssertEqual(library.selectedRef?.id, "old-model", "a rejected switch never claims the selection")
        XCTAssertEqual(library.error, "The host rejected the request (HTTP 400).")

        let agentAccepted = await library.selectAgent(host: one, sessionID: "ses_a", agent: agent, sessions: store)
        XCTAssertFalse(agentAccepted)
        XCTAssertEqual(library.selectedAgentID, "plan", "previous selection stays visible")
        XCTAssertEqual(store.sessionsByHost[one.id]?.first?.model?.id, "old-model",
                       "the store is never patched for a rejected switch")
    }

    func testSelectAgentClaimsOnlyAfter204() async throws {
        let handler: @Sendable (APIRequest) throws -> APIResponse = { request in
            switch request.operationID {
            case "agent.list":
                return Fixtures.response(Fixtures.located(Fixtures.agentsList))
            case "command.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "skill.list":
                return Fixtures.response(Fixtures.located(Fixtures.emptyActions))
            case "session.list":
                return Fixtures.response(Fixtures.sessionList)
            case "session.active":
                return Fixtures.response(Fixtures.active)
            case "session.switchAgent":
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        let store = makeSessionsStore(handler: handler)
        await store.load(host: one)

        let library = makeLibrary(recorder: Recorder(), handler: handler)
        await library.load(host: one, session: seededSession)
        let build = try XCTUnwrap(library.agents.first { $0.id == "build" })

        let accepted = await library.selectAgent(host: one, sessionID: "ses_a", agent: build, sessions: store)

        XCTAssertTrue(accepted)
        XCTAssertEqual(library.selectedAgentID, "build")
        XCTAssertNil(library.error)
        XCTAssertEqual(store.sessionsByHost[one.id]?.first?.agent, "build",
                       "the store reflects the host-confirmed agent")
    }

    // MARK: - Commands and skills (W07)

    func testInvocationsAre204Authoritative() async throws {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder) { request in
            switch request.operationID {
            case "session.command", "experimental.session.skill":
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        let command = CommandInfo(name: "review", description: "Synthetic review command")
        let skill = SkillInfo(
            id: "demo-review", name: "Demo review",
            path: "/srv/demo/.opencode/skills/review.md",
            content: "Review generated files only."
        )

        let sent = await library.invokeCommand(
            host: one, sessionID: "ses_a", command: command, text: "generated files"
        )
        XCTAssertTrue(sent, "204 is the authority — nothing rendered locally")
        XCTAssertNil(library.error)
        XCTAssertNotNil(library.notice, "a confirmed invocation is acknowledged")
        XCTAssertFalse(library.isInvoking)

        // The user's arguments reach the request body verbatim.
        let request = try XCTUnwrap(recorder.requests.first { $0.operationID == "session.command" })
        let payload = request.body.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertEqual(payload?["text"] as? String, "generated files")
        XCTAssertEqual(payload?["name"] as? String, "review")

        let activated = await library.activateSkill(host: one, sessionID: "ses_a", skill: skill)
        XCTAssertTrue(activated)
        XCTAssertNil(library.error)
        XCTAssertNotNil(library.notice)
        XCTAssertFalse(library.isInvoking)
    }

    func testRejectedInvocationsClaimNothing() async throws {
        let library = makeLibrary(recorder: Recorder()) { request in
            switch request.operationID {
            case "session.command", "experimental.session.skill":
                throw TransportError.http(status: 404, envelope: nil)
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        let command = CommandInfo(name: "nope")
        let skill = SkillInfo(id: "missing", name: "Missing", path: "/p", content: "c")

        let sent = await library.invokeCommand(host: one, sessionID: "ses_a", command: command)
        XCTAssertFalse(sent, "a rejected command must not claim anything ran")
        XCTAssertEqual(library.error, "The host rejected the request (HTTP 404).")
        XCTAssertNil(library.notice)

        let activated = await library.activateSkill(host: one, sessionID: "ses_a", skill: skill)
        XCTAssertFalse(activated, "a rejected skill must not claim activation")
        XCTAssertEqual(library.error, "The host rejected the request (HTTP 404).")
        XCTAssertNil(library.notice)
    }

    func testInvocationsFailClosedWithoutCredential() async throws {
        let library = makeLibrary(
            recorder: Recorder(),
            handler: { _ in Fixtures.empty() },
            credentials: [:]
        )

        let sent = await library.invokeCommand(
            host: one, sessionID: "ses_a", command: CommandInfo(name: "review")
        )

        XCTAssertFalse(sent)
        XCTAssertEqual(library.error, "Re-pair this host to run commands or skills.")
    }

    func testActionInventoriesDoNotSurviveAHostChange() async throws {
        let phase = Phase()
        let library = makeLibrary(
            recorder: Recorder(),
            handler: { request in
                switch request.operationID {
                case "model.list":
                    return Fixtures.response(Fixtures.located("[\(Fixtures.modelJSON)]"))
                case "model.default":
                    return Fixtures.response(Fixtures.located(Fixtures.modelJSON))
                case "agent.list":
                    return Fixtures.response(Fixtures.located(Fixtures.agentsList))
                case "command.list":
                    if phase.actionListsFail {
                        throw TransportError.http(status: 500, envelope: nil)
                    }
                    return Fixtures.response(Fixtures.located(Fixtures.commandsList))
                case "skill.list":
                    if phase.actionListsFail {
                        throw TransportError.http(status: 500, envelope: nil)
                    }
                    return Fixtures.response(Fixtures.located(Fixtures.skillsList))
                default:
                    throw TransportError.connectionFailed("unstubbed \(request.operationID)")
                }
            },
            credentials: [
                "host_one": BasicCredential(secret: "t"),
                "host_two": BasicCredential(secret: "t"),
            ]
        )

        // Host A's actions load.
        await library.load(host: one, session: seededSession)
        XCTAssertEqual(library.commands.map(\.id), ["review"], "precondition")
        XCTAssertEqual(library.skills.map(\.id), ["demo-review"])

        // Moving to host B where BOTH action lists fail: host A's rows
        // must not survive under B — empty plus the error is the honest
        // state.
        phase.failActionLists()
        await library.load(host: two, session: seededSession)

        XCTAssertTrue(library.commands.isEmpty, "host A's commands never appear under host B")
        XCTAssertTrue(library.skills.isEmpty, "host A's skills never appear under host B")
        XCTAssertEqual(library.error, "The host rejected the request (HTTP 500).")
        XCTAssertEqual(library.models.map(\.id), ["demo-code"],
                       "inventories that succeed still populate for the new host")
    }

    func testSecondInvocationIsRejectedWhileOneIsInFlight() async throws {
        let latch = Latch()
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder, handler: { request in
            switch request.operationID {
            case "session.command", "experimental.session.skill":
                return Fixtures.empty()
            default:
                throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }, hook: { request in
            if request.operationID == "session.command" {
                await latch.wait()
            }
        })
        let command = CommandInfo(name: "review")

        // Hold the first invocation at the transport…
        let first = Task { await library.invokeCommand(host: one, sessionID: "ses_a", command: command) }
        var arrived = false
        for _ in 0..<100 {
            if await latch.isArrived { arrived = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(arrived, "the first invocation must reach the transport")

        // …a second tap while it is in flight must NOT run the command.
        let second = await library.invokeCommand(host: one, sessionID: "ses_a", command: command)
        XCTAssertFalse(second, "a second invocation is rejected while one is in flight")

        await latch.signal()
        let sent = await first.value
        XCTAssertTrue(sent, "the held invocation still completes authoritatively")
        XCTAssertEqual(
            recorder.requests.filter { $0.operationID == "session.command" }.count, 1,
            "the command reached the host exactly once"
        )
    }
}
