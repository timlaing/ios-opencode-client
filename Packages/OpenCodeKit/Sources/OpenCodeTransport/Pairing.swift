import Foundation

/// The existing OpenCode web pairing payload, parsed for native use.
///
/// `opencode pair` prints `/auth/connect/<code>` links, and its QR code carries
/// the same code with every reachable server address as `{"code","urls"} JSON`.
/// There is no app-specific QR schema (docs/api-contract.md W01).
public struct PairingPayload: Sendable, Equatable {
    /// Single-use pairing code; redeemed via `GET /auth/connect/<code>`.
    public var code: String

    /// Reviewed destinations in payload order. The code is single-use, so at
    /// most one destination can redeem it (docs/api-contract.md).
    public var destinations: [URL]

    public init(code: String, destinations: [URL]) {
        self.code = code
        self.destinations = destinations
    }
}

/// Why a scanned or pasted value is not an acceptable pairing input. Each case
/// maps to an S03 error variant — invalid/legacy link — rather than a raw
/// implementation error (docs/navigation-screens.md).
public enum PairingParseError: Error, Equatable, Sendable {
    /// Empty or whitespace-only input.
    case emptyInput
    /// Not `{"code","urls"}` JSON and not an `http(s)://…/auth/connect/<code>` link.
    case notAPairingLink
    /// The pre-token `/connect#<credentials>` or `/connect?data=` format.
    case legacyLink
    /// A scheme other than http/https.
    case unsupportedScheme
    /// An address carrying userinfo, a query, or a fragment. The pinned client
    /// rejects these outright; they are never stripped and forwarded.
    case credentialBearingAddress
    /// A code outside the pinned `[A-Za-z0-9_-]+` shape.
    case invalidCode
    /// An unparseable or invalid host address.
    case invalidAddress
    /// A structurally valid payload with no addresses.
    case noDestinations
}

/// Parser for the existing pairing inputs (docs/implementation-guide.md).
///
/// Mirrors the pinned web client's parser
/// (`packages/app/src/servers/connect/pairing.ts` at the baseline commit) so
/// the app accepts exactly what `opencode pair` produces — including its
/// rejection of legacy credential-bearing `/connect` links — and rejects
/// everything else. Parsing is passive: it never spends a code or contacts a
/// host, so a scanned payload is always reviewed before redemption
/// (docs/navigation-screens.md).
public enum PairingParser {
    /// The pinned client's pairing-code shape, `[A-Za-z0-9_-]+`.
    private static let codeCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    private static func isValidCode(_ code: String) -> Bool {
        !code.isEmpty && code.allSatisfy(codeCharacters.contains)
    }

    /// Parses a scanned QR payload or a pasted pairing link. JSON payloads are
    /// detected by a leading `{`; anything else is treated as a link.
    public static func parse(_ raw: String) throws -> PairingPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PairingParseError.emptyInput }
        if trimmed.hasPrefix("{") {
            return try parseJSONPayload(trimmed)
        }
        return try parsePairingLink(trimmed)
    }

    /// Single-field form of the manual rules: scheme, host, and optional port
    /// all come from one URL string (e.g. `https://host:4096`, `host:4096`,
    /// or a bare hostname).
    public static func manualAddress(_ raw: String) throws -> URL {
        try manualAddress(host: raw, port: "")
    }

    /// Builds a bare host address for the password-fallback form (S03): the
    /// scheme defaults to https, an explicit `http://` prefix is honored for
    /// plain-HTTP hosts, and an explicit port is validated. Applies the pinned
    /// client's address rules, including its bare-address check: a
    /// single-label host needs a port. Paths stay allowed, where servers
    /// behind a proxy prefix live.
    public static func manualAddress(host rawHost: String, port rawPort: String) throws -> URL {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = rawPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw PairingParseError.invalidAddress }
        if !port.isEmpty {
            guard let number = Int(port), (1...65_535).contains(number) else {
                throw PairingParseError.invalidAddress
            }
        }

        var candidate = host.contains("://") ? host : "https://" + host
        if !port.isEmpty {
            // A port typed into both places is ambiguous; only fill the field.
            guard let url = URL(string: candidate), url.port == nil else {
                throw PairingParseError.invalidAddress
            }
            candidate += ":" + port
        }

        let url = try validatedAddress(candidate)
        let hostname = url.host ?? ""
        if url.path.isEmpty || url.path == "/", url.port == nil,
           hostname != "localhost", !hostname.contains("."), !hostname.hasPrefix("[") {
            throw PairingParseError.invalidAddress
        }
        return url
    }

    // MARK: - Pinned parser ports

    /// Pinned `pairingLink` for the JSON QR payload: `{"code","urls"}`. The
    /// code must match the pinned shape, duplicate addresses collapse in order,
    /// and one invalid address rejects the whole payload — the same
    /// all-or-nothing behavior as the web client.
    private static func parseJSONPayload(_ value: String) throws -> PairingPayload {
        struct QR: Decodable {
            var code: String
            var urls: [String]
        }
        guard let data = value.data(using: .utf8),
              let payload = try? OpenCodeAPI.decoder.decode(QR.self, from: data) else {
            throw PairingParseError.notAPairingLink
        }
        guard isValidCode(payload.code) else {
            throw PairingParseError.invalidCode
        }
        var seen = Set<String>()
        let uniqueURLs = payload.urls.filter { seen.insert($0).inserted }
        guard !uniqueURLs.isEmpty else { throw PairingParseError.noDestinations }
        return PairingPayload(
            code: payload.code,
            destinations: try uniqueURLs.map(validatedAddress)
        )
    }

    /// Pinned `pairingLink` for a printed link: an exact
    /// `/auth/connect/<code>` path on an http(s) origin. The destination is
    /// the origin itself, which drops any userinfo, query, and fragment by
    /// construction — matching the web client, which reads `url.origin`.
    private static func parsePairingLink(_ value: String) throws -> PairingPayload {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            throw PairingParseError.notAPairingLink
        }
        guard scheme == "http" || scheme == "https" else {
            throw PairingParseError.unsupportedScheme
        }
        // Pinned `legacyPairingLink`: the pre-token format carries credentials
        // in the fragment or `?data=`; never treat it as a pairing link.
        if url.path == "/connect",
           (url.fragment?.isEmpty == false || url.query?.contains("data=") == true) {
            throw PairingParseError.legacyLink
        }

        let prefix = "/auth/connect/"
        guard url.path.hasPrefix(prefix) else { throw PairingParseError.notAPairingLink }
        let code = String(url.path.dropFirst(prefix.count))
        // Pinned regex `^/auth/connect/([^/]+)$`: one non-empty, single-segment
        // path component, then the pinned code shape.
        guard !code.isEmpty, !code.contains("/") else { throw PairingParseError.notAPairingLink }
        guard isValidCode(code) else { throw PairingParseError.invalidCode }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.isEmpty == false else {
            throw PairingParseError.invalidAddress
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = ""
        guard let origin = components.url else { throw PairingParseError.invalidAddress }
        return PairingPayload(code: code, destinations: [origin])
    }

    /// Pinned `serverAddress`: http(s) only, host required, and no userinfo,
    /// query, or fragment — those are rejected, not silently stripped, so a
    /// credential-bearing or origin-muddied address never reaches the review
    /// screen (docs/implementation-defaults.md trust rules).
    private static func validatedAddress(_ raw: String) throws -> URL {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            throw PairingParseError.unsupportedSchemeIfPresent(value)
        }
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw PairingParseError.credentialBearingAddress
        }
        return url
    }
}

// MARK: - W01 requests and responses

/// `server.connect` result: the session token, used as the Basic password
/// (docs/api-contract.md). Browsers receive a cookie and a redirect instead;
/// the native client accepts JSON to receive the token.
public struct PairingSession: Decodable, Equatable, Sendable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

/// `server.info` — identifies the host build for S02 display, and (W08)
/// reports `paths.tmp` as the staging directory for attachments. Unknown
/// fields are tolerated so baseline-plus servers decode; `paths` is
/// optional here so an older host still pairs, while staging fails
/// honestly ("no temp directory") instead of decoding into garbage.
public struct ServerInfo: Decodable, Equatable, Sendable {
    public struct Paths: Decodable, Equatable, Sendable {
        public var tmp: String

        public init(tmp: String) {
            self.tmp = tmp
        }
    }

    public var version: String
    public var urls: [String]?
    public var paths: Paths?

    public init(version: String, urls: [String]? = nil, paths: Paths? = nil) {
        self.version = version
        self.urls = urls
        self.paths = paths
    }
}

/// W01 request builders (docs/api-route-catalog.md).
public enum W01Requests {
    /// Redeem a pairing code via `GET /auth/connect/<code>`. No credential is
    /// attached and the transport's default credential is suppressed: the
    /// single-use code is the credential, and redemption must never carry
    /// stored host credentials to a destination.
    public static func redeem(code: String) -> APIRequest {
        APIRequest(
            operationID: "server.connect",
            method: .get,
            path: "/auth/connect/" + code,
            omitsCredential: true
        )
    }

    /// `server.info` health check with a pairing token or host password as
    /// the Basic secret.
    public static func health(secret: String) -> APIRequest {
        APIRequest(
            operationID: "server.info",
            method: .get,
            path: "/api/info",
            credential: BasicCredential(secret: secret)
        )
    }
}

private extension PairingParseError {
    /// Scheme errors are only reported when the input actually carries a
    /// non-http(s) `://` prefix; other unparseable values are just invalid.
    static func unsupportedSchemeIfPresent(_ value: String) -> PairingParseError {
        guard value.contains("://") else { return .invalidAddress }
        return .unsupportedScheme
    }
}
