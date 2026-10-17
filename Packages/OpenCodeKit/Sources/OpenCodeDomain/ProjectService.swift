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

    /// S06 New Project: writes an empty valid JSONC config at
    /// `<parent>/<name>/opencode.jsonc` (creating missing parents), then
    /// re-resolves the new location so the caller gets the server-verified
    /// identity. The folder name is validated client-side first; the server
    /// remains the authority on the actual resolved target. This creates a
    /// folder and config file only — never Git init, cloning, or shell
    /// execution (docs/api-contract.md W02 steps 4–5).
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
}
