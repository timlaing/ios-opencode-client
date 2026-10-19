import Foundation

/// Inline-only Markdown for agent/user TRANSCRIPT text (S14
/// ConversationView) and host-file RENDERED previews (S13
/// FileViewerView): `AttributedString(markdown:)` produces text
/// attributes only — HTML/scripts embedded in the content never
/// execute — but inline links become TAPPABLE, and SwiftUI's default
/// `openURL` action accepts any scheme. Agent output can carry links
/// like `[Run](shortcuts://run?name=…)` or `tel:` (repository-content
/// prompt injection makes this attacker-influenced), and one tap would
/// open another app with attacker-chosen parameters.
///
/// The rule matches S12's external fields (`FormSheetView.browserURL`):
/// http(s) stays live, every other target — including relative,
/// scheme-less links — keeps its TEXT but loses its tap action.
enum MarkdownRendering {
    /// Parsed inline-only Markdown (whitespace preserved) with non-web
    /// link targets stripped. nil when parsing fails — the caller
    /// renders the source text verbatim, exactly as before.
    static func attributed(_ text: String) -> AttributedString? {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
        // Runs is a value snapshot; the ranges stay valid while only
        // attributes (never characters) are mutated beneath it.
        for run in attributed.runs {
            guard let link = run.link, !isWeb(link) else { continue }
            attributed[run.range].link = nil
        }
        return attributed
    }

    /// The same acceptance rule as `FormSheetView.browserURL`:
    /// lowercase http/https and nothing else — a nil scheme (relative
    /// link) is not web.
    private static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
