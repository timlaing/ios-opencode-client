import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// HostEventSupervisor lifecycle tests (docs/local-push-implementation.md
/// §"Provider start, configuration changes, timer and stop" and the derived
/// native test list): single stream per host, jittered backoff, no retries
/// after auth rejection, generation-safe stops, no timer duplication.
final class HostEventSupervisorTests: XCTestCase {
    // MARK: - Test doubles

    private final class ScriptedTransport: OpenCodeTransport, @unchecked Sendable {
        enum Script {
            /// Yield the events, then finish cleanly.
            case finish([OpenCodeEvent])
            /// Yield the events and keep the stream open (healthy host).
            case open([OpenCodeEvent])
            case fail(TransportError)
        }

        private let lock = NSLock()
        private var scripts: [Script]
        private var connects = 0
        private var openContinuations: [AsyncThrowingStream<OpenCodeEvent, Error>.Continuation] = []

        init(_ scripts: [Script]) { self.scripts = scripts }

        func perform(_ request: APIRequest) async throws -> APIResponse {
            XCTFail("supervisor must not use request/response APIs")
            throw TransportError.connectionFailed("unused")
        }

        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            let script: Script = lock.withLock {
                defer { connects += 1 }
                return connects < scripts.count ? scripts[connects] : .fail(.connectionFailed("scripts exhausted"))
            }
            return AsyncThrowingStream { continuation in
                switch script {
                case .finish(let events):
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                case .open(let events):
                    for event in events { continuation.yield(event) }
                    lock.withLock { openContinuations.append(continuation) }
                case .fail(let error):
                    continuation.finish(throwing: error)
                }
            }
        }

        var connectCount: Int { lock.withLock { connects } }

        func finishOpenStreams() {
            let pending = lock.withLock { openContinuations }
            pending.forEach { $0.finish() }
        }
    }

    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []
        func append(_ value: Value) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [Value] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private final class Sleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var delays: [Duration] = []
        func sleep(_ duration: Duration) throws {
            lock.lock(); delays.append(duration); lock.unlock()
            // A real (tiny) delay keeps the retry loop from spinning past
            // the test's observation windows.
            Thread.sleep(forTimeInterval: 0.001)
        }
        var recorded: [Duration] { lock.lock(); defer { lock.unlock() }; return delays }
    }

    private struct Environment {
        let supervisor: HostEventSupervisor
        let transport: ScriptedTransport
        let sleeper: Sleeper
        let statuses: Recorder<HostStreamStatus>
        let drafts: Recorder<NotificationDraft>
        let reconciles: Recorder<Int>
    }

    private func makeSupervisor(
        scripts: [ScriptedTransport.Script],
        followed: Set<String> = ["ses_a"],
        jitter: @escaping @Sendable () -> Double = { 1.0 }
    ) -> Environment {
        let transport = ScriptedTransport(scripts)
        let sleeper = Sleeper()
        let statuses = Recorder<HostStreamStatus>()
        let drafts = Recorder<NotificationDraft>()
        let reconciles = Recorder<Int>()
        let host = OpenCodeDomain.Host(
            id: HostID(rawValue: "host_1"),
            displayName: "Mock",
            address: URL(string: "http://localhost:4097")!,
            createdAt: Date(timeIntervalSince1970: 0),
            lastVersion: nil
        )
        let supervisor = HostEventSupervisor(
            host: host,
            classifier: EventClassifier(
                hostID: "host_1",
                policy: NotificationPolicy(followedSessions: followed)
            ),
            environment: .init(
                makeTransport: { _, _ in transport },
                credential: { BasicCredential(secret: "token") },
                sleep: { duration in try sleeper.sleep(duration) },
                jitter: jitter,
                now: { Date(timeIntervalSince1970: 5_000) }
            ),
            callbacks: .init(
                onStatus: { status in statuses.append(status) },
                deliver: { draft in drafts.append(draft) },
                onReconnect: { reconciles.append(1) }
            )
        )
        return Environment(
            supervisor: supervisor,
            transport: transport,
            sleeper: sleeper,
            statuses: statuses,
            drafts: drafts,
            reconciles: reconciles
        )
    }

    private func connected(_ id: String = "evt_c") -> OpenCodeEvent {
        OpenCodeEvent(id: id, type: "server.connected", data: .object([:]))
    }

    private func execution(_ type: String, id: String, sessionID: String = "ses_a") -> OpenCodeEvent {
        OpenCodeEvent(id: id, type: type, data: .object(["sessionID": .string(sessionID)]))
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(label)")
    }

    // MARK: - Tests

    func testDeliversClassifiedEventsAndPublishesStatus() async throws {
        let env = makeSupervisor(scripts: [
            .finish([connected(), execution("session.execution.succeeded", id: "evt_done")]),
        ])
        await env.supervisor.start()
        try await waitUntil("draft delivered") { env.drafts.values.count == 1 }
        try await waitUntil("reconnect reconcile fired") { env.reconciles.values.count == 1 }

        XCTAssertEqual(env.drafts.values.first?.category, .sessionCompleted)
        XCTAssertEqual(env.drafts.values.first?.ledgerKey, "host:host_1|session:ses_a|owner:-|transition:evt_done")
        XCTAssertEqual(env.statuses.values.first, .establishing)
        XCTAssertTrue(env.statuses.values.contains(.available), "server.connected marks the stream Available")
        let diagnostics = await env.supervisor.diagnostics
        XCTAssertEqual(diagnostics.receivedEvents, 2)
        XCTAssertEqual(diagnostics.relevantEvents, 1)
    }

    func testTransientFailureBacksOffThenReconnects() async throws {
        let env = makeSupervisor(scripts: [
            .finish([connected()]),
            .fail(.connectionFailed("network drop")),
            .finish([connected(), execution("session.execution.failed", id: "evt_fail")]),
        ])
        await env.supervisor.start()
        try await waitUntil("reconnect after drop") { env.transport.connectCount >= 3 }
        try await waitUntil("second draft") { env.drafts.values.count == 1 }

        XCTAssertEqual(env.drafts.values.first?.category, .sessionFailed)
        XCTAssertEqual(env.sleeper.recorded.first, .seconds(1), "first jittered retry at maximum jitter = 1s")
        let diagnostics = await env.supervisor.diagnostics
        XCTAssertGreaterThanOrEqual(diagnostics.reconnectCount, 2)
        XCTAssertTrue(env.statuses.values.contains(.reconnecting(attempts: 1)))
    }

    func testAuthRejectionStopsBlindRetries() async throws {
        let env = makeSupervisor(scripts: [
            .fail(.http(status: 401, envelope: nil)),
        ])
        await env.supervisor.start()
        try await waitUntil("repair required") { await env.supervisor.diagnostics.status == .repairRequired }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(env.transport.connectCount, 1, "no blind credential retries after rejection")
        XCTAssertEqual(env.sleeper.recorded, [])
        let diagnostics = await env.supervisor.diagnostics
        XCTAssertEqual(diagnostics.lastReason, "credential rejected")
    }

    func testTimerDoesNotDuplicateHealthyStream() async throws {
        let env = makeSupervisor(scripts: [
            .open([connected()]),
        ])
        await env.supervisor.start()
        try await waitUntil("available") { await env.supervisor.diagnostics.status == .available }

        await env.supervisor.handleTimerEvent()
        await env.supervisor.handleTimerEvent()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(env.transport.connectCount, 1, "never a second live stream for a healthy host")
    }

    func testTimerRestartsStoppedObserver() async throws {
        let env = makeSupervisor(scripts: [
            .open([connected()]),
            .open([connected()]),
        ])
        await env.supervisor.start()
        try await waitUntil("available") { await env.supervisor.diagnostics.status == .available }
        await env.supervisor.stop()
        let stoppedStatus = await env.supervisor.diagnostics.status
        XCTAssertEqual(stoppedStatus, .stopped)

        await env.supervisor.handleTimerEvent()
        try await waitUntil("restarted on timer") { env.transport.connectCount == 2 }
    }

    func testStopDuringBackoffCancelsWithoutFurtherConnects() async throws {
        let env = makeSupervisor(scripts: [
            .fail(.connectionFailed("down")),
        ])
        await env.supervisor.start()
        try await waitUntil("backing off") { env.sleeper.recorded.count >= 1 }

        await env.supervisor.stop()
        let stoppedStatus = await env.supervisor.diagnostics.status
        XCTAssertEqual(stoppedStatus, .stopped)
        let connectsAtStop = env.transport.connectCount
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(env.transport.connectCount, connectsAtStop, "stopped generation cannot reconnect")
    }

    func testStaleGenerationStreamFinishIsIgnored() async throws {
        let env = makeSupervisor(scripts: [
            .open([connected()]),
            .finish([connected()]),
        ])
        await env.supervisor.start()
        try await waitUntil("available") { await env.supervisor.diagnostics.status == .available }

        // Simulate the provider generation change: stop, then the old
        // stream reports its end afterwards. The stale callback must not
        // move current state or reconnect.
        await env.supervisor.stop()
        env.transport.finishOpenStreams()
        try await Task.sleep(nanoseconds: 100_000_000)
        let diagnostics = await env.supervisor.diagnostics
        XCTAssertEqual(diagnostics.status, .stopped, "stale generation callbacks cannot restore state")
        XCTAssertEqual(env.transport.connectCount, 1)
        XCTAssertEqual(env.sleeper.recorded, [])
    }

    func testUnfollowedTrafficNeverReachesDelivery() async throws {
        let env = makeSupervisor(scripts: [
            .finish([connected(), execution("session.execution.succeeded", id: "evt_x", sessionID: "ses_other")]),
        ])
        await env.supervisor.start()
        try await waitUntil("both events seen") { await env.supervisor.diagnostics.receivedEvents == 2 }
        let diagnostics = await env.supervisor.diagnostics
        XCTAssertEqual(diagnostics.relevantEvents, 0, "unfollowed traffic is discarded without delivery")
        XCTAssertEqual(env.drafts.values, [])
    }

    func testPolicyUpdateTakesEffectWithoutRestart() async throws {
        let env = makeSupervisor(scripts: [
            .open([connected()]),
        ])
        await env.supervisor.start()
        try await waitUntil("available") { await env.supervisor.diagnostics.status == .available }
        await env.supervisor.updatePolicy(NotificationPolicy(enabled: false))
        XCTAssertEqual(env.transport.connectCount, 1, "policy changes must not disturb a healthy stream")
    }

    // MARK: - Backoff math

    func testBackoffStaysWithinDocumentedBounds() {
        for attempt in 1...12 {
            for jitter in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let delay = HostEventSupervisor.backoffDelay(attempt: attempt, jitter: jitter)
                XCTAssertGreaterThanOrEqual(delay, HostEventSupervisor.minimumBackoff, "attempt \(attempt) jitter \(jitter)")
                XCTAssertLessThanOrEqual(delay, HostEventSupervisor.maximumBackoff, "attempt \(attempt) jitter \(jitter)")
            }
        }
    }

    func testBackoffCapsAtSixtySeconds() {
        XCTAssertEqual(HostEventSupervisor.backoffDelay(attempt: 1, jitter: 1.0), 1)
        XCTAssertEqual(HostEventSupervisor.backoffDelay(attempt: 3, jitter: 1.0), 4)
        XCTAssertEqual(HostEventSupervisor.backoffDelay(attempt: 7, jitter: 1.0), 60)
        XCTAssertEqual(HostEventSupervisor.backoffDelay(attempt: 10, jitter: 1.0), 60)
        XCTAssertEqual(HostEventSupervisor.backoffDelay(attempt: 10, jitter: 0.0), 30, "minimum jitter keeps half the base")
    }
}
