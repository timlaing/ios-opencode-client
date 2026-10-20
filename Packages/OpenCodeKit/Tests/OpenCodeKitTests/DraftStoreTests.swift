import XCTest
@testable import OpenCodeStorage

final class DraftStoreTests: XCTestCase {
    func testUpsertFetchUpdateDelete() throws {
        let store = try DraftStore(inMemory: ())
        let draft = Draft(id: "d1", hostUUID: "host-1", directory: "/srv/demo", text: "hello")
        try store.upsert(draft)

        let fetched = try XCTUnwrap(store.draft(id: "d1"))
        XCTAssertEqual(fetched.text, "hello")

        var updated = fetched
        updated.text = "hello world"
        try store.upsert(updated)
        XCTAssertEqual(try XCTUnwrap(store.draft(id: "d1")).text, "hello world")

        try store.deleteDraft(id: "d1")
        XCTAssertNil(try store.draft(id: "d1"))
    }

    func testScopeQueryReturnsNewestFirstAndIsolatesScopes() throws {
        let store = try DraftStore(inMemory: ())
        var older = Draft(id: "a", hostUUID: "h1", directory: "/d", text: "older")
        older.updatedAt = Date(timeIntervalSince1970: 1000)
        var newer = Draft(id: "b", hostUUID: "h1", directory: "/d", text: "newer")
        newer.updatedAt = Date(timeIntervalSince1970: 2000)
        let otherScope = Draft(id: "c", hostUUID: "h1", directory: "/other", text: "other")

        for draft in [older, newer, otherScope] { try store.upsert(draft) }

        let scoped = try store.drafts(hostUUID: "h1", directory: "/d", sessionID: nil)
        XCTAssertEqual(scoped.map(\.id), ["b", "a"])
    }

    func testAllDraftsReturnsEveryScopeNewestFirst() throws {
        let store = try DraftStore(inMemory: ())
        var older = Draft(id: "a", hostUUID: "h1", directory: "/d", text: "older")
        older.updatedAt = Date(timeIntervalSince1970: 1000)
        var newer = Draft(id: "b", hostUUID: "h2", directory: "/other", text: "newer")
        newer.updatedAt = Date(timeIntervalSince1970: 2000)

        XCTAssertEqual(try store.allDrafts(), [], "an empty store answers with nothing")

        for draft in [older, newer] { try store.upsert(draft) }
        let all = try store.allDrafts()
        XCTAssertEqual(all.map(\.id), ["b", "a"], "cross-scope, newest first — S19 confirms against every draft")
    }

    func testPruneRemovesOnlyExpiredDrafts() throws {
        let store = try DraftStore(inMemory: ())
        var stale = Draft(id: "stale", hostUUID: "h1", text: "old")
        stale.updatedAt = Date(timeIntervalSince1970: 0)
        let fresh = Draft(id: "fresh", hostUUID: "h1", text: "new")
        for draft in [stale, fresh] { try store.upsert(draft) }

        try store.deleteDrafts(olderThan: Date(timeIntervalSince1970: 86_400))
        XCTAssertNil(try store.draft(id: "stale"))
        XCTAssertNotNil(try store.draft(id: "fresh"))
    }
}
