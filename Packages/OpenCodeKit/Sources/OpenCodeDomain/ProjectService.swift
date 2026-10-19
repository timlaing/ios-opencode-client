import Foundation
import OpenCodeTransport

/// Folder-name validation for S04–S06 (docs/navigation-screens.md): reject
/// empty names, `.`/`..`, path separators and control characters; allow
/// ordinary Unicode. The server still verifies the actual resolved target
/// on resolve/write — this is client-side ergonomics, not authorization.
public enum FolderName {
    public enum ValidationError: Error, Equatable {
        case empty
        case reserved
        case containsSeparator
        case containsControlCharacter
    }

    /// Returns the trimmed, valid name or throws `ValidationError`.
    public static func validate(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ValidationError.empty }
        guard name != ".", name != ".." else { throw ValidationError.reserved }
        guard !name.contains("/"), !name.contains("\\") else { throw ValidationError.containsSeparator }
        guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ValidationError.containsControlCharacter
        }
        return name
    }
}

/// W02 operations for a paired host (docs/api-contract.md W02,
/// docs/navigation-screens.md S04–S06). Every call carries the host's
/// stored credential supplied by the caller; the transport keeps
/// presentation independent so the mock exercises the same adapter.
public struct ProjectService: Sendable {
    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// Project inventory; the array response has no envelope.
    public func projects(at host: URL, credential: BasicCredential?) async throws -> [Project] {
        try await makeTransport(host)
            .perform(W02Requests.listProjects(credential: credential))
            .decodedJSON([Project].self)
    }

    /// Resolves an existing directory into its server-side project identity.
    public func resolveLocation(
        at host: URL,
        credential: BasicCredential?,
        directory: String
    ) async throws -> ResolvedLocation {
        try await makeTransport(host)
            .perform(W02Requests.resolveLocation(directory: directory, credential: credential))
            .decodedJSON(ResolvedLocation.self)
    }

    /// Lists one directory level; entries are relative to the location.
    public func listDirectory(
        at host: URL,
        credential: BasicCredential?,
        directory: String,
        path: String
    ) async throws -> [FileSystemEntry] {
        try await makeTransport(host)
            .perform(W02Requests.listDirectory(directory: directory, path: path, credential: credential))
            .decodedJSON(LocationListResponse.self)
            .data
    }

    /// Name-based file/directory discovery within a location.
    public func find(
        at host: URL,
        credential: BasicCredential?,
        directory: String,
        query: String,
        type: FileSystemEntry.EntryType? = nil,
        limit: Int? = nil
    ) async throws -> [FileSystemEntry] {
        try await makeTransport(host)
            .perform(W02Requests.find(directory: directory, query: query, type: type, limit: limit, credential: credential))
            .decodedJSON(LocationListResponse.self)
            .data
    }

    /// The check-before-write rejection in `createProject`
    /// (docs/api-contract.md W02: "offer Open Existing rather than
    /// overwriting").
    public enum CreateProjectError: Error, Equatable, Sendable {
        /// The parent already holds this name — writing would replace
        /// that project's configuration with an empty one.
        case alreadyExists(String)
    }

    /// S06 New Project: CHECKS the parent for an existing entry with this
    /// name first (docs/api-contract.md W02: "check for an existing
    /// target/configuration before writing") — `fs.write` has no
    /// create-only mode at the pinned baseline, so a blind write would
    /// silently replace an existing project's `opencode.jsonc` with `{}`.
    /// On a clean check it writes an empty valid JSONC config at
    /// `<parent>/<name>/opencode.jsonc` (creating missing parents), then
    /// re-resolves the new location so the caller gets the server-verified
    /// identity. The folder name is validated client-side first; the server
    /// remains the authority on the actual resolved target. The
    /// check-then-write race is inherent — the baseline offers no atomic
    /// create-if-absent — so it is narrowed here, never claimed closed.
    /// This creates a folder and config file only — never Git init,
    /// cloning, or shell execution (docs/api-contract.md W02 steps 4–5).
    public func createProject(
        at host: URL,
        credential: BasicCredential?,
        parentDirectory: String,
        name rawName: String
    ) async throws -> ResolvedLocation {
        let name = try FolderName.validate(rawName)
        // Keep "/" as the root parent; only strip trailing slashes from
        // deeper paths, and never emit a double slash when joining.
        let parent = parentDirectory.count > 1 && parentDirectory.hasSuffix("/")
            ? String(parentDirectory.dropLast())
            : parentDirectory
        let targetDirectory = parent == "/" ? "/" + name : parent + "/" + name
        // fs.list on the parent: entries are one level deep and relative
        // to the location, so a conflict is a child whose last path
        // component is the requested name.
        let siblings = try await listDirectory(
            at: host, credential: credential, directory: parent, path: "."
        )
        if siblings.contains(where: { ($0.path as NSString).lastPathComponent == name }) {
            throw CreateProjectError.alreadyExists(targetDirectory)
        }
        _ = try await makeTransport(host)
            .perform(W02Requests.writeFile(
                directory: parent,
                path: targetDirectory + "/opencode.jsonc",
                bytes: Data("{}".utf8),
                credential: credential
            ))
            .decodedJSON(FileWriteResponse.self)
        return try await resolveLocation(at: host, credential: credential, directory: targetDirectory)
    }

    /// W11 S13: reads a file's raw bytes. The payload is octet-stream, never
    /// JSON, so it is extracted as bytes and never run through `decodedJSON`
    /// (docs/api-contract.md W11). `range` asks for one HTTP byte range for
    /// the progressive preview; a 206 answer reports `isPartial` plus the
    /// total size parsed from `Content-Range: bytes a-b/total`, while a 200
    /// answer is the whole file (`isPartial == false`). Errors — 404 for a
    /// missing file, 416 for an unsatisfiable range, permission failures,
    /// symlink resolution — propagate as the server's actual outcome;
    /// nothing is synthesized.
    public struct ReadFile: Sendable, Equatable {
        public var bytes: Data
        public var etag: String?
        public var isPartial: Bool
        /// Total file size from `Content-Range` (nil on an unranged 200,
        /// where the payload itself is the whole file).
        public var totalByteCount: Int?

        public init(bytes: Data, etag: String?, isPartial: Bool = false, totalByteCount: Int? = nil) {
            self.bytes = bytes
            self.etag = etag
            self.isPartial = isPartial
            self.totalByteCount = totalByteCount
        }
    }

    public func readFile(
        at host: URL,
        credential: BasicCredential?,
        directory: String,
        path: String,
        range: String? = nil
    ) async throws -> ReadFile {
        let response = try await makeTransport(host)
            .perform(W02Requests.readFile(
                directory: directory, path: path, credential: credential, range: range
            ))
        // A 200 may legitimately carry an empty file (payload `.empty`);
        // anything else must be the octet-stream body itself.
        let data: Data
        switch response.payload {
        case .bytes(let bytes): data = bytes
        case .empty: data = Data()
        case .json(let bytes): data = bytes // a 2xx that claims JSON still IS the file's bytes
        }
        return ReadFile(
            bytes: data,
            etag: response.header("ETag"),
            isPartial: response.statusCode == 206,
            // Case-insensitive: a host that answers `content-range` must
            // still yield the file's total, or every ranged read would
            // look complete.
            totalByteCount: Self.totalByteCount(fromContentRange: response.header("Content-Range"))
        )
    }

    /// Parses the total out of `Content-Range: bytes <start>-<end>/<total>`
    /// (or `bytes * /<total>`), the only place a ranged read learns the
    /// file's real size. Unparseable → nil, never a guess.
    static func totalByteCount(fromContentRange value: String?) -> Int? {
        guard let value, let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...]
        return Int(total)
    }
}
