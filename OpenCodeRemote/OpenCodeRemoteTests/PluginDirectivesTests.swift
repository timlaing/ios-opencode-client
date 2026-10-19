import XCTest
@testable import OpenCodeRemote

/// W14 plugin-toggle surgery (docs/api-contract.md W14): the edit
/// touches ONLY the string directives inside the top-level plugins
/// array — comments, options, unrelated keys and other entries survive
/// BYTE-EXACT, and documents without a top-level plugins array are
/// never edited.
final class PluginDirectivesTests: XCTestCase {
    // MARK: - Disable (append a negative directive)

    func testDisableAppendsNegativeToSingleLineArray() {
        let edit = PluginDirectives.disable("demo.b", in: #"{"plugins":["demo.a"]}"#)
        XCTAssertEqual(edit?.resultingText, #"{"plugins":["demo.a", "-demo.b"]}"#)
        XCTAssertEqual(edit?.description, #"Add "-demo.b" to the plugins directives."#)
    }

    func testDisableRespectsTrailingCommaAndEmptyArrays() {
        XCTAssertEqual(
            PluginDirectives.disable("b", in: #"{"plugins":["a",]}"#)?.resultingText,
            #"{"plugins":["a", "-b"]}"#
        )
        XCTAssertEqual(
            PluginDirectives.disable("b", in: #"{"plugins":[]}"#)?.resultingText,
            #"{"plugins":[ "-b"]}"#
        )
    }

    func testDisablePreservesEveryOtherByte() throws {
        let raw = """
        {
          // Ordered low → high precedence.
          "$schema": "https://opencode.ai/config.json",
          "plugins": [
            "demo.audit", // keeps working
            {"package": "opts.pkg", "options": {"depth": 2}}
          ],
          "share": "manual"
        }
        """
        let edit = PluginDirectives.disable("demo.b", in: raw)
        let resulting = try XCTUnwrap(edit?.resultingText)
        // The ONLY change is the inserted directive right before the
        // plugins array's close bracket — everything before and after
        // that splice is byte-identical to the source document.
        let insert = ", \"-demo.b\"]"
        let inserted = try XCTUnwrap(resulting.range(of: insert))
        // The plugins array is this document's only array, so its
        // close bracket is the first "]".
        let closeBracket = try XCTUnwrap(raw.range(of: "]"))
        XCTAssertEqual(
            String(resulting[resulting.startIndex..<inserted.lowerBound]),
            String(raw[raw.startIndex..<closeBracket.lowerBound])
        )
        XCTAssertEqual(
            String(resulting[inserted.upperBound...]),
            String(raw[closeBracket.upperBound...])
        )
        // The unrelated keys and comments survive verbatim.
        XCTAssertTrue(resulting.contains(#""share": "manual""#))
        XCTAssertTrue(resulting.contains("// keeps working"))
        XCTAssertTrue(resulting.contains(#""depth": 2"#))
    }

    func testDisableInsertsBeforeCloseBracketKeepingComments() {
        let raw = """
        {"plugins": [
            "demo.audit" // trailing note
        ]}
        """
        let edit = PluginDirectives.disable("b", in: raw)
        XCTAssertEqual(
            edit?.resultingText,
            """
            {"plugins": [
                "demo.audit" // trailing note
            , "-b"]}
            """
        )
    }

    func testDisableIsANoOpWhenAlreadyDisabledOrNoArray() {
        XCTAssertNil(PluginDirectives.disable("a", in: #"{"plugins":["-a"]}"#), "already disabled")
        XCTAssertNil(PluginDirectives.disable("a", in: #"{"share":"manual"}"#), "no plugins key")
        XCTAssertNil(PluginDirectives.disable("a", in: #"{"plugins":"a"}"#), "plugins is not an array")
        XCTAssertNil(
            PluginDirectives.disable("a", in: #"{"agents":{"x":{"plugins":["a"]}}}"#),
            "only the TOP-LEVEL plugins array is the directives list"
        )
    }

    // MARK: - Enable (remove a negative directive)

    func testEnableRemovesNegativeFromAnywhereInTheArray() {
        // Whitespace OUTSIDE the removed chunk is never reflowed — the
        // splice removes exactly the directive and its owning comma, so
        // the spaces that flanked the gap remain (both results are
        // valid JSON; byte-surgery, not reformatting).
        XCTAssertEqual(
            PluginDirectives.enable("b", in: #"{"plugins":["a", "-b", "c"]}"#)?.resultingText,
            #"{"plugins":["a",  "c"]}"#
        )
        XCTAssertEqual(
            PluginDirectives.enable("b", in: #"{"plugins":["-b", "c"]}"#)?.resultingText,
            #"{"plugins":[ "c"]}"#
        )
        XCTAssertEqual(
            PluginDirectives.enable("b", in: #"{"plugins":["a", "-b"]}"#)?.resultingText,
            #"{"plugins":["a"]}"#
        )
        XCTAssertEqual(
            PluginDirectives.enable("b", in: #"{"plugins":["-b"]}"#)?.resultingText,
            #"{"plugins":[]}"#
        )
    }

    func testEnableKeepsCommentsAndPositiveOptionsAroundTheDirective() {
        let raw = """
        {"plugins": [
            "a.pkg", // keep me
            "-b.pkg" /* removable */,
            {"package": "c.pkg", "options": {"x": 1}}
        ]}
        """
        let edit = PluginDirectives.enable("b.pkg", in: raw)
        // The removed directive's line keeps only its leading indent —
        // an empty line remains (never collapsed: collapsing would mean
        // reflowing bytes the contract reserves for the source). The
        // neighbouring `// keep me` comment and the options object are
        // untouched.
        XCTAssertEqual(
            edit?.resultingText,
            "{\"plugins\": [\n    \"a.pkg\", // keep me\n    \n    {\"package\": \"c.pkg\", \"options\": {\"x\": 1}}\n]}"
        )
    }

    func testEnableIsANoOpWithoutANegativeDirective() {
        XCTAssertNil(PluginDirectives.enable("a", in: #"{"plugins":["a"]}"#), "nothing negative to remove")
        XCTAssertNil(PluginDirectives.enable("a", in: #"{"share":"manual"}"#), "no plugins key")
    }

    func testEscapedAndNonStringElementsAreNeverToggled() {
        // A string with escapes is not a plain directive — left alone.
        let raw = #"{"plugins":["we\"ird", "-b"]}"#
        XCTAssertNil(PluginDirectives.enable("weird", in: raw))
        XCTAssertEqual(
            PluginDirectives.enable("b", in: raw)?.resultingText,
            #"{"plugins":["we\"ird"]}"#
        )
        // Object entries are never toggled either.
        XCTAssertNil(
            PluginDirectives.enable("c.pkg", in: #"{"plugins":[{"package":"c.pkg"}]}"#)
        )
    }
}
