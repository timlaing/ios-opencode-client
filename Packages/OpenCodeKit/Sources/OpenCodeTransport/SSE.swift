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

    private func nextFrameBoundary() -> FrameBoundary? {
        var index = 0
        while index < buffer.count {
            guard buffer[index] == 0x0A else {
                index += 1
                continue
            }
            let next = index + 1
            if next < buffer.count, buffer[next] == 0x0A {
                return FrameBoundary(contentEnd: index, totalEnd: next + 1)
            }
            if next + 1 < buffer.count, buffer[next] == 0x0D, buffer[next + 1] == 0x0A {
                return FrameBoundary(contentEnd: index, totalEnd: next + 2)
            }
            index += 1
        }
        return nil
    }

    static func parseFrame(_ frame: String) -> [SSEMessage] {
        var comments: [String] = []
        var dataLines: [String] = []
        var id: String?
        var eventName: String?

        for rawLine in frame.split(separator: "\n", omittingEmptySubsequences: false) {
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
