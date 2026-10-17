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
    private let baseURL: URL
    private let credential: BasicCredential?
    private let session: URLSession

    public init(baseURL: URL, credential: BasicCredential? = nil, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.credential = credential
        self.session = session ?? URLSession(configuration: .ephemeral)
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
        urlRequest.httpBody = request.body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
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
                    let (bytes, response) = try await session.bytes(for: request)
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
