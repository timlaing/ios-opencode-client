import Foundation

/// A host project as returned by `GET /api/project` (docs/api-contract.md
/// W02). `canonical` is the absolute project directory path on the host —
/// it is not a cloud identifier. Optional fields stay optional: unknown or
/// absent metadata is represented as absent, never invented.
public struct Project: Codable, Equatable, Sendable {
    public var id: String
    public var canonical: String
    public var name: String?
    public var vcs: String?
    public var time: Time?

    public struct Time: Codable, Equatable, Sendable {
        public var created: Int64?
        public var updated: Int64?
        public var active: Int64?
    }

    public init(id: String, canonical: String, name: String? = nil, vcs: String? = nil, time: Time? = nil) {
        self.id = id
        self.canonical = canonical
        self.name = name
        self.vcs = vcs
        self.time = time
    }
}

/// `Location.PublicInfo` from `GET /api/location`: the server-resolved
/// identity of an existing directory. Store this with the host UUID
/// (docs/api-contract.md W02 step 2).
public struct ResolvedLocation: Codable, Equatable, Sendable {
    public struct ProjectRef: Codable, Equatable, Sendable {
        public var id: String
        public var directory: String
        public var canonical: String

        public init(id: String, directory: String, canonical: String) {
            self.id = id
            self.directory = directory
            self.canonical = canonical
        }
    }

    public var directory: String
    public var project: ProjectRef

    public init(directory: String, project: ProjectRef) {
        self.directory = directory
        self.project = project
    }
}

/// A `FileSystem.Entry`: `path` is relative to the requested location;
/// listing may navigate outside the current directory, so the UI's tree is
/// never presented as server authorization (docs/api-contract.md W02).
public struct FileSystemEntry: Codable, Equatable, Sendable {
    public enum EntryType: String, Codable, Sendable {
        case file
        case directory
    }

    public var path: String
    public var type: EntryType

    public init(path: String, type: EntryType) {
        self.path = path
        self.type = type
    }
}

/// A location-wrapped list response (`fs.list`, `fs.find`).
public struct LocationListResponse: Codable, Equatable, Sendable {
    public struct LocationRef: Codable, Equatable, Sendable {
        public var directory: String
    }

    public var location: LocationRef
    public var data: [FileSystemEntry]

    public init(location: LocationRef, data: [FileSystemEntry]) {
        self.location = location
        self.data = data
    }
}

/// `experimental.fs.write` response: the server-resolved absolute path.
public struct FileWriteResponse: Codable, Equatable, Sendable {
    public struct LocationRef: Codable, Equatable, Sendable {
        public var directory: String
    }

    public var location: LocationRef
    public var data: WrittenPath

    public struct WrittenPath: Codable, Equatable, Sendable {
        public var path: String
    }
}

/// W02 request builders: project inventory, location resolution, folder
/// browsing and the experimental raw write used by New Project
/// (docs/api-contract.md W02). Location-scoped calls encode
/// `location[directory]` as a deep-object query, never a JSON string
/// (encoding rules).
public enum W02Requests {
    /// `GET /api/project` — returns `[Project]` directly, no envelope.
    public static func listProjects(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "project.list",
            method: .get,
            path: "/api/project",
            credential: credential
        )
    }

    /// `GET /api/location?location[directory]=<directory>` — resolves an
    /// existing directory into its server-side project identity.
    public static func resolveLocation(directory: String, credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "location.get",
            method: .get,
            path: "/api/location",
            query: [QueryPair(key: "location[directory]", value: directory)],
            credential: credential
        )
    }

    /// `GET /api/fs/list?location[directory]=<directory>&path=<path>` —
    /// `path` is absolute or relative to the location; entries come back
    /// relative to the location.
    public static func listDirectory(
        directory: String,
        path: String,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "fs.list",
            method: .get,
            path: "/api/fs/list",
            query: [
                QueryPair(key: "location[directory]", value: directory),
                QueryPair(key: "path", value: path),
            ],
            credential: credential
        )
    }

    /// `GET /api/fs/find` — file/directory NAME discovery, not full-text
    /// source search (docs/api-contract.md W02 step 3).
    public static func find(
        directory: String,
        query searchText: String,
        type: FileSystemEntry.EntryType? = nil,
        limit: Int? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        var query = [
            QueryPair(key: "location[directory]", value: directory),
            QueryPair(key: "query", value: searchText),
        ]
        if let type {
            query.append(QueryPair(key: "type", value: type.rawValue))
        }
        if let limit {
            query.append(QueryPair(key: "limit", value: String(limit)))
        }
        return APIRequest(
            operationID: "fs.find",
            method: .get,
            path: "/api/fs/find",
            query: query,
            credential: credential
        )
    }

    /// `POST /api/experimental/fs/write` — raw bytes with
    /// `application/octet-stream`; creates missing parents. The location
    /// must already exist; `path` is the absolute target.
    public static func writeFile(
        directory: String,
        path: String,
        bytes: Data,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "experimental.fs.write",
            method: .post,
            path: "/api/experimental/fs/write",
            query: [
                QueryPair(key: "location[directory]", value: directory),
                QueryPair(key: "path", value: path),
            ],
            body: bytes,
            contentType: "application/octet-stream",
            credential: credential
        )
    }

    /// `GET /api/fs/read/<path>` — reads one file's raw bytes (W11 file
    /// viewer). The 200 response is `application/octet-stream`, never a
    /// JSON envelope, so the caller reads `APIResponse.Payload.bytes`
    /// rather than `decodedJSON` (docs/api-contract.md W11). `path` is the
    /// location-relative file path; each segment is percent-encoded
    /// independently so spaces, Unicode and reserved characters survive
    /// while `/` stays as path structure. `location[directory]` is the
    /// reviewed location, encoded as a deep-object query like every other
    /// location-scoped call (encoding rules).
    ///
    /// `range` is a single HTTP byte range (`bytes=0-1048575`) for the S13
    /// progressive preview: the baseline handler supports ONE range and
    /// answers 206 with `Content-Range: bytes a-b/total` (docs/api-contract.md
    /// W11 — do not assume multipart ranges). A server that ignores `Range`
    /// answers 200 with the whole file, which the caller treats as complete.
    public static func readFile(
        directory: String,
        path: String,
        credential: BasicCredential? = nil,
        range: String? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "fs.read",
            method: .get,
            path: "/api/fs/read/" + path,
            query: [QueryPair(key: "location[directory]", value: directory)],
            credential: credential,
            headers: range.map { ["Range": $0] } ?? [:]
        )
    }
}
