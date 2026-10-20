import XCTest
import OpenCodeTransport
@testable import OpenCodeRemote

/// W16 S17 initial local notifications (docs/api-contract.md W16,
/// docs/implementation-defaults.md notification rules): the
/// active/dedup/consent gates, the canonical outcome copy, and the
/// seven-day / 10,000-entry dedup window.
@MainActor
final class ExecutionNotifierTests: XCTestCase {
    /// Thread-safe test double for the OS touch points.
    private final class FakeNotifier: UserNotifying, @unchecked Sendable {
        private let lock = NSLock()
        private var _authorized = true
        private var _authorizationRequests = 0
        private var _posted: [(identifier: String, title: String, body: String)] = []

        var authorized: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _authorized }
            set { lock.lock(); _authorized = newValue; lock.unlock() }
        }
        var authorizationRequests: Int {
            lock.lock(); defer { lock.unlock() }; return _authorizationRequests
        }
        var posted: [(identifier: String, title: String, body: String)] {
            lock.lock(); defer { lock.unlock() }; return _posted
        }

        func requestAuthorization() async -> Bool {
            lock.lock()
            _authorizationRequests += 1
            let result = _authorized
            lock.unlock()
            return result
        }

        func post(identifier: String, title: String, body: String) async {
            lock.lock()
            _posted.append((identifier, title, body))
            lock.unlock()
        }
    }

    /// A fresh domain per test — the store must not leak between tests.
    private func freshDefaults() -> UserDefaults {
        let suite = "ExecutionNotifierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func terminal(_ type: String, id: String?) -> OpenCodeEvent {
        OpenCodeEvent(id: id, type: type, data: .object(["sessionID": .string("ses_a")]))
    }

    private func notifier(
        _ fake: FakeNotifier,
        now: @escaping () -> Date = { Date() },
        ceiling: Int = NotificationDedupStore.ceiling,
        retention: TimeInterval = NotificationDedupStore.retention
    ) -> ExecutionNotifier {
        ExecutionNotifier(
            notifier: fake,
            dedup: NotificationDedupStore(
                defaults: freshDefaults(), retention: retention, ceiling: ceiling, now: now
            )
        )
    }

    // MARK: - Delivery gates

    func testPostsOnceForAStableEventIdentity() async {
        let fake = FakeNotifier()
        let notifier = notifier(fake)
        notifier.sceneActive = false

        await notifier.handleTerminal(
            terminal("session.execution.succeeded", id: "evt_1"), sessionTitle: "Demo session"
        )
        await notifier.handleTerminal(
            terminal("session.execution.succeeded", id: "evt_1"), sessionTitle: "Demo session"
        )

        XCTAssertEqual(fake.posted.count, 1, "the server's event id is a stable identity: one banner")
        XCTAssertEqual(fake.posted.first?.identifier, "opencode.execution.evt_1")
        XCTAssertEqual(fake.posted.first?.title, "Demo session")
        XCTAssertEqual(fake.posted.first?.body, "The turn completed.")
    }

    func testNeverBannersWhileTheAppIsActive() async {
        let fake = FakeNotifier()
        let notifier = notifier(fake)
        notifier.sceneActive = true

        await notifier.handleTerminal(
            terminal("session.execution.succeeded", id: "evt_1"), sessionTitle: nil
        )
        XCTAssertTrue(fake.posted.isEmpty, "a watched terminal needs no banner")

        // Skipping while active must NOT consume anything: a later
        // terminal (this stream never replays, so it is necessarily a
        // different event) still banners.
        notifier.sceneActive = false
        await notifier.handleTerminal(
            terminal("session.execution.failed", id: "evt_2"), sessionTitle: nil
        )
        XCTAssertEqual(fake.posted.count, 1, "the gate suppresses only while active")
        XCTAssertEqual(fake.posted.first?.title, "OpenCode Client", "no session title falls back to the display name")
        XCTAssertEqual(fake.posted.first?.body, "The turn failed.")
    }

    func testOutcomeCopyMatchesTheCanonicalTransition() async {
        let fake = FakeNotifier()
        let notifier = notifier(fake)
        notifier.sceneActive = false

        await notifier.handleTerminal(terminal("session.execution.failed", id: "f"), sessionTitle: nil)
        await notifier.handleTerminal(terminal("session.execution.interrupted", id: "i"), sessionTitle: nil)

        XCTAssertEqual(fake.posted.map(\.body), ["The turn failed.", "The turn was stopped."])
    }

    func testDeniedConsentNeverPostsAndAsksOnlyOnce() async {
        let fake = FakeNotifier()
        fake.authorized = false
        let notifier = notifier(fake)
        notifier.sceneActive = false

        await notifier.prepare()
        await notifier.handleTerminal(terminal("session.execution.succeeded", id: "d1"), sessionTitle: nil)
        await notifier.prepare()
        await notifier.handleTerminal(terminal("session.execution.failed", id: "d2"), sessionTitle: nil)

        XCTAssertTrue(fake.posted.isEmpty, "denied consent never posts")
        XCTAssertEqual(fake.authorizationRequests, 1, "one lazy ask — the OS decision is cached, never re-prompted")
    }

    func testIdlessAndUnknownEventsAreNeverPosted() async {
        let fake = FakeNotifier()
        let notifier = notifier(fake)
        notifier.sceneActive = false

        // An id-less event cannot be deduplicated — a duplicate
        // banner is worse than a missed one.
        await notifier.handleTerminal(terminal("session.execution.succeeded", id: nil), sessionTitle: nil)
        // Only the three canonical transitions banner.
        await notifier.handleTerminal(terminal("session.execution.vibing", id: "v"), sessionTitle: nil)

        XCTAssertTrue(fake.posted.isEmpty)
        XCTAssertFalse(
            NotificationDedupStore(defaults: freshDefaults()).alreadyPosted("v"),
            "an unknown type never consumes the identity — a later canonical event may still banner"
        )
    }

    // MARK: - The dedup window

    func testDedupStorePrunesBeyondSevenDays() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var current = start
        let store = NotificationDedupStore(defaults: freshDefaults(), now: { current })

        store.markPosted("old")
        XCTAssertTrue(store.alreadyPosted("old"))

        current = start.addingTimeInterval(8 * 24 * 60 * 60)
        XCTAssertFalse(store.alreadyPosted("old"), "identities expire after the seven-day window")
    }

    func testDedupStoreHonorsTheEntryCeiling() async {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var current = start
        let store = NotificationDedupStore(defaults: freshDefaults(), ceiling: 3, now: { current })

        for index in 0..<3 {
            current = start.addingTimeInterval(Double(index))
            store.markPosted("e\(index)")
        }
        current = start.addingTimeInterval(10)
        store.markPosted("e3")

        XCTAssertFalse(store.alreadyPosted("e0"), "the oldest identity is evicted at the ceiling")
        XCTAssertTrue(store.alreadyPosted("e3"), "the newest identity always fits")
        XCTAssertTrue(store.alreadyPosted("e1"))
        XCTAssertTrue(store.alreadyPosted("e2"))
    }
}
