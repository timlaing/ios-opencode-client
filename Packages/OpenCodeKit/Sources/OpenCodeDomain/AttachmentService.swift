import Foundation
import OpenCodeTransport

/// W08 attachment preparation (docs/api-contract.md W08, S09): the web
/// inline/staging rule, and host-side staging for content the rule does
/// not inline.
public enum AttachmentRouter: Sendable {
    /// The CLIENT's inline threshold. Per the contract this is not an
    /// upload cap — larger or other content is staged on the host
    /// instead, and neither threshold overrides server/provider limits.
    public static let inlineThresholdBytes = 20 * 1024 * 1024

    /// The implementation-defaults warning point: a confirmation the
    /// user answers, never a hard limit (docs/implementation-defaults.md).
    public static let warningThresholdBytes = 50 * 1024 * 1024

    /// The native types the web rule inlines as data URIs.
    public static let inlineMIMETypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "application/pdf",
    ]

    /// Supported native images/PDFs at or under the inline threshold ride
    /// in the prompt itself; everything else — other types, or larger
    /// content of a supported type — is staged on the host and sent as a
    /// `file:` URI.
    public static func shouldInline(mimeType: String, byteCount: Int) -> Bool {
        inlineMIMETypes.contains(mimeType.lowercased()) && byteCount <= inlineThresholdBytes
    }

    /// `data:<mime>;base64,<bytes>` for inline attachments.
    public static func dataURI(mimeType: String, bytes: Data) -> String {
        "data:\(mimeType);base64,\(bytes.base64EncodedString())"
    }

    /// A properly escaped `file:` URI from the HOST's absolute path.
    /// Every path component is percent-encoded (`%` included, so a literal
    /// `%20` in a filename cannot masquerade as an escape) — an iOS
    /// sandbox URL must never be sent as a host reference.
    public static func fileURI(hostAbsolutePath: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%")
        let encoded = hostAbsolutePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        return "file://\(encoded)"
    }
}

/// Honest staging failures — never a silent fallback to a wrong URI.
public enum StagingError: Error, Equatable, Sendable {
    /// The host's `server.info` reports no `paths.tmp`: this host cannot
    /// accept staged uploads.
    case noTmpDirectory
}

/// W08 staging: `server.info` yields `paths.tmp`, bytes are written under
/// `<tmp>/uploads/<UUID>/` via `experimental.fs.write` (W02's builder —
/// location-scoped deep-object query, raw octet-stream body), and the
/// host's RESOLVED absolute path comes back as a `file:` URI.
public struct AttachmentStager: Sendable {
    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// `GET /api/info` → the staging directory. A host without
    /// `paths.tmp` fails with `StagingError.noTmpDirectory` — staging is
    /// unavailable, never guessed from somewhere else.
    public func tmpDirectory(at host: URL, credential: BasicCredential?) async throws -> String {
        let info = try await makeTransport(host)
            .perform(W08Requests.info(credential: credential))
            .decodedJSON(ServerInfo.self)
        guard let tmp = info.paths?.tmp else {
            throw StagingError.noTmpDirectory
        }
        return tmp
    }

    /// Writes one attachment's bytes to a unique upload directory and
    /// returns the escaped `file:` URI built from the host's resolved
    /// path. Slashes in the filename are replaced so it cannot escape the
    /// upload directory.
    public func stage(
        at host: URL,
        credential: BasicCredential?,
        tmpDirectory: String,
        filename: String,
        bytes: Data
    ) async throws -> String {
        let safeName = filename.replacingOccurrences(of: "/", with: "_")
        let directory = "\(tmpDirectory)/uploads/\(UUID().uuidString)"
        let response = try await makeTransport(host)
            .perform(W02Requests.writeFile(
                directory: tmpDirectory,
                path: "\(directory)/\(safeName)",
                bytes: bytes,
                credential: credential
            ))
            .decodedJSON(FileWriteResponse.self)
        return AttachmentRouter.fileURI(hostAbsolutePath: response.data.path)
    }
}
