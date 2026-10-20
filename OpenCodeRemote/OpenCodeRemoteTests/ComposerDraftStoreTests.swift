import XCTest
import OpenCodeStorage
@testable import OpenCodeRemote

/// W17 drafts: restore is expiry-aware, empty text deletes, records
/// are per host+session, and the retention sweep is the docs' policy
/// applied literally (implementation-defaults.md "Drafts").
@MainActor
final class ComposerDraftStoreTests: XCTestCase {
    private var suiteName: String!
    private var drafts: DraftStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ComposerDraftStoreTests-\(UUID().uuidString)"
        drafts = try DraftStore(inMemory: ())
    }

    override func tearDown() {
        drafts = nil
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func settings(_ mutate: (inout SettingsState) -> Void = { _ in }) -> SettingsLibrary {
        let library = SettingsLibrary(defaults: UserDefaults(suiteName: suiteName)!)
        library.update(mutate)
        return library
    }

    private var store: ComposerDraftStore { ComposerDraftStore(drafts: drafts) }

    func testSaveAndRestoreRoundTripOneConversation() {
        store.save("half a thought", hostUUID: "h1", sessionID: "ses_a")

        XCTAssertEqual(
            store.restore(hostUUID: "h1", sessionID: "ses_a", settings: settings()),
            "half a thought"
        )
    }

    func testDraftsAreIsolatedPerHostAndSession() {
        store.save("for h1", hostUUID: "h1", sessionID: "ses_a")

        XCTAssertNil(store.restore(hostUUID: "h2", sessionID: "ses_a", settings: settings()), "server session IDs can collide across hosts")
        XCTAssertNil(store.restore(hostUUID: "h1", sessionID: "ses_b", settings: settings()))

        store.save("for ses_b", hostUUID: "h1", sessionID: "ses_b")
        XCTAssertEqual(store.restore(hostUUID: "h1", sessionID: "ses_a", settings: settings()), "for h1")
        XCTAssertEqual(store.restore(hostUUID: "h1", sessionID: "ses_b", settings: settings()), "for ses_b")
    }

    func testEmptyTextDeletesTheDraft() {
        store.save("typed", hostUUID: "h1", sessionID: "ses_a")
        store.save("", hostUUID: "h1", sessionID: "ses_a")

        XCTAssertNil(store.restore(hostUUID: "h1", sessionID: "ses_a", settings: settings()))
        XCTAssertEqual(try drafts.allDrafts(), [], "sent or discarded leaves no husk behind")
    }

    func testReSavingTheSameConversationReplacesRatherThanStacks() {
        store.save("first", hostUUID: "h1", sessionID: "ses_a")
        store.save("second", hostUUID: "h1", sessionID: "ses_a")

        XCTAssertEqual(try drafts.allDrafts().count, 1)
        XCTAssertEqual(store.restore(hostUUID: "h1", sessionID: "ses_a", settings: settings()), "second")
    }

    func testRestoreDeletesAnExpiredDraftOnSight() throws {
        var ancient = Draft(
            id: ComposerDraftStore.draftID(hostUUID: "h1", sessionID: "ses_a"),
            hostUUID: "h1",
            sessionID: "ses_a",
            text: "too old"
        )
        ancient.updatedAt = Date().addingTimeInterval(-8 * 86_400)
        try drafts.upsert(ancient)

        let restored = store.restore(
            hostUUID: "h1", sessionID: "ses_a",
            settings: settings { $0.draftRetention = .days(7) }
        )

        XCTAssertNil(restored, "a 7-day policy does not restore an 8-day-old draft")
        XCTAssertEqual(try drafts.allDrafts(), [], "expiry is applied, not merely displayed")
    }

    func testUntilDiscardedKeepsAncientDrafts() throws {
        var ancient = Draft(
            id: ComposerDraftStore.draftID(hostUUID: "h1", sessionID: "ses_a"),
            hostUUID: "h1",
            sessionID: "ses_a",
            text: "kept forever"
        )
        ancient.updatedAt = Date().addingTimeInterval(-400 * 86_400)
        try drafts.upsert(ancient)

        XCTAssertEqual(
            store.restore(hostUUID: "h1", sessionID: "ses_a", settings: settings()),
            "kept forever",
            "the default retention never expires"
        )
    }

    func testWhitespaceOnlyTextIsStoredExactlyAsTyped() {
        store.save("  indented\n", hostUUID: "h1", sessionID: "ses_a")

        XCTAssertEqual(
            store.restore(hostUUID: "h1", sessionID: "ses_a", settings: settings()),
            "  indented\n",
            "the draft preserves raw text — trimming is the send path's job"
        )
    }

    func testRetentionSweepRemovesExpiredAcrossScopesAndKeepsFresh() throws {
        var staleA = Draft(id: "a", hostUUID: "h1", sessionID: "ses_a", text: "stale")
        staleA.updatedAt = Date().addingTimeInterval(-10 * 86_400)
        var staleB = Draft(id: "b", hostUUID: "h2", sessionID: "ses_b", text: "also stale")
        staleB.updatedAt = Date().addingTimeInterval(-9 * 86_400)
        var fresh = Draft(id: "c", hostUUID: "h1", sessionID: "ses_c", text: "fresh")
        fresh.updatedAt = Date().addingTimeInterval(-1 * 86_400)
        for draft in [staleA, staleB, fresh] { try drafts.upsert(draft) }

        store.applyRetention(settings { $0.draftRetention = .days(7) })

        XCTAssertEqual(try drafts.allDrafts().map(\.id), ["c"], "expired drafts die across every scope; fresh ones survive")
    }

    func testRetentionSweepUnderUntilDiscardedRemovesNothing() throws {
        var ancient = Draft(id: "a", hostUUID: "h1", sessionID: "ses_a", text: "ancient")
        ancient.updatedAt = Date().addingTimeInterval(-400 * 86_400)
        try drafts.upsert(ancient)

        store.applyRetention(settings())

        XCTAssertEqual(try drafts.allDrafts().map(\.id), ["a"])
    }
}
