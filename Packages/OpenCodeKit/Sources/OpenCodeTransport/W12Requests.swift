import Foundation

/// W12 change and branch types (docs/api-contract.md W12/W13,
/// docs/navigation-screens.md S15). Both `session.diff` and `vcs.diff`
/// answer with `FileDiff.Info` rows; `Vcs.*` carries branch identity,
/// working-copy status and the review base.
public enum FileDiff {
    /// The pinned status enum — exactly `added`/`deleted`/`modified`.
    public enum Status: String, Codable, Sendable {
        case added, deleted, modified
    }

    /// One changed file with a unified `patch` (full file unless the
    /// request asked for `context` lines around hunks). `additions` and
    /// `deletions` are the HOST's counts — display them as reported,
    /// never recompute client-side.
    public struct Info: Codable, Equatable, Sendable {
        public var file: String
        public var patch: String
        public var additions: Int
        public var deletions: Int
        public var status: Status

        public init(
            file: String,
            patch: String,
            additions: Int,
            deletions: Int,
            status: Status
        ) {
            self.file = file
            self.patch = patch
            self.additions = additions
            self.deletions = deletions
            self.status = status
        }
    }
}

/// Workspace/version-control shapes of the pinned baseline.
public enum Vcs {
    /// `vcs.diff`'s REQUIRED mode: working copy, the branch against its
    /// base, or committed history against the base.
    public enum Mode: String, Sendable {
        case working, branch, committed
    }

    public struct Branch: Codable, Equatable, Sendable {
        public var current: String?
        /// Wire key `default` — the repository's default branch.
        public var defaultBranch: String?

        public init(current: String? = nil, defaultBranch: String? = nil) {
            self.current = current
            self.defaultBranch = defaultBranch
        }

        enum CodingKeys: String, CodingKey {
            case current
            case defaultBranch = "default"
        }
    }

    /// `vcs.get` — provider + branch identity for the location.
    public struct Info: Codable, Equatable, Sendable {
        public var provider: String?
        public var branch: Branch

        public init(provider: String? = nil, branch: Branch) {
            self.provider = provider
            self.branch = branch
        }
    }

    /// `vcs.status` row — like `FileDiff.Info` WITHOUT the patch: the
    /// working-copy totals; the patch itself comes from `vcs.diff`.
    public struct FileStatus: Codable, Equatable, Sendable {
        public var file: String
        public var additions: Int
        public var deletions: Int
        public var status: FileDiff.Status

        public init(file: String, additions: Int, deletions: Int, status: FileDiff.Status) {
            self.file = file
            self.additions = additions
            self.deletions = deletions
            self.status = status
        }
    }

    /// `vcs.base` — the host's best-effort review base. The response's
    /// `data` is NULLABLE: no base yet (no commits) or ambiguous history
    /// is a distinct state the caller surfaces, never an empty
    /// successful diff.
    public struct Base: Codable, Equatable, Sendable {
        public var name: String
        public var ref: String
        public var source: Source

        public init(name: String, ref: String, source: Source) {
            self.name = name
            self.ref = ref
            self.source = source
        }
    }

    /// Where the base came from: a reflog walk or the repository default
    /// branch (wire key `default`).
    public enum Source: String, Codable, Sendable {
        case reflog
        case repositoryDefault = "default"
    }
}

/// `session.diff`'s envelope: `{data:[FileDiff.Info]}` — unlike the VCS
/// endpoints it carries NO location wrapper (the session is already
/// location-bound).
public struct SessionDiffResponse: Codable, Equatable, Sendable {
    public var data: [FileDiff.Info]

    public init(data: [FileDiff.Info]) {
        self.data = data
    }
}

/// W12 request builders (docs/api-contract.md W12/W13 — changes and
/// branch identity).
public enum W12Requests {
    /// `GET /api/session/{sessionID}/diff` — per-file changes of a TURN
    /// (first prompt after idle → the next idle; steering prompts belong
    /// to the same turn). Omit `from` for the newest user turn, `to` for
    /// one turn alone, `context` for full-file patches. A range spanning
    /// a location change is rejected by the host.
    public static func sessionDiff(
        sessionID: String,
        from: String? = nil,
        to: String? = nil,
        context: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        var query: [QueryPair] = []
        func add(_ key: String, _ value: String?) {
            if let value { query.append(QueryPair(key: key, value: value)) }
        }
        add("from", from)
        add("to", to)
        add("context", context)
        return APIRequest(
            operationID: "session.diff",
            method: .get,
            path: "/api/session/\(sessionID)/diff",
            query: query,
            credential: credential
        )
    }

    /// `GET /api/vcs` — the location's provider and current/default
    /// branch.
    public static func vcsInfo(
        directory: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "vcs.get",
            method: .get,
            path: "/api/vcs",
            query: locationQuery(directory: directory),
            credential: credential
        )
    }

    /// `GET /api/vcs/status` — uncommitted working-copy changes; rows
    /// carry totals but no patch.
    public static func vcsStatus(
        directory: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "vcs.status",
            method: .get,
            path: "/api/vcs/status",
            query: locationQuery(directory: directory),
            credential: credential
        )
    }

    /// `GET /api/vcs/base` — the host's review base; `data` is nullable
    /// (see `Vcs.Base`).
    public static func vcsBase(
        directory: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "vcs.base",
            method: .get,
            path: "/api/vcs/base",
            query: locationQuery(directory: directory),
            credential: credential
        )
    }

    /// `GET /api/vcs/diff` — `mode` is REQUIRED. `base` overrides the
    /// comparison without saving it; omit `base` for the repository's
    /// default comparison, `context` for full-file patches.
    public static func vcsDiff(
        directory: String? = nil,
        mode: Vcs.Mode,
        base: String? = nil,
        context: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        var query = locationQuery(directory: directory)
        query.append(QueryPair(key: "mode", value: mode.rawValue))
        if let base { query.append(QueryPair(key: "base", value: base)) }
        if let context { query.append(QueryPair(key: "context", value: context)) }
        return APIRequest(
            operationID: "vcs.diff",
            method: .get,
            path: "/api/vcs/diff",
            query: query,
            credential: credential
        )
    }

    /// The VCS endpoints' `location` parameter is OPTIONAL at the
    /// contract level; omit it entirely when no directory is given so
    /// the host applies its own location default.
    private static func locationQuery(directory: String?) -> [QueryPair] {
        guard let directory else { return [] }
        return [QueryPair(key: "location[directory]", value: directory)]
    }
}
