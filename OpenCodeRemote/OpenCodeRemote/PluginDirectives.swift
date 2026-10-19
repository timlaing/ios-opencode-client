import Foundation

/// W14 plugin-toggle surgery (docs/api-contract.md W14): edits ONLY the
/// ordered string directives inside the top-level `"plugins"` array of
/// one raw JSONC document. Everything else — comments, options,
/// unrelated keys, non-string entries, formatting — survives
/// BYTE-EXACT, because the document is spliced, never re-serialised
/// (a re-print would destroy comments the contract requires preserving).
///
/// Semantics: a negative string (`"-target"`) disables; enabling removes
/// the negative directive and preserves any positive target/options for
/// recovery. A negative wins over a positive regardless of order (the
/// host resolves declared directives that way — the mock filters
/// negatively-declared plugins out of the runtime inventory).
enum PluginDirectives {
    /// One top-level element of the plugins array. `string` is the
    /// decoded value iff the element is a PLAIN string literal (only
    /// `\"` and `\\` escapes recognised); any other shape — objects,
    /// numbers, escapes — is never toggled.
    struct Element {
        var range: Range<String.Index>
        var string: String?
    }

    struct PluginsArray {
        var elements: [Element]
        var closeBracket: String.Index
        /// The last element already carries a trailing comma.
        var hasTrailingComma: Bool
    }

    /// A planned edit: the exact resulting document text plus the
    /// directive change, for the plan confirmation the UI shows before
    /// anything is written.
    struct Edit: Equatable {
        var resultingText: String
        var description: String
    }

    /// Disables `target` by APPENDING a `"-target"` directive. The
    /// positive entry stays (recoverable). Returns nil when the
    /// document already disables it or declares no plugins array — the
    /// caller reports honestly instead of inventing structure.
    static func disable(_ target: String, in raw: String) -> Edit? {
        guard let array = pluginsArray(in: raw) else { return nil }
        let negative = "-" + target
        guard !array.elements.contains(where: { $0.string == negative }) else { return nil }
        let separator = (array.hasTrailingComma || array.elements.isEmpty) ? "" : ","
        let insert = "\(separator) \"\(negative)\""
        var text = raw
        text.insert(contentsOf: insert, at: array.closeBracket)
        return Edit(
            resultingText: text,
            description: "Add \"\(negative)\" to the plugins directives."
        )
    }

    /// Enables `target` by REMOVING its `"-target"` directive, keeping
    /// every neighbouring directive and comment. ONE contiguous splice
    /// per case (Swift indices are invalidated by mutation): a
    /// comma-closed element loses its chunk AND its closing comma; the
    /// LAST element instead loses its PRECEDING comma through its chunk
    /// end; a lone element empties the array. Trivia trailing the
    /// removed directive travels with it. Returns nil when no negative
    /// directive exists or there is no plugins array.
    static func enable(_ target: String, in raw: String) -> Edit? {
        guard let array = pluginsArray(in: raw) else { return nil }
        let negative = "-" + target
        guard let index = array.elements.firstIndex(where: { $0.string == negative }) else {
            return nil
        }
        let element = array.elements[index]
        let removeRange: Range<String.Index>
        if index + 1 < array.elements.count {
            // Comma-closed: the element chunk ends AT its closing comma
            // by construction — remove both as one contiguous range.
            let comma = element.range.upperBound
            guard comma < raw.endIndex, raw[comma] == "," else { return nil }
            removeRange = element.range.lowerBound..<raw.index(after: comma)
        } else if index > 0 {
            // Last element: remove the preceding comma through the
            // chunk end.
            removeRange = array.elements[index - 1].range.upperBound..<element.range.upperBound
        } else {
            // The array's only element.
            removeRange = element.range
        }
        var text = raw
        text.removeSubrange(removeRange)
        return Edit(
            resultingText: text,
            description: "Remove \"\(negative)\" from the plugins directives."
        )
    }

    // MARK: - JSONC-aware scanning

    /// Locates the top-level `"plugins"` array. A `plugins` key that is
    /// not followed by `[` (or one nested inside another value) is NOT
    /// the directives array and is never edited. `depth` counts opened
    /// braces/brackets, so the ROOT object's keys are scanned at
    /// depth 1 — depth 0 means outside any container entirely.
    static func pluginsArray(in raw: String) -> PluginsArray? {
        var index = raw.startIndex
        var depth = 0
        while index < raw.endIndex {
            let char = raw[index]
            if char == "/", let end = triviaEnd(from: index, in: raw) {
                // triviaEnd advances past a comment; a non-comment
                // slash falls through.
                if end != index {
                    index = end
                    continue
                }
            }
            if char == "\"" {
                guard let token = stringToken(from: index, in: raw) else { return nil }
                var after = skipTrivia(from: token.range.upperBound, in: raw)
                if after < raw.endIndex, raw[after] == ":", token.value == "plugins",
                   depth == 1 {
                    after = skipTrivia(from: raw.index(after: after), in: raw)
                    if after < raw.endIndex, raw[after] == "[" {
                        return parseArray(from: after, in: raw)
                    }
                    return nil
                }
                index = token.range.upperBound
                continue
            }
            if char == "{" || char == "[" {
                depth += 1
            } else if char == "}" || char == "]" {
                depth -= 1
            }
            index = raw.index(after: index)
        }
        return nil
    }

    private static func parseArray(
        from openBracket: String.Index, in raw: String
    ) -> PluginsArray? {
        var index = raw.index(after: openBracket)
        var elements: [Element] = []
        var elementStart: String.Index?
        var depth = 0
        var commaAfterLast = false
        while index < raw.endIndex {
            let char = raw[index]
            if char == "/", let end = triviaEnd(from: index, in: raw), end != index {
                index = end
                continue
            }
            if char == "\"" {
                guard let token = stringToken(from: index, in: raw) else { return nil }
                if depth == 0, elementStart == nil {
                    elementStart = index
                    commaAfterLast = false
                }
                index = token.range.upperBound
                continue
            }
            if char == "[" || char == "{" {
                if depth == 0, elementStart == nil {
                    elementStart = index
                    commaAfterLast = false
                }
                depth += 1
                index = raw.index(after: index)
                continue
            }
            if char == "]" && depth == 0 {
                if let start = elementStart {
                    elements.append(makeElement(from: start, to: index, in: raw))
                }
                return PluginsArray(
                    elements: elements,
                    closeBracket: index,
                    hasTrailingComma: commaAfterLast
                )
            }
            if char == "}" || char == "]" {
                depth = max(0, depth - 1)
                index = raw.index(after: index)
                continue
            }
            if char == "," && depth == 0 {
                if let start = elementStart {
                    elements.append(makeElement(from: start, to: index, in: raw))
                    elementStart = nil
                    commaAfterLast = true
                }
                index = raw.index(after: index)
                continue
            }
            if depth == 0, elementStart == nil, char != " ", char != "\t", char != "\n",
               char != "\r" {
                elementStart = index
                commaAfterLast = false
            }
            index = raw.index(after: index)
        }
        return nil
    }

    /// The element is a plain string literal iff its first significant
    /// token is a string and everything after it is whitespace/comments.
    private static func makeElement(
        from start: String.Index, to end: String.Index, in raw: String
    ) -> Element {
        var index = skipTrivia(from: start, in: raw)
        guard index < end, raw[index] == "\"",
              let token = stringToken(from: index, in: raw),
              token.range.upperBound <= end
        else {
            return Element(range: start..<end, string: nil)
        }
        let after = skipTrivia(from: token.range.upperBound, in: raw)
        if after >= end || raw[after] == "," || raw[after] == "]" {
            return Element(range: start..<end, string: token.value)
        }
        return Element(range: start..<end, string: nil)
    }

    /// Parses a string literal from its opening quote. `value` is the
    /// decoded text for plain `\"`/`\\` escapes and nil for anything
    /// else — an undecodable literal is simply never toggled.
    private static func stringToken(
        from quote: String.Index, in raw: String
    ) -> (range: Range<String.Index>, value: String?)? {
        var index = raw.index(after: quote)
        var value = ""
        var decodable = true
        while index < raw.endIndex {
            let char = raw[index]
            if char == "\\" {
                let next = raw.index(after: index)
                guard next < raw.endIndex else { return nil }
                let escaped = raw[next]
                if escaped == "\"" {
                    value.append("\"")
                } else if escaped == "\\" {
                    value.append("\\")
                } else {
                    decodable = false
                }
                index = raw.index(after: next)
                continue
            }
            if char == "\"" {
                return (quote..<raw.index(after: index), decodable ? value : nil)
            }
            if decodable { value.append(char) }
            index = raw.index(after: index)
        }
        return nil
    }

    /// Advances past whitespace and comments; returns the first
    /// significant index.
    private static func skipTrivia(from start: String.Index, in raw: String) -> String.Index {
        var index = start
        while index < raw.endIndex {
            let char = raw[index]
            if char == " " || char == "\t" || char == "\n" || char == "\r" {
                index = raw.index(after: index)
            } else if char == "/", let end = triviaEnd(from: index, in: raw), end != index {
                index = end
            } else {
                break
            }
        }
        return index
    }

    /// When `index` starts a comment, returns the index after it;
    /// otherwise returns nil.
    private static func triviaEnd(
        from start: String.Index, in raw: String
    ) -> String.Index? {
        guard start < raw.endIndex, raw[start] == "/" else { return nil }
        let next = raw.index(after: start)
        guard next < raw.endIndex else { return nil }
        if raw[next] == "/" {
            var index = next
            while index < raw.endIndex, raw[index] != "\n" {
                index = raw.index(after: index)
            }
            return index
        }
        if raw[next] == "*" {
            var index = raw.index(after: next)
            while index < raw.endIndex {
                if raw[index] == "*", raw.index(after: index) < raw.endIndex,
                   raw[raw.index(after: index)] == "/" {
                    return raw.index(after: raw.index(after: index))
                }
                index = raw.index(after: index)
            }
            return raw.endIndex
        }
        return nil
    }
}
