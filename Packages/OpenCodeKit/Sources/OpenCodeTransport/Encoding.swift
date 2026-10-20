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
    /// ALWAYS exactly once for raw paths: a literal `%` is content (`%25`) — the
    /// encoder never guesses from a segment's shape that it was pre-escaped (a
    /// raw file named `a%20b.txt` must route as `a%2520b.txt`). A path PARAMETER
    /// that may itself contain `/` is pre-encoded with `encode` and declared via
    /// `APIRequest.pathIsPreEncoded`, which takes that path verbatim instead of
    /// running this encoder.
    public static func encodePath(_ path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }
            .joined(separator: "/")
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
