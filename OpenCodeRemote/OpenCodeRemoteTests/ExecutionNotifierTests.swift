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
        private var _authorizationGate: AsyncStream<Void>?
        private var _posted: [(identifier: String, title: String, body: String)] = []

        /// Optional gate so a test can hold the consent ask open and
        /// flip sceneActive mid-flight (review W16 r12). Nil = the
        /// instant behaviour every other test relies on.
        var authorizationGate: AsyncStream<Void>? {
            get { lock.lock(); defer { lock.unlock() }; return _authorizationGate }
            set { lock.lock(); _authorizationGate = newValue; lock.unlock() }
        }

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
            let (result, gate) = lock.withLock {
                _authorizationRequests += 1
                return (_authorized, _authorizationGate)
            }
            if let gate {
                // Held until the test releases it — this models the
                // OS alert being on screen.
                for await _ in gate { break }
            }
            return result
        }

        func post(identifier: String, title: String, body: String) async {
            lock.withLock {
                _posted.append((identifier, title, body))
            }
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

    /// The copy these tests pin is the DETAILED mode: the session
    /// title and the outcome phrase, with every category enabled.
    private let detailed = NotificationDeliveryPolicy(
        contentPrivacy: .detailed,
        categories: NotificationCategories()
    )

    // MARK: - Delivery gates

    func testPostsOnceForAStableEventIdentity() async {
        let fake = FakeNotifier()
        let notifier = notifier(fake)
        notifier.sceneActive = false

        await notifier.handleTerminal(
            terminal("session.execution.succeeded", id: "evt_1"), sessionTitle: "Demo session",
            policy: detailed
        )
        await notifier.handleTerminal(
            terminal("session.execution.succeeded", id: "evt_1"), sessionTitle: "Demo session",
            policy: detailed
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
            terminal("session.execution.succeeded", id: "evt_1"), sessionTitle: nil,
            policy: detailed
        )
        XCTAssertTrue(fake.posted.isEmpty, "a watched terminal needs no banner")

        // Skipping while active must NOT consume anything: a later
        // terminal (this stream never replays, so it is necessarily a
        // different event) still banners.
        notifier.sceneActive = false
        await notifier.handleTerminal(
            terminal("session.execution.failed", id: "evt_2"), sessionTitle: nil,
            policy: detailed
        )
        XCTAssertEqual(fake.posted.count, 1, "the gate suppresses only while active")
        XCTAssertEqual(fake.posted.first?.title, "OpenCode Client", "no session title falls back to the display name")
        XCTAssertEqual(fake.posted.first?.body, "The turn failed.")
    }

    func testAnsweringTheConsentAlertDoesNotPostAnInterruptingBanner() async {
        let fake = FakeNotifier()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        fake.authorizationGate = gate
        let notifier = notifier(fake)
        notifier.sceneActive = false // the app switcher, when the terminal arrives

        let posting = Task {
            await notifier.handleTerminal(
                terminal("session.execution.succeeded", id: "evt_1"), sessionTitle: nil,
                policy: detailed
            )
        }
        // Wait until the consent alert is actually on screen...
        var polls = 0
        while fake.authorizationRequests == 0, polls < 200 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            polls += 1
        }
        XCTAssertEqual(fake.authorizationRequests, 1, "the consent ask is on screen")
        // ...then the user taps Allow, which returns the app to the
        // foreground while the post awaits the answer.
        notifier.sceneActive = true
        gateContinuation.yield()
        await posting.value

        XCTAssertTrue(
            fake.posted.isEmpty,
            "the user is watching the screen again by now — the re-check after the consent await suppresses exactly who the gate protects (review W16 r12)"
        )
    }

    func testOutcomeCopyMatchesTheCanonicalTransition() async {
        let fake = FakeNotifier()
        let notifier = notifier(fake)
        notifier.sceneActive = false

        await notifier.handleTerminal(terminal("session.execution.failed", id: "f"), sessionTitle: nil, policy: detailed)
        await notifier.handleTerminal(terminal("session.execution.interrupted", id: "i"), sessionTitle: nil, policy: detailed)

        XCTAssertEqual(fake.posted.map(\.body), ["The turn failed.", "The turn was stopped."])
    }

    func testDeniedConsentNeverPostsAndAsksOnlyOnce() async {
        let fake = FakeNotifier()
        fake.authorized = false
        let notifier = notifier(fake)
        notifier.sceneActive = false

        await notifier.prepare()
        await notifier.handleTerminal(terminal("session.execution.succeeded", id: "d1"), sessionTitle: nil, policy: detailed)
        await notifier.prepare()
        await notifier.handleTerminal(terminal("session.execution.failed", id: "d2"), sessionTitle: nil, policy: detailed)

        XCTAssertTrue(fake.posted.isEmpty, "denied consent never posts")
        XCTAssertEqual(fake.authorizationRequests, 1, "one lazy ask — the OS decision is cached, never re-prompted")
    }

    func testIdlessAndUnknownEventsAreNeverPosted() async {
        let fake = FakeNotifier()
        // ONE defaults domain for the notifier AND the assertion: a
        // second freshDefaults() would read an empty domain the
        // notifier never wrote to.
        let defaults = freshDefaults()
        let notifier = ExecutionNotifier(
            notifier: fake, dedup: NotificationDedupStore(defaults: defaults)
        )
        notifier.sceneActive = false

        // An id-less event cannot be deduplicated — a duplicate
        // banner is worse than a missed one.
        await notifier.handleTerminal(terminal("session.execution.succeeded", id: nil), sessionTitle: nil, policy: detailed)
        // Only the three canonical transitions banner.
        await notifier.handleTerminal(terminal("session.execution.vibing", id: "v"), sessionTitle: nil, policy: detailed)

        XCTAssertTrue(fake.posted.isEmpty)
        XCTAssertFalse(
            NotificationDedupStore(defaults: defaults).alreadyPosted("v"),
            "an unknown type never consumes the identity — a later canonical event may still banner"
        )
    }

    // MARK: - The S17 policy (review W17 r1)

    func testGenericContentNeverNamesTheSessionOrTheOutcome() async {
        let fake = FakeNotifier()
        let notifier = notifier(fake)
        notifier.sceneActive = false

        // nil privacy = onboarding has not asked yet: content stays
        // GENERIC (S17 footer; WelcomeView promise).
        await notifier.handleTerminal(
            terminal("session.execution.succeeded", id: "g1"),
            sessionTitle: "Demo session",
            policy: NotificationDeliveryPolicy(contentPrivacy: nil, categories: NotificationCategories())
        )

        XCTAssertEqual(fake.posted.count, 1)
        XCTAssertEqual(fake.posted.first?.title, "OpenCode Client", "generic content never carries the session title")
        XCTAssertEqual(fake.posted.first?.body, "Open the app for details.", "generic content never carries outcome text")
    }

    func testDisabledCategoryNeverPostsAndNeverSpendsTheAsk() async {
        let fake = FakeNotifier()
        let notifier = notifier(fake)
        notifier.sceneActive = false
        var categories = NotificationCategories()
        categories.failed = false

        await notifier.handleTerminal(
            terminal("session.execution.failed", id: "c1"),
            sessionTitle: nil,
            policy: NotificationDeliveryPolicy(contentPrivacy: .detailed, categories: categories)
        )

        XCTAssertTrue(fake.posted.isEmpty, "only the enabled outcomes notify (S17)")
        XCTAssertEqual(fake.authorizationRequests, 0, "a disabled category never spends the OS consent ask")
    }

    func testPermissionOutcomeIsRecordedOncePerProcessNotOncePerOpen() async {
        let logDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecutionNotifierTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let log = DiagnosticsLogStore(directory: logDirectory)
        ExecutionNotifier.lastRecordedAuthorization = nil

        // Denied is the spam case: every conversation open used to
        // append another identical .error entry (review W17 r5).
        let fake = FakeNotifier()
        fake.authorized = false

        let first = notifier(fake)
        first.diagnostics = log
        await first.prepare()
        // A second open — a FRESH notifier, same process.
        let second = notifier(fake)
        second.diagnostics = log
        await second.prepare()

        let copies = log.entries().filter { $0.message.contains("not granted") }
        XCTAssertEqual(copies.count, 1, "the permission outcome records once per process, not once per conversation open")

        // A mid-process change IS a new outcome — it records again.
        fake.authorized = true
        let third = notifier(fake)
        third.diagnostics = log
        await third.prepare()
        XCTAssertEqual(
            log.entries().filter { $0.message == "Notification permission granted" }.count,
            1,
            "an outcome change records the new fact"
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

    func testOnlyExecutionBannersPresentWhileTheAppIsForeground() {
        let options = ExecutionNotificationPresenter.options(for: "opencode.execution.evt_1")
        XCTAssertTrue(
            options.contains(.banner),
            "the inactive-window target IS the app-switcher/Control Center case — silent delivery there would miss it (review W16 r10)"
        )
        XCTAssertTrue(options.contains(.sound), "the posted content carries the default sound")
        XCTAssertTrue(
            ExecutionNotificationPresenter.options(for: "uk.co.laingcorp.opencode-client.other").isEmpty,
            "every other notification keeps the system's own presentation rules"
        )
    }
}
