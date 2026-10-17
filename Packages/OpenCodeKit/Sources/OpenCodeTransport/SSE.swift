import Foundation

/// One decoded Server-Sent Events message. The OpenCode event stream uses
/// `data: <JSON>\n\n` frames with `: heartbeat` comment frames; unknown fields
/// are ignored and heartbeats surface as `.comment` for liveness tracking.
public enum SSEMessage: Equatable, Sendable {
    case comment(String)
    case event(id: String?, event: String?, data: String)
}

/// Incremental SSE decoder. Feed raw byte chunks of any size (including frames
/// and UTF-8 sequences split across chunk boundaries); complete frames are
/// returned as messages.
public struct SSEDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func decode(_ chunk: Data) -> [SSEMessage] {
        buffer.append(contentsOf: chunk)
        var messages: [SSEMessage] = []
        while let boundary = nextFrameBoundary() {
            let frameBytes = Array(buffer[0..<boundary.contentEnd])
            buffer.removeFirst(boundary.totalEnd)
            let frame = String(decoding: frameBytes, as: UTF8.self)
            messages.append(contentsOf: Self.parseFrame(frame))
        }
        return messages
    }

    /// Called when the stream ends. Incomplete trailing frames are discarded
    /// per the SSE specification.
    public mutating func finish() -> [SSEMessage] {
        buffer.removeAll(keepingCapacity: false)
        return []
    }

    private struct FrameBoundary {
        var contentEnd: Int
        var totalEnd: Int
    }

    /// Finds the next blank-line frame boundary. The SSE format permits LF,
    /// CRLF, and CR-only line endings; a CRLF counts as one break, not two.
    private func nextFrameBoundary() -> FrameBoundary? {
        var index = 0
        while index < buffer.count {
            guard let breakLength = Self.lineBreakLength(in: buffer, at: index) else {
                index += 1
                continue
            }
            let contentEnd = index
            let secondStart = index + breakLength
            if let secondLength = Self.lineBreakLength(in: buffer, at: secondStart) {
                return FrameBoundary(contentEnd: contentEnd, totalEnd: secondStart + secondLength)
            }
            index = secondStart // continue scanning from just past this break
        }
        return nil
    }

    /// Length in bytes of the line break starting at `index` (LF = 1, CR = 1,
    /// CRLF = 2), or nil when no break starts there.
    private static func lineBreakLength(in buffer: [UInt8], at index: Int) -> Int? {
        guard index < buffer.count else { return nil }
        switch buffer[index] {
        case 0x0A:
            return 1
        case 0x0D:
            return index + 1 < buffer.count && buffer[index + 1] == 0x0A ? 2 : 1
        default:
            return nil
        }
    }

    static func parseFrame(_ frame: String) -> [SSEMessage] {
        var comments: [String] = []
        var dataLines: [String] = []
        var id: String?
        var eventName: String?

        // The spec permits LF, CRLF, and CR-only line endings; normalize so
        // the field split below sees one separator style.
        let normalized = frame
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty { continue }
            if line.hasPrefix(":") {
                comments.append(String(line.dropFirst()))
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(parts[0])
            var value = parts.count > 1 ? String(parts[1]) : ""
            if value.hasPrefix(" ") { value.removeFirst() }
            switch field {
            case "data": dataLines.append(value)
            case "id": id = value
            case "event": eventName = value
            default: break // unknown fields ignored (forward compatibility)
            }
        }

        var messages = comments.map(SSEMessage.comment)
        if !dataLines.isEmpty {
            messages.append(.event(id: id, event: eventName, data: dataLines.joined(separator: "\n")))
        }
        return messages
    }
}
