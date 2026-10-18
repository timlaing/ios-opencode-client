import XCTest
@testable import OpenCodeRemote
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W11 S13 preview logic (docs/navigation-screens.md S13): kind-aware fetch
/// strategy, ranged 206 adoption, the 1 MiB / 10,000-line progressive
/// budgets, cut-line withholding, ETag continuity, within-file text search,
/// and complete-file gating for Copy/Share. This covers the pure decisions
/// FileViewerView renders — the view is a thin renderer and is exercised
/// through the mock E2E, per the sheet convention.
@MainActor
final class FileViewerLibraryTests: XCTestCase {

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    /// A viewer with tiny budgets so tests need no 1 MiB fixtures.
    private func makeViewer(
        byteStep: Int = 16,
        lineStep: Int = 3
    ) -> FileViewerLibrary {
        FileViewerLibrary(byteStep: byteStep, lineStep: lineStep)
    }

    private func readFile(
        _ s: String,
        etag: String? = nil,
        isPartial: Bool = false,
        totalByteCount: Int? = nil
    ) -> ProjectService.ReadFile {
        ProjectService.ReadFile(
            bytes: bytes(s),
            etag: etag,
            isPartial: isPartial,
            totalByteCount: totalByteCount
        )
    }

    // MARK: - Kind detection (drives fetch strategy + renderer)

    func testKindByExtension() {
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "src/main.swift"), .text)
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "README.md"), .markdown)
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "notes.MARKDOWN"), .markdown)
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "shot.png"), .image)
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "scan.JPEG"), .image)
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "doc.pdf"), .pdf)
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "assets/archive.zip"), .binary)
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "clip.mp4"), .binary)
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "db.sqlite"), .binary)
    }

    func testSVGStaysTextSoItsSourceIsNeverExecuted() {
        // Rendering SVG as an image would mean executing embedded markup.
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "logo.svg"), .text)
    }

    func testUnknownExtensionIsTextNotBinary() {
        // Defaulting to binary would hide ordinary source files; defaulting
        // to text only risks mojibake, which the lenient decoder renders as
        // U+FFFD rather than failing.
        XCTAssertEqual(FileViewerLibrary.kind(forPath: "Makefile"), .text)
    }

    func testOnlyTextKindsUseRanges() {
        XCTAssertTrue(FileViewerLibrary.Kind.text.isRanged)
        XCTAssertTrue(FileViewerLibrary.Kind.markdown.isRanged)
        XCTAssertFalse(FileViewerLibrary.Kind.image.isRanged)
        XCTAssertFalse(FileViewerLibrary.Kind.pdf.isRanged)
        XCTAssertFalse(FileViewerLibrary.Kind.binary.isRanged)
    }

    // MARK: - Decoding

    func testDecodePrefersUTF8() {
        XCTAssertEqual(FileViewerLibrary.decode(bytes("héllo — ✓")), "héllo — ✓")
    }

    func testDecodeFallsBackForInvalidUTF8() {
        // A lone 0xFF is invalid UTF-8; the fallback must still yield a
        // string (with U+FFFD) rather than empty or crashing.
        let broken = Data([0x68, 0x69, 0xFF])
        let decoded = FileViewerLibrary.decode(broken)
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertTrue(decoded.contains("hi"))
    }

    func testSplitLinesNormalisesCRLFForLoneCR() {
        // A naive split on ".newlines" would invent an empty line between
        // the CR and LF of a CRLF pair.
        XCTAssertEqual(
            FileViewerLibrary.FileContent.splitLines("a\r\nb\rc\n"),
            ["a", "b", "c", ""]
        )
    }

    // MARK: - initialRange (what the first request asks the server for)

    func testInitialRangeForTextStartsAtByteStep() {
        let viewer = makeViewer(byteStep: 16)
        viewer.beginFile(kind: .text)
        XCTAssertEqual(viewer.initialRange(), "bytes=0-15")
    }

    func testInitialRangeForMediaAndBinaryIsNil() {
        let viewer = makeViewer()
        for kind: FileViewerLibrary.Kind in [.image, .pdf, .binary] {
            viewer.beginFile(kind: kind)
            XCTAssertNil(viewer.initialRange(), "\(kind) must fetch whole or nothing")
        }
    }

    // MARK: - 200 vs 206 adoption

    func testAdoptWholeFileReplacesBufferAndCompletes() {
        let viewer = makeViewer(byteStep: 4)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\ntwo\n", etag: "W/\"v1\""))

        XCTAssertFalse(viewer.isPartial)
        XCTAssertEqual(viewer.totalByteCount, 8, "one\\ntwo\\n is 8 bytes — a whole file declares its own size")
        XCTAssertEqual(viewer.fetchedByteCount, 8)
        XCTAssertFalse(viewer.needsMoreBytes)
        XCTAssertNil(viewer.nextRange())
        XCTAssertEqual(viewer.completeText, "one\ntwo\n")
        XCTAssertEqual(viewer.visibleLines(), ["one", "two", ""])
    }

    func testAdoptPartialAppendsAndReportsTotal() {
        let viewer = makeViewer(byteStep: 4)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\n", etag: "W/\"v1\"", isPartial: true, totalByteCount: 9))

        XCTAssertTrue(viewer.isPartial)
        XCTAssertEqual(viewer.fetchedByteCount, 4)
        XCTAssertEqual(viewer.totalByteCount, 9)
        XCTAssertTrue(viewer.needsMoreBytes)
        XCTAssertEqual(viewer.nextRange(), "bytes=4-7")
    }

    func testWholeFileAfterPartialReplacesRatherThanAppending() {
        // A server that IGNORES Range answers 200 with the whole file;
        // appending it to the prefix would double the content.
        let viewer = makeViewer(byteStep: 4)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\n", etag: "W/\"v1\"", isPartial: true, totalByteCount: 9))
        viewer.adopt(readFile("one\ntwo\n", etag: "W/\"v1\""))

        XCTAssertEqual(viewer.completeText, "one\ntwo\n")
        XCTAssertFalse(viewer.needsMoreBytes)
    }

    func testSequentialRangesAssembleContiguousPrefix() {
        let viewer = makeViewer(byteStep: 4)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\n", etag: "W/\"v1\"", isPartial: true, totalByteCount: 9))
        viewer.adopt(readFile("two\n", etag: "W/\"v1\"", isPartial: true, totalByteCount: 9))
        XCTAssertEqual(viewer.nextRange(), "bytes=8-8")
        viewer.adopt(readFile("x", etag: "W/\"v1\"", isPartial: true, totalByteCount: 9))

        XCTAssertFalse(viewer.needsMoreBytes)
        XCTAssertEqual(viewer.completeText, "one\ntwo\nx")
    }

    func testCutScalarFromOneSliceResolvesInNext() {
        // "é" is two UTF-8 bytes (0xC3 0xA9). Split between them the first
        // decode yields U+FFFD; after the append the re-decode must produce
        // the real character, never a permanent mojibake.
        let viewer = makeViewer(byteStep: 1)
        viewer.beginFile(kind: .text)
        let full = bytes("é")
        viewer.adopt(ProjectService.ReadFile(
            bytes: full.prefix(1),
            etag: "W/\"v1\"",
            isPartial: true,
            totalByteCount: 2
        ))
        viewer.adopt(ProjectService.ReadFile(
            bytes: full.suffix(1),
            etag: "W/\"v1\"",
            isPartial: true,
            totalByteCount: 2
        ))

        XCTAssertEqual(viewer.completeText, "é")
    }

    // MARK: - Cut-line withholding (honesty rule)

    func testPartialPreviewWithholdsCutLastLine() {
        let viewer = makeViewer(byteStep: 100)
        viewer.beginFile(kind: .text)
        // "alpha\nbeta\nga" — the third line is cut mid-word.
        viewer.adopt(readFile("alpha\nbeta\nga", etag: "e1", isPartial: true, totalByteCount: 200))

        XCTAssertEqual(viewer.displayLines, ["alpha", "beta"], "the cut line must never render")
        XCTAssertTrue(viewer.visibleLines().allSatisfy { !$0.contains("ga") })
    }

    func testCompletePreviewWithholdsNothing() {
        let viewer = makeViewer(byteStep: 4)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("alpha\nbeta\ngamma\n"))

        XCTAssertEqual(viewer.displayLines, ["alpha", "beta", "gamma", ""])
    }

    func testSingleLineMinifiedFileStaysVisibleWhilePartial() {
        // A minified one-line file would otherwise preview as empty.
        let viewer = makeViewer(byteStep: 10)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("var a=1;var b=2;", etag: "e1", isPartial: true, totalByteCount: 500))

        XCTAssertEqual(viewer.displayLines, ["var a=1;var b=2;"])
    }

    // MARK: - Line budget (progressive, never truncated)

    func testLineBudgetCapsVisibleLines() {
        let viewer = makeViewer(lineStep: 2)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("a\nb\nc\nd\n"))

        XCTAssertEqual(viewer.visibleLines(), ["a", "b"])
        XCTAssertTrue(viewer.needsMoreLines)
        XCTAssertTrue(viewer.hasMore)
    }

    func testLoadMoreGrowsLineBudgetByStep() {
        let viewer = makeViewer(lineStep: 2)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("a\nb\nc\nd\ne\n"))

        viewer.loadMore()
        XCTAssertEqual(viewer.visibleLines(), ["a", "b", "c", "d"])
        viewer.loadMore()
        XCTAssertFalse(viewer.needsMoreLines)
        XCTAssertEqual(viewer.visibleLines().count, 6)
    }

    func testRevealGrowsBudgetToIncludeTargetLine() {
        let viewer = makeViewer(lineStep: 2)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("a\nb\nc\nd\ne\n"))

        viewer.reveal(line: 5)
        XCTAssertGreaterThanOrEqual(viewer.renderedLineBudget, 5, "reveal must grow the budget to reach the target line")
        XCTAssertGreaterThanOrEqual(viewer.visibleLines().count, 5)
    }

    func testSmallFileWithinBudgetHasNoLoadMore() {
        let viewer = makeViewer()
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\ntwo\n"))

        XCTAssertFalse(viewer.hasMore, "a small complete file must preview with no Load More")
    }

    // MARK: - hasMore / nextRange (the Load More pair)

    func testHasMoreIsByteOrLineBudget() {
        // "one\ntwo\nthree\n" is 14 bytes; a 4-byte step fetches from 14.
        let viewer = makeViewer(byteStep: 4, lineStep: 1)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\ntwo\nthree\n", isPartial: true, totalByteCount: 4096))

        XCTAssertTrue(viewer.needsMoreBytes)
        XCTAssertTrue(viewer.hasMore)
        XCTAssertEqual(viewer.nextRange(), "bytes=14-17")
    }

    func testNextRangeClampsAtTotal() {
        let viewer = makeViewer(byteStep: 8)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("1234567", isPartial: true, totalByteCount: 10))

        XCTAssertEqual(viewer.nextRange(), "bytes=7-9")
    }

    func testNoRangeWhenNothingMoreBytes() {
        let viewer = makeViewer(byteStep: 8)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("12345678"))

        XCTAssertNil(viewer.nextRange())
        XCTAssertFalse(viewer.needsMoreBytes)
    }

    // MARK: - Within-file text search

    func testSearchIsCaseInsensitiveOverDisplayLines() {
        let viewer = makeViewer()
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("Alpha beta\ngamma\nALPHA delta\n"))

        let hits = viewer.search("alpha")
        XCTAssertEqual(hits.map(\.line), [1, 3])
        XCTAssertEqual(hits.first?.text, "Alpha beta")
    }

    func testSearchExcludesCutTail() {
        // A match in a not-yet-complete line must not be reported: it could
        // not be shown or scrolled to honestly. The buffer holds
        // "alpha\nbeta ga" of a larger file, so the second line is cut and
        // withheld from displayLines entirely — its words are unsearchable.
        let viewer = makeViewer(byteStep: 100)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("alpha\nbeta ga", isPartial: true, totalByteCount: 300))

        XCTAssertEqual(viewer.displayLines, ["alpha"], "the cut line is withheld")
        XCTAssertEqual(viewer.search("ga").map(\.line), [], "no match inside the withheld tail")
        XCTAssertEqual(viewer.search("beta").map(\.line), [], "the cut line's words are not searchable")
        XCTAssertEqual(viewer.search("alpha").map(\.line), [1], "complete lines still search")
    }

    func testSearchBlankQueryReturnsNothing() {
        let viewer = makeViewer()
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("alpha\n"))

        XCTAssertTrue(viewer.search("").isEmpty)
        XCTAssertTrue(viewer.search("   ").isEmpty)
    }

    func testSearchBeforeAnyReadReturnsNothing() {
        let viewer = makeViewer()
        viewer.beginFile(kind: .text)

        XCTAssertTrue(viewer.search("alpha").isEmpty)
    }

    // MARK: - ETag continuity

    func testFirstReadStoresEtag() {
        let viewer = makeViewer()
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\n", etag: "W/\"v1\"", isPartial: true, totalByteCount: 9))

        XCTAssertEqual(viewer.etag, "W/\"v1\"")
    }

    func testContinuesCurrentEntityAcceptsSameTag() {
        let viewer = makeViewer()
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\n", etag: "W/\"v1\"", isPartial: true, totalByteCount: 9))

        XCTAssertTrue(viewer.continuesCurrentEntity(
            readFile("two\n", etag: "W/\"v1\"", isPartial: true, totalByteCount: 9)
        ))
    }

    func testContinuesCurrentEntityRejectsChangedTag() {
        // The host rewrote the file between ranged reads; splicing the
        // slices would fabricate content that never existed.
        let viewer = makeViewer()
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\n", etag: "W/\"v1\"", isPartial: true, totalByteCount: 9))

        XCTAssertFalse(viewer.continuesCurrentEntity(
            readFile("two\n", etag: "W/\"v9\"", isPartial: true, totalByteCount: 9)
        ))
    }

    func testContinuesCurrentEntityAcceptsUntaggedSlice() {
        // No tag means no check is possible; the baseline handler always
        // sends one, so this only matters for other hosts.
        let viewer = makeViewer()
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\n", isPartial: true, totalByteCount: 9))

        XCTAssertTrue(viewer.continuesCurrentEntity(readFile("two\n", isPartial: true, totalByteCount: 9)))
    }

    // MARK: - Copy/Share completeness gating

    func testCompleteBytesNilBeforeAnyRead() {
        let viewer = makeViewer()
        viewer.beginFile(kind: .binary)

        XCTAssertFalse(viewer.hasFetched)
        XCTAssertNil(viewer.completeBytes, "a never-fetched file must not look complete")
    }

    func testCompleteBytesNilWhilePrefixRemains() {
        let viewer = makeViewer(byteStep: 4)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\n", etag: "e1", isPartial: true, totalByteCount: 9))

        XCTAssertNil(viewer.completeBytes)
        XCTAssertNil(viewer.completeText)
    }

    func testCompleteBytesAvailableOnceWhole() {
        let viewer = makeViewer(byteStep: 4)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\ntwo\n"))

        XCTAssertEqual(viewer.completeBytes, bytes("one\ntwo\n"))
        XCTAssertEqual(viewer.completeText, "one\ntwo\n")
    }

    func testBinaryKindKeepsBytesButNeverText() {
        let viewer = makeViewer()
        viewer.beginFile(kind: .binary)
        viewer.adopt(readFile("PK\u{0003}\u{0004}payload"))

        XCTAssertNil(viewer.content, "binary kinds must not decode bytes to text")
        XCTAssertNotNil(viewer.completeBytes)
        XCTAssertNil(viewer.completeText)
    }

    func testImageKindKeepsBytesButNeverText() {
        let viewer = makeViewer()
        viewer.beginFile(kind: .image)
        viewer.adopt(readFile("fake-image-bytes"))

        XCTAssertNil(viewer.content)
        XCTAssertEqual(viewer.completeBytes, bytes("fake-image-bytes"))
    }

    // MARK: - beginFile resets (switching files)

    func testBeginFileResetsFetchState() {
        let viewer = makeViewer(byteStep: 4)
        viewer.beginFile(kind: .text)
        viewer.adopt(readFile("one\ntwo\n", etag: "e1"))
        XCTAssertTrue(viewer.hasFetched)

        viewer.beginFile(kind: .pdf)

        XCTAssertEqual(viewer.kind, .pdf)
        XCTAssertFalse(viewer.hasFetched)
        XCTAssertNil(viewer.etag)
        XCTAssertNil(viewer.totalByteCount)
        XCTAssertNil(viewer.content)
        XCTAssertNil(viewer.completeBytes)
        XCTAssertEqual(viewer.fetchedByteCount, 0)
        XCTAssertEqual(viewer.renderedLineBudget, viewer.lineStep)
    }
}
