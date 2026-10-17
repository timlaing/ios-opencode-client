import XCTest
@testable import OpenCodeRemote

/// S05 navigation-path tests (docs/api-contract.md W02: fs.list/fs.find
/// entry paths are relative to the requested location). Descending must
/// REPLACE the level path, never append it — the second level otherwise
/// duplicates segments (`src` + `src/lib`). Root "/" survives absolute
/// formatting intact.
final class FolderNavigationTests: XCTestCase {
    func testDescendReplacesLocationRelativePathInsteadOfJoining() {
        var navigation = FolderNavigation()
        navigation.descend(to: "src")
        XCTAssertEqual(navigation.current, "src")

        // Entries at level `src` are still location-relative ("src/lib").
        navigation.descend(to: "src/lib")
        XCTAssertEqual(navigation.current, "src/lib", "no src/src/lib duplication")

        XCTAssertEqual(
            FolderNavigation.absolute(of: navigation.current, startDirectory: "/srv/demo/harbour"),
            "/srv/demo/harbour/src/lib"
        )
    }

    func testGoUpRestoresThePreviousLevel() {
        var navigation = FolderNavigation()
        XCTAssertFalse(navigation.canGoUp, "root cannot go up")
        navigation.descend(to: "src")
        navigation.descend(to: "src/lib")
        navigation.goUp()
        XCTAssertEqual(navigation.current, "src")
        navigation.goUp()
        XCTAssertEqual(navigation.current, "")
        XCTAssertFalse(navigation.canGoUp)
    }

    func testSearchResultDirectoryNavigatesByItsLocationRelativePath() {
        var navigation = FolderNavigation()
        navigation.descend(to: "deep/nested") // fs.find returns location-relative paths
        XCTAssertEqual(navigation.current, "deep/nested")
        XCTAssertEqual(
            FolderNavigation.absolute(of: navigation.current, startDirectory: "/srv/demo"),
            "/srv/demo/deep/nested"
        )
    }

    func testAbsolutePathPreservesRootAndAvoidsDoubleSlashes() {
        // Root start: empty level stays "/", joined level gains no "//".
        XCTAssertEqual(FolderNavigation.absolute(of: "", startDirectory: "/"), "/")
        XCTAssertEqual(FolderNavigation.absolute(of: "srv", startDirectory: "/"), "/srv")

        // Normal start: trailing slash tolerated, empty level is the root dir.
        XCTAssertEqual(FolderNavigation.absolute(of: "", startDirectory: "/srv/demo/"), "/srv/demo")
        XCTAssertEqual(FolderNavigation.absolute(of: "src", startDirectory: "/srv/demo"), "/srv/demo/src")
    }
}
