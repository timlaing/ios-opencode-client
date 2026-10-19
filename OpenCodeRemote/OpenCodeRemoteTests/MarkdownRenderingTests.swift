import XCTest
@testable import OpenCodeRemote

/// Transcript/file-rendered Markdown link policy (S13/S14): only
/// http(s) links stay tappable — agent output carrying
/// `[Run](shortcuts://…)` or `tel:` (prompt injection from repository
/// content) must keep its text but lose the action that would open
/// another app with attacker-chosen parameters. The rule matches S12's
/// external fields (`FormSheetView.browserURL`).
final class MarkdownRenderingTests: XCTestCase {
    func testWebLinksStayTappable() throws {
        let attributed = try XCTUnwrap(MarkdownRendering.attributed(
            "See [docs](https://example.com/a) and [plain](http://example.com/b)"
        ))

        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), [
            "https://example.com/a",
            "http://example.com/b",
        ], "http(s) links keep their targets")
    }

    func testForeignSchemeLinksKeepTextButLoseTheAction() throws {
        let attributed = try XCTUnwrap(MarkdownRendering.attributed(
            "[Run](shortcuts://run?name=Attack) and [Call](tel:123456) stay readable"
        ))

        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil },
                      "no non-web link survives as a tappable target")
        XCTAssertEqual(String(attributed.characters),
                       "Run and Call stay readable",
                       "the label text is never stripped")
    }

    func testRelativeLinksAreNotTappable() throws {
        let attributed = try XCTUnwrap(MarkdownRendering.attributed(
            "See [local](docs/guide.md) here"
        ))

        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil },
                      "a scheme-less target is not web and loses the tap action")
    }

    func testMixedMessageKeepsOnlyTheWebLink() throws {
        let attributed = try XCTUnwrap(MarkdownRendering.attributed(
            "[bad](ssh://host/x) vs [good](https://example.com)"
        ))

        XCTAssertEqual(attributed.runs.compactMap(\.link).map(\.absoluteString),
                       ["https://example.com"])
        XCTAssertEqual(String(attributed.characters), "bad vs good")
    }

    func testPlainTextIsReturnedUntouched() throws {
        let attributed = try XCTUnwrap(MarkdownRendering.attributed(
            "No links here — **bold** and `code` only"
        ))

        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil })
        XCTAssertTrue(String(attributed.characters).contains("bold"))
    }
}
