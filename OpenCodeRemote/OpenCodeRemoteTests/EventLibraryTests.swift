import XCTest
import OpenCodeDomain
import OpenCodeTransport
@testable import OpenCodeRemote

/// W16 event subscription (docs/api-contract.md W16,
/// docs/implementation-defaults.md reconnect ladder): delivery, the
/// 1/2/4/8/16/32/60s backoff with reset-on-delivery, the
/// authentication-failure stop, credential gating, and supersession.
@MainActor
final class EventLibraryTests: XCTestCase {
    /// One scripted stream frame.
    private enum Frame {
        case event(OpenCodeEvent)
        /// Delivers after a delay — lets a test supersede a loop that
        /// is still on its first connection.
        case delayed(UInt64, OpenCodeEvent)
        case fail(TransportError)
    }

    /// Thread-safe counters for what the supervisor did (transport
    /// builds, sleeps, delivered events) — captured-var mutation is
    /// not allowed in `@Sendable` contexts.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var builtCount = 0
        private var slept: [Double] = []
        private var delivered: [OpenCodeEvent] = []
        func nextBuildIndex() -> Int {
            lock.lock(); defer { lock.unlock() }
            let index = builtCount
            builtCount += 1
            return index
        }
        func recordSleep(_ seconds: Double) {
            lock.lock(); slept.append(seconds); lock.unlock()
        }
        func record(_ event: OpenCodeEvent) {
            lock.lock(); delivered.append(event); lock.unlock()
        }
        var builds: Int {
            lock.lock(); defer { lock.unlock() }; return builtCount
        }
        var sleeps: [Double] {
            lock.lock(); defer { lock.unlock() }; return slept
        }
        var events: [OpenCodeEvent] {
            lock.lock(); defer { lock.unlock() }; return delivered
        }
    }

    private struct ScriptedTransport: OpenCodeTransport {
        let frames: [Frame]
        func perform(_ request: APIRequest) async throws -> APIResponse {
            XCTFail("the event subscription never performs request/response calls")
            return APIResponse(statusCode: 500, payload: .empty)
        }
        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    for frame in frames {
                        switch frame {
                        case .event(let event):
                            continuation.yield(event)
                        case .delayed(let nanoseconds, let event):
                            try? await Task.sleep(nanoseconds: nanoseconds)
                            continuation.yield(event)
                        case .fail(let error):
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    continuation.finish()
                }
            }
        }
    }

    private let one = OpenCodeDomain.Host(
        id: HostID(rawValue: "host_one"),
        displayName: "Mock A",
        address: URL(string: "http://host_one.local:4097")!,
        createdAt: Date(timeIntervalSince1970: 0),
        lastVersion: nil
    )

    private func event(_ type: String, sessionID: String? = nil) -> OpenCodeEvent {
        OpenCodeEvent(
            id: "evt",
            type: type,
            data: .object(sessionID.map { ["sessionID": .string($0)] } ?? [:])
        )
    }

    private func library(
        log: Log,
        scripts: [[Frame]],
        credentials: [String: BasicCredential?] = ["host_one": BasicCredential(secret: "t")]
    ) -> EventLibrary {
        let library = EventLibrary(
            makeTransport: { _, _ in
                // Script per build; past the scripts, an empty stream
                // (instant clean end) keeps the loop from wedging.
                let index = log.nextBuildIndex()
                return ScriptedTransport(frames: index < scripts.count ? scripts[index] : [])
            },
            sleep: { seconds in
                // The documented ladder is observed in real seconds;
                // tests wait on the RECORD, never on wall time.
                log.recordSleep(Double(seconds))
                try? await Task.sleep(nanoseconds: 30_000_000)
            },
            jitter: { $0 },
            credentialProvider: { id in credentials[id.rawValue] ?? nil }
        )
        library.onEvent = { event in log.record(event) }
        return library
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // Generous budget: the suite runs in parallel workers, so
        // a loaded sim can stretch any single poll loop.
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not reached in time", file: file, line: line)
    }

    // MARK: - Delivery

    func testDeliversEventsAndGoesLiveOnTheOpeningFrame() async {
        let log = Log()
        let library = library(log: log, scripts: [
            [
                .event(event("server.connected")),
                // A delayed second frame keeps the LIVE phase observable:
                // with instant streams the clean end moves the phase on
                // within microseconds of the first delivery.
                .delayed(300_000_000, event("session.execution.started", sessionID: "ses_a")),
            ],
        ])
        library.watch(host: one)
        await waitUntil { library.phase == .live }
        await waitUntil { log.events.count == 2 }

        XCTAssertEqual(log.events.map(\.type), ["server.connected", "session.execution.started"])
        library.stop()
        XCTAssertEqual(library.phase, .idle)
    }

    // MARK: - The reconnect ladder

    func testCleanStreamEndReconnectsWithTheDocumentedLadder() async {
        let log = Log()
        let library = library(log: log, scripts: [
            [.event(event("server.connected"))],   // ends cleanly -> 1s
            [],                                     // ends cleanly -> 2s
            [],
        ])
        library.watch(host: one)
        // Both observed ends raise the ladder: 1, then 2.
        await waitUntil { log.sleeps.count == 2 }

        XCTAssertEqual(log.sleeps, [1, 2], "clean closes are transient failures on the documented ladder")
        XCTAssertEqual(log.events.map(\.type), ["server.connected"], "each (re)connect starts from the opening frame")
        library.stop()
    }

    func testDeliveredFramesResetTheLadder() async {
        let log = Log()
        let library = library(log: log, scripts: [
            [.event(event("server.connected"))],   // delivered, then dies -> 1s
            [.event(event("server.connected"))],   // delivered again -> 1s, not 2s
            [],
        ])
        library.watch(host: one)
        await waitUntil { log.sleeps.count == 2 }

        XCTAssertEqual(log.sleeps, [1, 1], "a delivered frame proves the connection: the ladder restarts at 1")
        library.stop()
    }

    func testJitteredDelayFollowsTheDocumentedLadder() {
        let log = Log()
        let library = library(log: log, scripts: [])
        for (failures, expected) in zip(1...7, [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 60.0]) {
            XCTAssertEqual(library.jitteredDelay(failures), expected)
        }
        XCTAssertEqual(library.jitteredDelay(9), 60, "beyond the ladder stays capped at 60s")
    }

    func testJitterIsAppliedAndCapped() {
        let library = EventLibrary(
            makeTransport: { _, _ in ScriptedTransport(frames: []) },
            sleep: { _ in },
            jitter: { $0 * 10 },
            credentialProvider: { _ in BasicCredential(secret: "t") }
        )
        XCTAssertEqual(library.jitteredDelay(1), 10, "the injected jitter scales the base delay")
        XCTAssertEqual(library.jitteredDelay(7), 60, "the 60s cap survives any jitter")
    }

    // MARK: - Failure stops

    func testAuthenticationFailureStopsWithRepairRequired() async {
        let log = Log()
        let library = library(log: log, scripts: [
            [.fail(.http(status: 401, envelope: nil))],
            [.event(event("server.connected"))],  // must never be reached
        ])
        library.watch(host: one)
        await waitUntil {
            if case .repairRequired = library.phase { return true }
            return false
        }

        guard case .repairRequired(let message) = library.phase else {
            return XCTFail("expected repairRequired, got \(library.phase)")
        }
        XCTAssertEqual(message, "Re-pair this host to follow its events.")
        XCTAssertTrue(log.sleeps.isEmpty, "an authentication failure never retries")
        XCTAssertEqual(log.builds, 1, "no second subscription is opened")
    }

    func testMissingCredentialNeverSubscribes() async {
        let log = Log()
        let library = library(log: log, scripts: [[.event(event("server.connected"))]], credentials: [:])
        library.watch(host: one)
        await waitUntil {
            if case .repairRequired = library.phase { return true }
            return false
        }

        XCTAssertEqual(log.builds, 0, "no credential, no subscription")
        XCTAssertTrue(log.sleeps.isEmpty)
    }

    // MARK: - Lifecycle

    func testStopDuringBackoffEndsTheLoop() async {
        let log = Log()
        let library = library(log: log, scripts: [
            [.fail(.connectionFailed("host asleep"))],
            [.event(event("server.connected"))],  // must never be reached
        ])
        library.watch(host: one)
        await waitUntil { log.sleeps.count == 1 }

        library.stop()
        // The sleeping loop resumes with a stale token and exits
        // without building the next transport.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(log.builds, 1)
        XCTAssertEqual(library.phase, .idle)
    }

    func testSecondWatchSupersedesTheFirstLoop() async {
        let log = Log()
        let library = library(log: log, scripts: [
            [.delayed(100_000_000, event("server.connected"))],  // first loop, superseded mid-flight
            [.event(event("session.status", sessionID: "ses_a"))],
        ])
        library.watch(host: one)
        await waitUntil { log.builds == 1 }

        library.watch(host: one)
        await waitUntil { log.events.count == 1 }
        // The first loop's delayed frame lands AFTER its generation
        // was superseded — it must never reach the reconciler.
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(log.events.map(\.type), ["session.status"], "only the current loop delivers")
        library.stop()
    }
}
