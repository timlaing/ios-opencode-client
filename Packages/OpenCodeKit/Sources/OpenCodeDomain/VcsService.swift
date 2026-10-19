import Foundation
import OpenCodeTransport

/// W12 workspace change/branch operations for a paired host
/// (docs/api-contract.md W12/W13, docs/navigation-screens.md S15):
/// branch identity, working-copy status, the review base, and mode-based
/// diffs. Every call is LOCATION-scoped.
///
/// A nil `base()` answer is a DISTINCT state (no commits yet, or
/// ambiguous history the host refuses to guess) that the caller must
/// surface — never an empty successful diff — and this service never
/// invents a ref to fill it.
public struct VcsService: Sendable {
    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport) {
        self.makeTransport = makeTransport
    }

    /// `GET /api/vcs` — the location's provider and current/default
    /// branch (`vcs.get`).
    public func info(
        at host: URL,
        credential: BasicCredential?,
        directory: String? = nil
    ) async throws -> Vcs.Info {
        try await makeTransport(host)
            .perform(W12Requests.vcsInfo(directory: directory, credential: credential))
            .decodedJSON(LocationEnvelope<Vcs.Info>.self)
            .data
    }

    /// `GET /api/vcs/status` — uncommitted working-copy changes
    /// (`vcs.status`); rows carry totals but NO patch.
    public func status(
        at host: URL,
        credential: BasicCredential?,
        directory: String? = nil
    ) async throws -> [Vcs.FileStatus] {
        try await makeTransport(host)
            .perform(W12Requests.vcsStatus(directory: directory, credential: credential))
            .decodedJSON(LocationEnvelope<[Vcs.FileStatus]>.self)
            .data
    }

    /// `GET /api/vcs/base` — the host's review base (`vcs.base`);
    /// `nil` when the host has none.
    public func base(
        at host: URL,
        credential: BasicCredential?,
        directory: String? = nil
    ) async throws -> Vcs.Base? {
        try await makeTransport(host)
            .perform(W12Requests.vcsBase(directory: directory, credential: credential))
            .decodedJSON(LocationEnvelope<Vcs.Base?>.self)
            .data
    }

    /// `GET /api/vcs/diff` — mode-based per-file diffs (`vcs.diff`).
    /// `mode` is REQUIRED by the schema; `base` overrides the comparison
    /// without saving it.
    public func diff(
        at host: URL,
        credential: BasicCredential?,
        directory: String? = nil,
        mode: Vcs.Mode,
        base: String? = nil,
        context: String? = nil
    ) async throws -> [FileDiff.Info] {
        try await makeTransport(host)
            .perform(W12Requests.vcsDiff(
                directory: directory,
                mode: mode,
                base: base,
                context: context,
                credential: credential
            ))
            .decodedJSON(LocationEnvelope<[FileDiff.Info]>.self)
            .data
    }
}
