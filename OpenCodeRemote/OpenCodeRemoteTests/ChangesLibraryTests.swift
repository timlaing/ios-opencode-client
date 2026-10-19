import XCTest
@testable import OpenCodeRemote
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W12 S15 Changes inspector tests: patch parsing/side-by-side/search
/// decisions, session-turn scope loads (defaults, range, context, stale
/// discard), workspace scope loads (all four reads, the distinct null-
/// base state, per-section failures), scope switching, and the honest
/// no-directory path (docs/api-contract.md W12/W13).
@MainActor
final class ChangesLibraryTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [APIRequest] = []
        func record(_ request: APIRequest) { lock.lock(); recorded.append(request); lock.unlock() }
        var requests: [APIRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
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
    }

    private nonisolated static func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    private nonisolated static func filesBody(file: String) -> String {
        #"{"data":[{"file":"\#(file)","patch":"@@ -1 +1 @@\n-old\n+new\n","additions":1,"deletions":1,"status":"modified"}]}"#
    }

    private nonisolated static let infoBody =
        #"{"location":{"directory":"/srv/demo"},"data":{"provider":"git","branch":{"current":"demo-feature","default":"main"}}}"#
    private nonisolated static let statusBody =
        #"{"location":{"directory":"/srv/demo"},"data":[{"file":"a.txt","additions":2,"deletions":0,"status":"added"}]}"#
    private nonisolated static let baseNullBody =
        #"{"location":{"directory":"/srv/demo"},"data":null}"#
    private nonisolated static let vcsDiffBody =
        #"{"location":{"directory":"/srv/demo"},"data":[{"file":"a.txt","patch":"+a\n","additions":1,"deletions":0,"status":"added"}]}"#

    private let host = OpenCodeDomain.Host(
        id: HostID(rawValue: "h1"),
        displayName: "Demo",
        address: URL(string: "http://localhost:4097")!,
        createdAt: Date(timeIntervalSince1970: 0),
        lastVersion: nil
    )
    private let credential = BasicCredential(secret: "token")

    private func inputs(directory: String? = "/srv/demo") -> ChangesLibrary.Inputs {
        .init(host: host, credential: credential, sessionID: "ses_a", directory: directory)
    }

    private func makeLibrary(
        recorder: Recorder = Recorder(),
        hook: (@Sendable (APIRequest) async -> Void)? = nil,
        handler: @escaping @Sendable (APIRequest) throws -> APIResponse
    ) -> ChangesLibrary {
        let transport = StubTransport(recorder: recorder, handler: handler, hook: hook)
        return ChangesLibrary(
            historyService: SessionHistoryService(makeTransport: { _ in transport }),
            vcsService: VcsService(makeTransport: { _ in transport })
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func message(_ id: String, _ text: String, type: String = "user") throws -> SessionMessage {
        // Newlines must reach the JSON as the two-character escape, not
        // as raw control bytes.
        let escaped = text.replacingOccurrences(of: "\n", with: "\\n")
        return try OpenCodeAPI.decoder.decode(
            SessionMessage.self,
            from: Data(#"{"id":"\#(id)","type":"\#(type)","time":{"created":1},"text":"\#(escaped)"}"#.utf8)
        )
    }

    // MARK: Pure decisions

    func testUserTurnsFiltersToUserMessagesNewestFirst() throws {
        let idle = try OpenCodeAPI.decoder.decode(
            SessionMessage.self,
            from: Data(#"{"id":"msg_b","type":"idle","time":{"created":2},"outcome":"completed"}"#.utf8)
        )
        let messages = [
            try message("msg_a", "First\nprompt"),
            idle,
            try message("msg_c", "Second"),
        ]
        XCTAssertEqual(
            ChangesLibrary.userTurns(from: messages),
            [
                .init(id: "msg_c", preview: "Second"),
                .init(id: "msg_a", preview: "First prompt"),
            ],
            "only user turns, flattened to one line, newest first"
        )
    }

    func testParsePatchNumbersLinesFromHunkHeaders() {
        let lines = ChangesLibrary.parsePatch(
            "--- a/src/main.py\n+++ b/src/main.py\n@@ -1 +1 @@\n-print(\"Hello\")\n+print(\"Hi\")\n tail\n"
        )
        XCTAssertEqual(lines.map(\.kind), [.fileHeader, .fileHeader, .hunkHeader, .deletion, .addition, .context])
        XCTAssertEqual(lines[3].oldLine, 1)
        XCTAssertEqual(lines[3].text, "print(\"Hello\")")
        XCTAssertNil(lines[3].newLine)
        XCTAssertEqual(lines[4].newLine, 1)
        XCTAssertEqual(lines[5].oldLine, 2)
        XCTAssertEqual(lines[5].newLine, 2)
        XCTAssertEqual(lines[5].text, "tail", "the context marker space is dropped")
    }

    func testParsePatchLeavesLinesUnnumberedAfterMalformedHeader() {
        let lines = ChangesLibrary.parsePatch("@@ nonsense @@\n+added\n")
        XCTAssertEqual(lines.map(\.kind), [.hunkHeader, .addition])
        XCTAssertNil(lines[1].newLine, "a malformed header never produces guessed numbers")
    }

    func testParsePatchHandlesCRLFAndNoteLines() {
        let lines = ChangesLibrary.parsePatch("--- a/x\r\n+++ b/x\r\n@@ -1 +1 @@\r\n-old\r\n\\ No newline at end of file\r\n")
        XCTAssertEqual(lines.map(\.kind), [.fileHeader, .fileHeader, .hunkHeader, .deletion, .note])
    }

    func testSideBySidePairsRunsAndMapsLinesToRows() {
        let lines = ChangesLibrary.parsePatch(
            "@@ -1,2 +1,2 @@\n-first\n-second\n+uno\n+dos\n+extra\n same\n"
        )
        let side = ChangesLibrary.sideBySide(lines)
        // header, three zipped pairs (the deletion side is shorter, so
        // the extra addition pads its own row), one context pair.
        XCTAssertEqual(side.rows.count, 5)
        XCTAssertEqual(
            side.rows[1], .pair(left: lines[1], right: lines[3]),
            "deletions zip with additions by position"
        )
        XCTAssertEqual(side.rows[2], .pair(left: lines[2], right: lines[4]))
        XCTAssertEqual(side.rows[3], .pair(left: nil, right: lines[5]))
        XCTAssertEqual(side.rows[4], .pair(left: lines[6], right: lines[6]))
        XCTAssertEqual(side.rowOfLine[5], 3, "the extra addition's navigation target is its own row")
    }

    func testSearchHitsIgnoreCaseAndSkipEmptyQuery() {
        let lines = ChangesLibrary.parsePatch(
            "@@ -1 +1 @@\n-Hello\n+goodbye\n+HELLO world\n"
        )
        XCTAssertEqual(ChangesLibrary.searchHits(query: "hello", in: lines), [1, 3])
        XCTAssertEqual(ChangesLibrary.searchHits(query: "   ", in: lines), [])
    }

    func testChangeStartsMarksEachRun() {
        let lines = ChangesLibrary.parsePatch(
            "@@ -1,2 +1,2 @@\n-old\n+new\n ctx\n+again\n"
        )
        XCTAssertEqual(
            ChangesLibrary.changeStarts(in: lines), [1, 4],
            "one target per run of additions/deletions, not per line"
        )
    }

    func testAdvanceCursorLandsOnFirstForNextAndLastForPrevious() {
        XCTAssertEqual(ChangesLibrary.advanceCursor(nil, delta: 1, count: 3), 0)
        XCTAssertEqual(ChangesLibrary.advanceCursor(nil, delta: -1, count: 3), 2)
        XCTAssertEqual(ChangesLibrary.advanceCursor(2, delta: 1, count: 3), 0)
        XCTAssertEqual(ChangesLibrary.advanceCursor(0, delta: -1, count: 3), 2)
        XCTAssertNil(ChangesLibrary.advanceCursor(nil, delta: 1, count: 0))
    }

    // MARK: Session-turn scope

    func testSessionScopeLoadsNewestTurnWithHunkContext() async {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder) { request in
            Self.json(Self.filesBody(file: "src/main.py"))
        }
        library.reload(inputs())

        await waitUntil { library.sessionFiles != nil }
        XCTAssertEqual(library.sessionFiles?.first?.file, "src/main.py")
        XCTAssertEqual(recorder.requests.map(\.operationID), ["session.diff"])
        let query = Dictionary(
            uniqueKeysWithValues: recorder.requests[0].query.map { ($0.key, $0.value) }
        )
        XCTAssertEqual(
            query, ["context": "3"],
            "the newest turn and hunk context are the host defaults; from/to stay omitted"
        )
        XCTAssertNil(library.errors[.sessionTurn])
    }

    func testSessionRangeAndFullFileReachTheRequest() async {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder) { _ in
            Self.json(Self.filesBody(file: "a.txt"))
        }
        library.setTurn(from: "msg_a", to: nil, inputs())
        await waitUntil { library.sessionFiles != nil }
        library.setFullFile(true, inputs())
        await waitUntil { recorder.requests.count == 2 }

        let last = recorder.requests[1]
        let query = Dictionary(uniqueKeysWithValues: last.query.map { ($0.key, $0.value) })
        XCTAssertEqual(
            query, ["from": "msg_a"],
            "the chosen start reaches the host; full-file omits context entirely"
        )
    }

    func testStaleSessionResponseIsDiscardedAfterAwait() async {
        let latch = Latch()
        let library = makeLibrary(
            hook: { request in
                // Hold ONLY the default-range (no `from`) request in
                // flight until the newer range load has finished.
                if request.query.first(where: { $0.key == "from" }) == nil {
                    await latch.wait()
                }
            },
            handler: { request in
                let from = request.query.first { $0.key == "from" }?.value
                return Self.json(Self.filesBody(file: from == nil ? "first.py" : "second.py"))
            }
        )
        library.reload(inputs())
        library.setTurn(from: "msg_a", to: nil, inputs())
        await waitUntil { library.sessionFiles?.first?.file == "second.py" }

        await latch.signal()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(
            library.sessionFiles?.first?.file, "second.py",
            "the superseded response is discarded after its await — never adopted"
        )
    }

    func testSessionFailureNamesTheActualError() async {
        let library = makeLibrary { _ in
            throw TransportError.connectionFailed("down")
        }
        library.reload(inputs())
        await waitUntil { library.errors[.sessionTurn] != nil }

        XCTAssertTrue(
            library.errors[.sessionTurn]?.contains("unreachable") == true,
            "a connection failure names the actual failure, not a generic message"
        )
    }

    // MARK: Workspace scope

    func testWorkspaceLoadAdoptsAllSectionsAndMarksNullBaseUnavailable() async {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder) { request in
            switch request.operationID {
            case "vcs.get": return Self.json(Self.infoBody)
            case "vcs.status": return Self.json(Self.statusBody)
            case "vcs.base": return Self.json(Self.baseNullBody)
            default: return Self.json(Self.vcsDiffBody)
            }
        }
        library.setScope(.workspace, inputs())

        await waitUntil { library.diffFiles != nil && library.statusFiles != nil }
        XCTAssertEqual(library.branchInfo?.branch.current, "demo-feature")
        XCTAssertEqual(library.branchInfo?.branch.defaultBranch, "main")
        XCTAssertEqual(library.statusFiles?.first?.additions, 2)
        XCTAssertEqual(library.diffFiles?.first?.file, "a.txt")
        XCTAssertEqual(
            library.baseState, .unavailable,
            "a host null base is a distinct state — not a failure and not an empty diff"
        )
        XCTAssertTrue(library.loading.isEmpty)
        XCTAssertTrue(library.errors.isEmpty)
        XCTAssertEqual(
            recorder.requests.map(\.operationID), ["vcs.get", "vcs.status", "vcs.base", "vcs.diff"],
            "the workspace section reads branch, status, base and the mode diff"
        )
    }

    func testWorkspaceModeChangeRequestsOnlyTheDiffAgain() async {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder) { request in
            switch request.operationID {
            case "vcs.get": return Self.json(Self.infoBody)
            case "vcs.status": return Self.json(Self.statusBody)
            case "vcs.base": return Self.json(Self.baseNullBody)
            default: return Self.json(Self.vcsDiffBody)
            }
        }
        library.setScope(.workspace, inputs())
        await waitUntil { library.diffFiles != nil }

        library.setMode(.branch, inputs())
        await waitUntil { recorder.requests.count == 5 }

        let last = recorder.requests[4]
        XCTAssertEqual(last.operationID, "vcs.diff", "mode only affects the diff — nothing else refetches")
        let query = Dictionary(uniqueKeysWithValues: last.query.map { ($0.key, $0.value) })
        XCTAssertEqual(query["mode"], "branch")
    }

    func testWorkspaceDiffFailureSurfacesOnlyTheDiffError() async {
        let library = makeLibrary { request in
            switch request.operationID {
            case "vcs.diff": throw TransportError.http(status: 503, envelope: nil)
            case "vcs.get": return Self.json(Self.infoBody)
            case "vcs.status": return Self.json(Self.statusBody)
            default: return Self.json(Self.baseNullBody)
            }
        }
        library.setScope(.workspace, inputs())

        await waitUntil { library.errors[.workspaceDiff] != nil }
        XCTAssertNotNil(library.errors[.workspaceDiff])
        XCTAssertNil(library.errors[.workspaceHeader], "the other sections load fine and stay error-free")
        XCTAssertEqual(library.branchInfo?.provider, "git", "successful sections are still adopted")
    }

    func testWorkspaceWithoutDirectoryIsHonestAndIssuesNoRequest() async {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder) { _ in
            XCTFail("nothing may be requested without a workspace directory")
            return Self.json("{}")
        }
        library.setScope(.workspace, inputs(directory: nil))

        XCTAssertTrue(library.errors[.workspaceHeader]?.contains("no workspace directory") == true)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testScopeSwitchLoadsWorkspaceAndKeepsSessionFiles() async {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder) { request in
            if request.operationID == "session.diff" {
                return Self.json(Self.filesBody(file: "session.py"))
            }
            switch request.operationID {
            case "vcs.get": return Self.json(Self.infoBody)
            case "vcs.status": return Self.json(Self.statusBody)
            case "vcs.base": return Self.json(Self.baseNullBody)
            default: return Self.json(Self.vcsDiffBody)
            }
        }
        library.reload(inputs())
        await waitUntil { library.sessionFiles != nil }

        library.setScope(.workspace, inputs())
        await waitUntil { library.diffFiles != nil }

        XCTAssertEqual(
            library.sessionFiles?.first?.file, "session.py",
            "the session scope keeps its adopted state across a scope switch"
        )
        XCTAssertEqual(
            recorder.requests.map(\.operationID),
            ["session.diff", "vcs.get", "vcs.status", "vcs.base", "vcs.diff"]
        )
    }

    func testLoadIfNeededSkipsASecondLoadButReloadForces() async {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder) { _ in
            Self.json(Self.filesBody(file: "a.txt"))
        }
        library.loadIfNeeded(inputs())
        await waitUntil { library.sessionFiles != nil }
        library.loadIfNeeded(inputs())
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(
            recorder.requests.count, 1,
            "popping back from a detail view never refetches"
        )

        library.reload(inputs())
        await waitUntil { recorder.requests.count == 2 }
    }
}
