import Foundation

/// URLSession-backed `OpenCodeTransport` (docs/api-contract.md).
///
/// The session is ephemeral: no cookie storage and no URL cache, so
/// authorization-bearing responses never land on disk (docs/implementation-
/// defaults.md). Requests default to JSON acceptance; the event stream sets
/// its own `Accept` header. `Authorization` comes from the request when set,
/// otherwise from the transport's credential — the pairing redemption request
/// deliberately carries neither: the code itself is the credential.
public struct URLSessionTransport: OpenCodeTransport {
    /// One ephemeral session for the process (no cookie storage, no URL
    /// cache), rather than a fresh connection pool per transport value:
    /// hosts, watchers, and reloads construct transports constantly, and
    /// per-value sessions discard keep-alive connections every time.
    /// Tests inject their own `session` (e.g. a `StubURLProtocol` one).
    private static let sharedSession: URLSession = {
        // .ephemeral keeps cookies and cached responses in MEMORY for the
        // life of the process (and sets cookies by default). This session is
        // shared by every host: a cookie set during pairing would ride along
        // with later Basic-authed requests, and authorization-bearing
        // responses (e.g. file bytes) could sit in the cache — so both are
        // disabled outright, matching the privacy rule in the doc comment.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private let baseURL: URL
    private let credential: BasicCredential?
    private let session: URLSession

    public init(baseURL: URL, credential: BasicCredential? = nil, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.credential = credential
        self.session = session ?? Self.sharedSession
    }

    /// Refuses redirects that change origin. `perform` and `events` set the
    /// Basic `Authorization` header BY HAND, and URLSession follows 3xx
    /// responses automatically — without this guard a host or reverse proxy
    /// redirecting to another origin (or downgrading https → http, bypassing
    /// the pairing gate) would carry the host secret there, breaking the
    /// trust rule in `W01Requests.redeem`: stored secrets must never ride
    /// along to a destination. Same-origin redirects (a proxy normalising a
    /// path) still follow; every hop is checked against the task's ORIGINAL
    /// url, so same-origin → cross-origin chains are caught too.
    final class OriginGuard: NSObject, URLSessionTaskDelegate {
        // `@Sendable` matches the SDK's `NS_SWIFT_SENDABLE` block
        // annotation exactly — the optional-requirement match is what
        // makes URLSession route redirects through this method at all.
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let original = task.originalRequest?.url,
                  let target = request.url,
                  URLSessionTransport.isSameOrigin(original, target)
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    /// Fail-closed origin equality for the guard: scheme, host
    /// (case-insensitive) and port must match EXACTLY — an explicit port
    /// never equals the default (nil ≠ 443) — because the credential is what
    /// is being protected. Deliberately stricter than HostLibrary's
    /// `isSameServer`, which is a UX dedup and tolerates cosmetic
    /// differences.
    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }

    public func perform(_ request: APIRequest) async throws -> APIResponse {
        var urlRequest = URLRequest(url: try request.url(baseURL: baseURL))
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if !request.omitsCredential, let credential = request.credential ?? credential {
            urlRequest.setValue(credential.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        }
        if let contentType = request.contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        // Extra request headers (e.g. `Range` for a progressive fs.read).
        // `Authorization` is skipped: it is owned by the credential fields
        // above and must never be overridable from here.
        for (field, value) in request.headers where field.caseInsensitiveCompare("Authorization") != .orderedSame {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = request.body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: OriginGuard())
        } catch let error as URLError {
            throw error.code == .cancelled ? TransportError.cancelled : TransportError.connectionFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.connectionFailed("Non-HTTP response")
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        // Case-insensitive lookup: HTTP/2 and proxies vary the header's
        // spelling, and a missed Content-Type would misclassify JSON as bytes.
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let payload: APIResponse.Payload
        if data.isEmpty {
            payload = .empty
        } else if contentType.contains("json") {
            payload = .json(data)
        } else {
            payload = .bytes(data)
        }

        let apiResponse = APIResponse(statusCode: http.statusCode, headers: headers, payload: payload)
        guard apiResponse.isSuccess else {
            throw TransportError.http(
                status: http.statusCode,
                envelope: try? apiResponse.decodedJSON(APIErrorEnvelope.self)
            )
        }
        return apiResponse
    }

    /// Subscribes to `GET /api/event` (W16). Framing is handled by the shared
    /// `SSEDecoder`; reconnect policy belongs to the caller (docs/
    /// implementation-defaults.md backoff rules), not the transport.
    public func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try eventRequest()
                    let (bytes, response) = try await session.bytes(for: request, delegate: OriginGuard())
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw TransportError.http(
                            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                            envelope: nil
                        )
                    }
                    var decoder = SSEDecoder()
                    var buffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        // Decode at each line boundary so complete frames are
                        // delivered promptly even on a quiet stream, instead
                        // of waiting for a byte threshold to fill. The SSE
                        // format allows LF, CRLF, and CR-only endings, so
                        // flush on either byte (a lone CR flush finds no
                        // complete frame yet and is a harmless no-op).
                        guard byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") else { continue }
                        for message in decoder.decode(buffer) {
                            deliver(message, to: continuation)
                        }
                        buffer.removeAll(keepingCapacity: true)
                    }
                    if !buffer.isEmpty {
                        for message in decoder.decode(buffer) {
                            deliver(message, to: continuation)
                        }
                    }
                    _ = decoder.finish()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as TransportError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(throwing: error.code == .cancelled
                        ? TransportError.cancelled
                        : TransportError.connectionFailed(error.localizedDescription))
                } catch {
                    continuation.finish(throwing: TransportError.connectionFailed(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func eventRequest() throws -> URLRequest {
        var request = URLRequest(url: try APIRequest(operationID: "event.subscribe", method: .get, path: "/api/event").url(baseURL: baseURL))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let credential {
            request.setValue(credential.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Yields decoded event frames; comments (heartbeats) and stray payloads
    /// are skipped.
    private func deliver(
        _ message: SSEMessage,
        to continuation: AsyncThrowingStream<OpenCodeEvent, Error>.Continuation
    ) {
        guard case .event(_, _, let payload) = message,
              let event = OpenCodeEvent.parse(dataPayload: payload) else { return }
        continuation.yield(event)
    }
}
