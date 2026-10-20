import XCTest
import OpenCodeDomain
@testable import OpenCodeRemote

/// Device-local session state (docs/navigation-screens.md S07): pinned/
/// followed/hidden are persisted app-locally, keyed host+session so
/// colliding server IDs across hosts stay distinct, and survive relaunch.
@MainActor
final class SessionLocalStateStoreTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SessionLocalStateStoreTests-\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    private func makeKey(host: String = "host_one", session: String) -> SessionKey {
        SessionKey(hostID: HostID(rawValue: host), sessionID: session)
    }

    func testTogglesMutateAndPersistAcrossRelaunch() {
        let store = SessionLocalStateStore(defaults: defaults)
        let key = makeKey(session: "ses_a")

        XCTAssertTrue(store.togglePinned(key))
        XCTAssertTrue(store.toggleFollowed(key))
        XCTAssertTrue(store.toggleHidden(key))
        XCTAssertEqual(store.followedSessionIDs, ["ses_a"])

        // A second store over the same defaults = app relaunch.
        let reloaded = SessionLocalStateStore(defaults: defaults)
        XCTAssertTrue(reloaded.isPinned(key))
        XCTAssertTrue(reloaded.isFollowed(key))
        XCTAssertTrue(reloaded.isHidden(key))

        XCTAssertFalse(reloaded.togglePinned(key))
        XCTAssertFalse(reloaded.isPinned(key))
        XCTAssertTrue(reloaded.isFollowed(key), "toggling one state never touches the others")
    }

    func testSameSessionIDOnDifferentHostsStaysDistinct() {
        let store = SessionLocalStateStore(defaults: defaults)
        let onOne = makeKey(host: "host_one", session: "ses_shared")
        let onTwo = makeKey(host: "host_two", session: "ses_shared")

        store.togglePinned(onOne)

        XCTAssertTrue(store.isPinned(onOne), "server IDs are only unique per server")
        XCTAssertFalse(store.isPinned(onTwo), "another host's identically-named session is untouched")
    }

    func testStorageFormRoundTripsAndRejectsGarbage() {
        let key = makeKey(host: "host_one", session: "ses_a")
        XCTAssertEqual(key.storage, "host_one/ses_a")
        XCTAssertEqual(SessionKey(storage: "host_one/ses_a"), key)
        XCTAssertNil(SessionKey(storage: "no-separator"), "malformed persisted rows are dropped, not guessed")
        XCTAssertNil(SessionKey(storage: "/ses_a"), "empty host segment is dropped")
    }

    func testFreshDefaultsStartEmpty() {
        let store = SessionLocalStateStore(defaults: defaults)
        XCTAssertTrue(store.state.pinned.isEmpty)
        XCTAssertTrue(store.state.followed.isEmpty)
        XCTAssertTrue(store.state.hidden.isEmpty)
    }

    func testClearLocalDataWipesStateForThisAndEveryFutureReader() {
        let live = SessionLocalStateStore(defaults: defaults)
        live.togglePinned(makeKey(session: "ses_a"))
        live.toggleFollowed(makeKey(session: "ses_a"))
        live.toggleHidden(makeKey(session: "ses_b"))

        live.clear()

        XCTAssertTrue(live.state.pinned.isEmpty, "the LIVE instance empties at once — Observation readers update without a relaunch")
        XCTAssertTrue(live.state.followed.isEmpty, "followed IDs are the push eligibility source: the wipe must reach them")
        XCTAssertTrue(live.state.hidden.isEmpty)

        let relaunched = SessionLocalStateStore(defaults: defaults)
        XCTAssertTrue(relaunched.state.followed.isEmpty, "the clear persists — not an in-memory illusion")
    }
}
