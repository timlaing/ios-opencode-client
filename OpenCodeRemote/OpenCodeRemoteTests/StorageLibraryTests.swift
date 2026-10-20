import XCTest
import OpenCodeStorage
@testable import OpenCodeRemote

/// W17 S19: cache usage counts real bytes, Clear Cache removes
/// contents while keeping the directory (and never reaches drafts),
/// and Clear Local Data's drafts half wipes the app-private store.
final class StorageLibraryTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
        workspace = nil
        try super.tearDownWithError()
    }

    private var cacheDir: URL { workspace.appendingPathComponent("cache", isDirectory: true) }
    private var draftsDir: URL { workspace.appendingPathComponent("drafts", isDirectory: true) }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    func testCacheUsageSumsNestedRegularFilesOnly() throws {
        let library = StorageLibrary(cacheDirectory: cacheDir, draftsDirectory: draftsDir)
        XCTAssertEqual(library.cacheUsageBytes(), 0, "a missing cache directory honestly reads zero")

        try write(100, to: cacheDir.appendingPathComponent("root.bin"))
        try write(50, to: cacheDir.appendingPathComponent("thumbs/nested.bin"))
        try FileManager.default.createDirectory(
            at: cacheDir.appendingPathComponent("just-a-dir"), withIntermediateDirectories: true
        )

        XCTAssertEqual(library.cacheUsageBytes(), 150, "nested files count; directories add no size")
    }

    func testClearCacheEmptiesContentsButKeepsTheDirectory() throws {
        try write(100, to: cacheDir.appendingPathComponent("root.bin"))
        try write(50, to: cacheDir.appendingPathComponent("thumbs/nested.bin"))
        let library = StorageLibrary(cacheDirectory: cacheDir, draftsDirectory: draftsDir)

        try library.clearCache()

        XCTAssertEqual(library.cacheUsageBytes(), 0)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cacheDir.path, isDirectory: &isDirectory),
            "the directory itself survives — only contents are removed"
        )
        XCTAssertTrue(isDirectory.boolValue)

        try library.clearCache() // idempotent: already-cleared is the steady state
    }

    func testClearCacheNeverReachesDrafts() throws {
        let store = try DraftStore(writingAt: draftsDir)
        try store.upsert(Draft(id: "d1", hostUUID: "h1", text: "kept"))
        try write(10, to: cacheDir.appendingPathComponent("refetchable.bin"))

        try StorageLibrary(cacheDirectory: cacheDir, draftsDirectory: draftsDir).clearCache()

        XCTAssertNotNil(
            try store.draft(id: "d1"),
            "drafts live outside the cache — the budget/clear can never delete them"
        )
    }

    func testClearAllDraftsWipesEveryScope() throws {
        let store = try DraftStore(writingAt: draftsDir)
        try store.upsert(Draft(id: "a", hostUUID: "h1", text: "one"))
        try store.upsert(Draft(id: "b", hostUUID: "h2", directory: "/other", text: "two"))
        try write(10, to: cacheDir.appendingPathComponent("keep.bin"))

        try StorageLibrary(cacheDirectory: cacheDir, draftsDirectory: draftsDir).clearAllDrafts()

        XCTAssertEqual(try store.allDrafts(), [], "every scope's draft dies with Clear Local Data")
        XCTAssertEqual(
            StorageLibrary(cacheDirectory: cacheDir, draftsDirectory: draftsDir).cacheUsageBytes(), 10,
            "the drafts wipe never touches the cache — each half clears only its own store"
        )
    }

    func testClearAllDraftsOnAMissingStoreIsAlreadyTheDesiredState() throws {
        XCTAssertNoThrow(
            try StorageLibrary(cacheDirectory: cacheDir, draftsDirectory: draftsDir).clearAllDrafts(),
            "no drafts table yet = no drafts — nothing to fail on"
        )
    }
}
