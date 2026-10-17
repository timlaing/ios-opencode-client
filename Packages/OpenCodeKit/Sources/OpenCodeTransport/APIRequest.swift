import Foundation

public enum HTTPMethod: String, Sendable, Equatable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// Basic credentials for the W01 pre-pair handshake. The username is fixed by the
/// pinned baseline contract; the secret is a user-supplied password or token.
/// Never log, persist in plaintext, or attach to diagnostics.
public struct BasicCredential: Sendable, Equatable {
    public static let fixedUsername = "opencode"

    public var secret: String

    public init(secret: String) {
        self.secret = secret
    }

    public var authorizationHeaderValue: String {
        let raw = "\(Self.fixedUsername):\(secret)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }
}

/// A typed API request. `path` and `query` carry raw values; encoding is applied
/// when the URL is built (docs/api-contract.md encoding rules).
public struct APIRequest: Sendable, Equatable {
    public var operationID: String
    public var method: HTTPMethod
    public var path: String
    public var query: [QueryPair]
    public var body: Data?
    public var contentType: String?
    public var credential: BasicCredential?
    /// When true, no `Authorization` header is attached even if the transport
    /// holds a default credential. Pairing redemption uses this: the code is
    /// the credential, and stored secrets must never ride along to a
    /// destination (docs/implementation-defaults.md trust rules).
    public var omitsCredential: Bool

    public init(
        operationID: String,
        method: HTTPMethod,
        path: String,
        query: [QueryPair] = [],
        body: Data? = nil,
        contentType: String? = nil,
        credential: BasicCredential? = nil,
        omitsCredential: Bool = false
    ) {
        self.operationID = operationID
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.contentType = contentType
        self.credential = credential
        self.omitsCredential = omitsCredential
    }

    public static func jsonBody<T: Encodable>(
        operationID: String,
        method: HTTPMethod,
        path: String,
        query: [QueryPair] = [],
        value: T,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        var request = APIRequest(
            operationID: operationID,
            method: method,
            path: path,
            query: query,
            contentType: "application/json; charset=utf-8",
            credential: credential
        )
        request.body = try OpenCodeAPI.encoder.encode(value)
        return request
    }

    /// Builds the absolute URL for this request against a host base URL
    /// (origin only; no query or path components on the base).
    public func url(baseURL: URL) throws -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let encodedPath = PercentCoding.encodePath(path)
        let queryString = query.isEmpty
            ? ""
            : "?" + query.map(\.encoded).joined(separator: "&")
        guard let url = URL(string: base + encodedPath + queryString) else {
            throw TransportError.invalidURL
        }
        return url
    }
}

/// A raw API response. Modeled operations return no universal envelope
/// (docs/api-contract.md), so status/payload are surfaced directly.
public struct APIResponse: Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        case json(Data)
        case bytes(Data)
        case empty
    }

    public var statusCode: Int
    public var headers: [String: String]
    public var payload: Payload

    public init(statusCode: Int, headers: [String: String] = [:], payload: Payload) {
        self.statusCode = statusCode
        self.headers = headers
        self.payload = payload
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    public func decodedJSON<T: Decodable>(_ type: T.Type) throws -> T {
        guard case .json(let data) = payload else {
            throw TransportError.emptyBody
        }
        do {
            return try OpenCodeAPI.decoder.decode(T.self, from: data)
        } catch {
            throw TransportError.decodingFailed(String(describing: error))
        }
    }
}

/// Shared coding configuration for the pinned baseline contract.
public enum OpenCodeAPI {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
