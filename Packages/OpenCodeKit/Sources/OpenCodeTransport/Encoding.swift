import Foundation

/// Strict percent-encoding helpers.
///
/// Contract (docs/api-contract.md): encode path segments and query parameters
/// independently, without treating `#`, `?`, spaces, Unicode, or reserved characters
/// as syntax. Inputs are *raw* values; never pass pre-encoded strings.
public enum PercentCoding {
    /// Unreserved characters per RFC 3986. Everything else is percent-encoded.
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ component: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(component.utf8.count)
        for byte in component.utf8 {
            if unreserved.contains(Character(Unicode.Scalar(byte))) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    /// Encodes a slash-delimited path, percent-encoding each segment independently
    /// so embedded `/` stay as path structure while everything else is escaped.
    ///
    /// A segment may already carry percent-escapes: a path PARAMETER whose raw
    /// value can itself contain `/` (an MCP server name, for example) is
    /// pre-encoded as ONE component with `encode` before interpolation, and
    /// valid `%HH` sequences survive this pass — encoding is idempotent per
    /// segment, so pre-encoding never turns into `%25`. A `%` that is not a
    /// valid escape is still encoded as raw content (raw `%` → `%25`),
    /// keeping single-encoding the default for raw paths.
    public static func encodePath(_ path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { encodeSegmentPreservingEscapes(String($0)) }
            .joined(separator: "/")
    }

    /// One segment: keeps valid `%HH` escapes; every other byte follows the
    /// same unreserved-only rule as `encode`.
    private static func encodeSegmentPreservingEscapes(_ segment: String) -> String {
        let bytes = Array(segment.utf8)
        var encoded = ""
        encoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               hexDigit(bytes[index + 1]) != nil, hexDigit(bytes[index + 2]) != nil {
                encoded.unicodeScalars.append(Unicode.Scalar(UInt8(ascii: "%")))
                encoded.unicodeScalars.append(Unicode.Scalar(bytes[index + 1]))
                encoded.unicodeScalars.append(Unicode.Scalar(bytes[index + 2]))
                index += 3
                continue
            }
            let byte = bytes[index]
            if unreserved.contains(Character(Unicode.Scalar(byte))) {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
            index += 1
        }
        return encoded
    }

    /// An ASCII hex digit's value (0–15), case-insensitively.
    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}

/// A raw (unencoded) query key/value pair.
public struct QueryPair: Sendable, Equatable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public var encoded: String {
        "\(PercentCoding.encode(key))=\(PercentCoding.encode(value))"
    }
}
