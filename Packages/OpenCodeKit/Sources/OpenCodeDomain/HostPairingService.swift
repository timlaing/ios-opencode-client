import Foundation
import OpenCodeTransport

/// A host plus the credential the caller must persist to the Keychain.
/// Never log, display, or attach the secret to diagnostics.
public struct PairedHost: Sendable, Equatable {
    public var host: Host
    public var secret: String

    public init(host: Host, secret: String) {
        self.host = host
        self.secret = secret
    }
}

/// W01 pairing flow against a reviewed destination (docs/api-contract.md):
/// redeem the single-use code, run the health check with the returned token,
/// and hand back the host plus credential to persist.
///
/// The code is spent only by an explicit redeem call — reviewing or parsing
/// never contacts the host — and a health failure after redemption keeps the
/// redeemed token for retry rather than re-spending the code
/// (docs/navigation-screens.md pairing states).
public struct HostPairingService: Sendable {
    /// Transport factory keyed by destination; injectable for tests.
    public var makeTransport: @Sendable (URL) -> any OpenCodeTransport

    public init(
        makeTransport: @escaping @Sendable (URL) -> any OpenCodeTransport = { URLSessionTransport(baseURL: $0) }
    ) {
        self.makeTransport = makeTransport
    }

    /// S03 pairing failures, one per documented error variant
    /// (docs/navigation-screens.md).
    public enum Failure: Error, Equatable {
        /// The host rejected the code: expired, already spent, or unknown.
        case expiredCode
        /// The host could not be reached at the reviewed destination.
        case unreachable
        /// The host rejected the credential during the health check.
        case rejectedCredential
        /// OpenCode's Basic username is fixed; other values can never work.
        case unsupportedUsername
        /// A success status without the expected payload.
        case invalidResponse
    }

    /// Redeem flow for scanned or pasted pairing links.
    public func pair(code: String, at destination: URL, displayName: String) async throws -> PairedHost {
        let transport = makeTransport(destination)
        let session: PairingSession
        do {
            session = try await transport
                .perform(W01Requests.redeem(code: code))
                .decodedJSON(PairingSession.self)
        } catch let error as TransportError {
            switch error {
            case .http(let status, _) where status == 401 || status == 403:
                throw Failure.expiredCode
            case .decodingFailed:
                throw Failure.invalidResponse
            default:
                throw Failure.unreachable
            }
        }
        let info = try await health(transport: transport, secret: session.token)
        return PairedHost(
            host: Host(
                displayName: Self.defaultDisplayName(for: destination, given: displayName),
                address: destination,
                lastVersion: info.version
            ),
            secret: session.token
        )
    }

    /// Password-fallback flow: the supplied credential is proven by the
    /// health check itself.
    public func verifyPassword(
        at address: URL,
        username: String,
        password: String,
        displayName: String
    ) async throws -> PairedHost {
        guard username == BasicCredential.fixedUsername else { throw Failure.unsupportedUsername }
        let info = try await health(transport: makeTransport(address), secret: password)
        return PairedHost(
            host: Host(
                displayName: Self.defaultDisplayName(for: address, given: displayName),
                address: address,
                lastVersion: info.version
            ),
            secret: password
        )
    }

    /// Health check for a stored credential (S02 state refresh).
    public func healthCheck(at address: URL, secret: String) async throws -> ServerInfo {
        try await health(transport: makeTransport(address), secret: secret)
    }

    private func health(transport: any OpenCodeTransport, secret: String) async throws -> ServerInfo {
        do {
            return try await transport
                .perform(W01Requests.health(secret: secret))
                .decodedJSON(ServerInfo.self)
        } catch let error as TransportError {
            switch error {
            case .http(let status, _) where status == 401 || status == 403:
                throw Failure.rejectedCredential
            case .decodingFailed:
                throw Failure.invalidResponse
            default:
                throw Failure.unreachable
            }
        }
    }

    static func defaultDisplayName(for url: URL, given: String) -> String {
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (url.host ?? url.absoluteString) : trimmed
    }
}
