import Foundation
import OpenCodeDomain
import OpenCodeTransport

/// Pure decision logic for the S13 file viewer (docs/navigation-screens.md
/// S13–S16, "Files"): progressive byte-ranged previews, line budgeting, and
/// within-file text search — never an edit/Save-file control.
///
/// `fs.read` is `application/octet-stream` (never JSON) and the baseline
/// handler answers ONE byte range with `Content-Range: bytes a-b/total`
/// (docs/api-contract.md W11). This library owns the budgets
/// (docs/implementation-defaults.md:91 — start at 1 MiB OR 10,000 lines,
/// grown only by an explicit Load More) and turns fetched bytes into
/// line-addressable text, so the VIEW stays a thin renderer of decisions
/// made here — the split that keeps `FolderNavigation` testable.
@MainActor
@Observable
final class FileViewerLibrary {
    /// Progressive preview budgets (docs/implementation-defaults.md:91):
    /// "Start text previews at 1 MiB or 10,000 lines … before an explicit
    /// Load More/Large File action. These are progressive-rendering
    /// thresholds, not truncation or upload limits." A file within both
    /// budgets previews complete with no Load More; every budget overrun is
    /// reachable by pressing Load More — never permanently truncated.
    static let defaultByteStep = 1_048_576 // 1 MiB per ranged fetch
    static let defaultLineStep = 10_000 // lines initially / per Load More

    /// The preview kind, chosen from the file's extension before any bytes
    /// arrive — it decides the fetch strategy (text ranges, media fetches
    /// whole: a partial image/PDF cannot render at all).
    enum Kind: Equatable {
        case text
        case markdown
        case image
        case pdf
        case binary

        /// Ranged fetching only helps kinds whose preview can render a
        /// prefix; images and PDFs need the whole file to decode, and a
        /// binary has no preview at all (share/save only).
        var isRanged: Bool { self == .text || self == .markdown }
    }

    static func kind(forPath path: String) -> Kind {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "avif":
            return .image
        case "pdf":
            return .pdf
        case "md", "markdown":
            // SVG deliberately stays .text: it is XML source, and rendering
            // it as an image would mean executing embedded markup
            // (docs/implementation-defaults.md — no script execution).
            return .markdown
        case "zip", "gz", "tgz", "tar", "7z", "rar", "exe", "dylib", "so", "wasm",
             "mp4", "mov", "avi", "mkv", "mp3", "wav", "m4a", "flac", "bin",
             "ttf", "otf", "woff", "woff2", "sqlite":
            return .binary
        default:
            return .text
        }
    }

    /// A decoded, line-addressable snapshot of the fetched bytes.
    struct FileContent: Equatable {
        var text: String
        var lines: [String]

        init(text: String) {
            self.text = text
            self.lines = Self.splitLines(text)
        }

        /// Splits on LF after normalising CRLF and lone CR to LF. Using
        /// `.newlines` directly would split a CRLF pair at BOTH characters
        /// and invent an empty line between them.
        static func splitLines(_ text: String) -> [String] {
            text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
        }
    }

    // MARK: - Budgets (instance-tunable so tests need no 1 MiB fixtures)

    let byteStep: Int
    let lineStep: Int

    // MARK: - Fetch state

    /// What the open file IS (set with `beginFile(kind:)`).
    private(set) var kind: Kind = .text
    /// Bytes fetched so far (the whole file once `needsMoreBytes` is false).
    private var buffer = Data()
    /// True once at least one read has been adopted. Before that the empty
    /// buffer means "nothing fetched", NOT "an empty file", so full-file
    /// actions must never treat a never-fetched file as complete.
    private(set) var hasFetched = false
    /// True while the server answered 206 — `buffer` is a prefix of the file.
    private(set) var isPartial = false
    /// Total file size. From `Content-Range` on a 206; the buffer's own
    /// length on a 200 (the server sent everything). Nil only when a 206
    /// omits the header — RFC 7233 requires it, and without it there is no
    /// honest way to ask for more, so the fetched prefix is what exists.
    private(set) var totalByteCount: Int?
    private(set) var renderedLineBudget: Int
    /// Entity tag from the FIRST read; a later read with a different tag
    /// means the host rewrote the file mid-preview and the buffered prefix
    /// must not be extended (the view restarts instead of stitching).
    private(set) var etag: String?

    /// The decoded file, or nil before the first read succeeds — and for
    /// image/pdf/binary kinds, which never decode bytes to text.
    private(set) var content: FileContent?

    init(
        byteStep: Int = FileViewerLibrary.defaultByteStep,
        lineStep: Int = FileViewerLibrary.defaultLineStep
    ) {
        self.byteStep = byteStep
        self.lineStep = lineStep
        self.renderedLineBudget = lineStep
    }

    /// Resets all fetch/preview state for a newly opened file of `kind`.
    func beginFile(kind: Kind) {
        self.kind = kind
        buffer = Data()
        hasFetched = false
        isPartial = false
        totalByteCount = nil
        etag = nil
        content = nil
        renderedLineBudget = lineStep
    }

    /// Adopts one `fs.read` answer. A 200 is the WHOLE file and REPLACES the
    /// buffer (a server ignoring `Range` must never append into a prefix);
    /// a 206 APPENDS its slice — the accumulated buffer is always a contiguous
    /// prefix of the file, so re-decoding it after each append resolves any
    /// scalar the previous slice happened to cut in half. Text kinds decode
    /// to lines; image/pdf/binary keep bytes only (decoding megabytes of a
    /// photo into U+FFFD strings would be pure waste).
    func adopt(_ file: ProjectService.ReadFile) {
        if file.isPartial {
            buffer += file.bytes
            isPartial = true
            totalByteCount = file.totalByteCount
        } else {
            buffer = file.bytes
            isPartial = false
            totalByteCount = file.bytes.count
        }
        if etag == nil { etag = file.etag }
        hasFetched = true
        switch kind {
        case .text, .markdown:
            content = FileContent(text: Self.decode(buffer))
        case .image, .pdf, .binary:
            content = nil
        }
    }

    /// True when `file` continues the SAME entity the buffer was built from.
    /// A later slice carrying a DIFFERENT tag means the host rewrote the file
    /// between ranged reads; splicing it into the prefix would fabricate a
    /// file that never existed, so the caller must restart instead of
    /// adopting. A slice with no tag (server declined to send one) cannot be
    /// checked and is accepted — the baseline handler always sends one.
    func continuesCurrentEntity(_ file: ProjectService.ReadFile) -> Bool {
        guard let etag, let sliceTag = file.etag else { return true }
        return etag == sliceTag
    }

    // MARK: - Progressive budgets

    /// Bytes fetched so far — for the "Previewing X of Y" progress text.
    var fetchedByteCount: Int { buffer.count }

    /// The `Range` header for the FIRST read of a ranged kind (text-like
    /// previews start at the byte step), or nil when the kind needs the
    /// whole file to render at all (image/pdf/binary).
    func initialRange() -> String? {
        kind.isRanged ? "bytes=0-\(byteStep - 1)" : nil
    }

    /// Bytes remain beyond the buffer — the only condition under which Load
    /// More has a range left to fetch.
    var needsMoreBytes: Bool {
        guard let total = totalByteCount else { return false }
        return buffer.count < total
    }

    /// Lines exist beyond the rendered budget (either still unfetched or
    /// fetched but unrendered) — the second reason Load More appears.
    var needsMoreLines: Bool {
        renderedLineBudget < (content?.lines.count ?? 0)
    }

    /// The single condition under which S13 shows Load More: either budget
    /// still has somewhere to go (docs/navigation-screens.md S13 — large
    /// previews are progressive, never permanently truncated).
    var hasMore: Bool { needsMoreBytes || needsMoreLines }

    /// The `Range` header for the next fetch, or nil when the whole file is
    /// already buffered (docs/api-contract.md W11 — ONE range per request).
    func nextRange() -> String? {
        guard needsMoreBytes, let total = totalByteCount else { return nil }
        let start = buffer.count
        let end = min(start + byteStep, total) - 1
        return "bytes=\(start)-\(end)"
    }

    /// One Load More step on the LINE axis: grows the render budget by the
    /// line threshold. Byte fetching is the view's half of Load More (it
    /// owns the network call); both axes may grow in the same press.
    func loadMore() {
        renderedLineBudget += lineStep
    }

    /// Ensures a searched line is within the rendered budget so line
    /// navigation can scroll to it (the line's bytes are already fetched —
    /// search only ever matches display lines).
    func reveal(line: Int) {
        renderedLineBudget = max(renderedLineBudget, line)
    }

    /// The lines eligible for rendering/search. While the buffer is a prefix,
    /// its LAST line may be cut mid-line (or mid-scalar) and is withheld —
    /// an incomplete line is never shown as if it were whole; once every byte
    /// has arrived nothing is withheld. The >1 guard keeps a single huge
    /// line (minified content) visible rather than showing an empty file.
    var displayLines: [String] {
        guard let content else { return [] }
        var lines = content.lines
        if needsMoreBytes, lines.count > 1 {
            lines.removeLast()
        }
        return lines
    }

    /// The lines the viewer should render: whole leading display lines within
    /// the line budget. Never a byte-partial line (that is `displayLines`' job).
    func visibleLines() -> [String] {
        Array(displayLines.prefix(renderedLineBudget))
    }

    // MARK: - Within-file text search

    /// A 1-based line number carrying a within-file search hit.
    struct SearchHit: Equatable, Identifiable {
        var id: Int { line }
        var line: Int
        var text: String
    }

    /// Case-insensitive search over the DISPLAY lines, returning the 1-based
    /// numbers. Restricting to display lines keeps every hit renderable:
    /// a match inside a not-yet-fetched or cut tail can be neither shown nor
    /// scrolled to, and reporting it would promise navigation that cannot
    /// happen. Text beyond the line budget (but fetched) IS searched.
    func search(_ query: String) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, content != nil else { return [] }
        return displayLines.enumerated().compactMap { index, line in
            line.range(of: needle, options: .caseInsensitive) == nil
                ? nil
                : SearchHit(line: index + 1, text: line)
        }
    }

    // MARK: - Full-file actions (Copy / Share)

    /// The complete file bytes once every range has arrived; nil while the
    /// buffer is still a prefix — Copy/Share must never export a partial
    /// file as if it were the whole one. A 206 whose `Content-Range` had
    /// no parseable total is NEVER complete: `needsMoreBytes` can't ask
    /// for more without a size, but that means "unknowable", not "done".
    var completeBytes: Data? {
        guard hasFetched, !needsMoreBytes else { return nil }
        if isPartial, totalByteCount == nil { return nil }
        return buffer
    }

    /// The complete decoded text (text kinds only, and only when whole).
    var completeText: String? {
        guard hasFetched, !needsMoreBytes else { return nil }
        if isPartial, totalByteCount == nil { return nil }
        return content?.text
    }

    // MARK: - Decoding

    /// Decodes bytes as UTF-8, falling back to a lossless UTF-8-lenient
    /// decode so a host file that is not valid UTF-8 still previews its
    /// characters (invalid sequences become U+FFFD) instead of failing
    /// outright — the server's bytes are never silently swapped for a guess.
    static func decode(_ bytes: Data) -> String {
        String(data: bytes, encoding: .utf8)
            ?? String(decoding: bytes, as: UTF8.self)
    }
}
