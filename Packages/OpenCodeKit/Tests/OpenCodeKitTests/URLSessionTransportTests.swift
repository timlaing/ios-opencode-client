import XCTest
@testable import OpenCodeTransport

/// Records and stubs at the URL loading layer so `URLSessionTransport`'s
/// request mapping and response handling are verified end to end.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let client else {
            XCTFail("No stub handler installed")
            return
        }
        do {
            let (response, data) = try handler(request)
            // A 3xx with Location reports the redirect the way CFNetwork
            // does — above the protocol layer, URLSession's redirect
            // machinery (task delegate FIRST, automatic follow only if
            // the delegate allows) takes over. The redirect request
            // inherits the original headers, simulating the credential-
            // riding follow-up the delegate exists to prevent.
            if (300..<400).contains(response.statusCode),
               let location = response.value(forHTTPHeaderField: "Location"),
               let target = URL(string: location, relativeTo: request.url)?.absoluteURL {
                var redirect = URLRequest(url: target)
                request.allHTTPHeaderFields?.forEach { redirect.setValue($0.value, forHTTPHeaderField: $0.key) }
                client.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
                // Terminate THIS protocol load — CFNetwork's redirect
                // bookkeeping expects it (the standard OHHTTPStubs /
                // Nocilla pattern); the session then consults the task
                // delegate for the redirect decision.
                client.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            client.urlProtocolDidFinishLoading(self)
        } catch {
            client.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class URLSessionTransportTests: XCTestCase {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        func capture(_ request: URLRequest) { lock.lock(); recorded.append(request); lock.unlock() }
        var current: URLRequest? { lock.lock(); defer { lock.unlock() }; return recorded.last }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        session = nil
        super.tearDown()
    }

    private func transport(credential: BasicCredential? = nil) -> URLSessionTransport {
        URLSessionTransport(
            baseURL: URL(string: "https://host.example:4096")!,
            credential: credential,
            session: session
        )
    }

    /// Installs a stub that records the request and responds with the given
    /// status/body/content type.
    private func stub(
        status: Int = 200,
        body: String = "",
        contentType: String = "application/json",
        seen: Seen? = nil
    ) {
        StubURLProtocol.handler = { request in
            seen?.capture(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
            )!
            return (response, Data(body.utf8))
        }
    }

    func testPerformMapsMethodPathAndHeaders() async throws {
        let seen = Seen()
        stub(body: #"{"token":"t2"}"#, seen: seen)
        let response = try await transport(credential: BasicCredential(secret: "stored"))
            .perform(W01Requests.health(secret: "t2"))
        XCTAssertTrue(response.isSuccess)

        let request = try XCTUnwrap(seen.current)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/info")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        // The request-level credential wins and encodes the fixed username.
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            BasicCredential(secret: "t2").authorizationHeaderValue
        )
    }

    func testRedeemRequestCarriesNoAuthorization() async throws {
        let seen = Seen()
        stub(body: #"{"token":"t"}"#, seen: seen)
        _ = try await transport(credential: BasicCredential(secret: "stored-secret"))
            .perform(W01Requests.redeem(code: "abc-123"))
        let request = try XCTUnwrap(seen.current)
        XCTAssertEqual(request.url?.path, "/auth/connect/abc-123")
        XCTAssertNil(
            request.value(forHTTPHeaderField: "Authorization"),
            "The pairing code is the credential; stored secrets must not ride along"
        )
    }

    func testAuthenticationFailureDecodesEnvelope() async throws {
        stub(status: 401, body: #"{"_tag":"UnauthorizedError","message":"Pairing link expired or already used"}"#)
        do {
            _ = try await transport().perform(W01Requests.redeem(code: "spent"))
            XCTFail("Expected a thrown error")
        } catch let TransportError.http(status, envelope) {
            XCTAssertEqual(status, 401)
            XCTAssertEqual(envelope?.tag, "UnauthorizedError")
        }
    }

    func testEmptySuccessHasEmptyPayload() async throws {
        stub(status: 204)
        let response = try await transport().perform(
            APIRequest(operationID: "location.reload", method: .get, path: "/api/location/reload")
        )
        XCTAssertEqual(response.payload, .empty)
    }

    func testNonJSONContentTypeYieldsBytesPayload() async throws {
        stub(body: "raw-bytes", contentType: "application/octet-stream")
        let response = try await transport().perform(
            APIRequest(operationID: "fs.read", method: .get, path: "/file")
        )
        guard case .bytes(let data) = response.payload else {
            return XCTFail("Expected bytes payload, got \(response.payload)")
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "raw-bytes")
    }

    func testSameOriginRequiresExactSchemeHostAndPort() throws {
        let base = URL(string: "https://host.example:4096/api/info")!
        XCTAssertTrue(URLSessionTransport.isSameOrigin(base, URL(string: "https://host.example:4096/other")!),
                      "the path alone may differ")
        XCTAssertFalse(URLSessionTransport.isSameOrigin(base, URL(string: "http://host.example:4096/api/info")!),
                       "a scheme downgrade must not count as the same origin")
        XCTAssertFalse(URLSessionTransport.isSameOrigin(base, URL(string: "https://evil.example:4096/api/info")!),
                       "a host change must not count as the same origin")
        XCTAssertFalse(URLSessionTransport.isSameOrigin(base, URL(string: "https://host.example:8443/api/info")!),
                       "a port change must not count as the same origin")
        XCTAssertFalse(URLSessionTransport.isSameOrigin(base, URL(string: "https://host.example/api/info")!),
                       "an explicit port never equals the default (fail closed)")
    }

    func testOriginGuardRefusesCrossOriginRedirectsForCredentialRequests() throws {
        // `perform`/`events` set Authorization by hand and URLSession
        // follows 3xx automatically — the guard is the only thing stopping
        // the host secret from riding along to another origin (W01Requests:
        // "stored secrets must never ride along to a destination").
        let original = URL(string: "https://host.example:4096/api/info")!
        let task = session.dataTask(with: URLRequest(url: original))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil
        ))
        let originGuard = URLSessionTransport.OriginGuard()

        // Each sentinel only survives if the completion handler never
        // runs. A reference box: the handler is `@Sendable` (matching
        // the SDK), so it cannot mutate a captured local var.
        final class Slot: @unchecked Sendable {
            var value: URLRequest?
        }
        let slot = Slot()
        slot.value = URLRequest(url: original)
        originGuard.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "http://host.example:4096/api/info")!)
        ) { slot.value = $0 }
        XCTAssertNil(slot.value, "an https→http downgrade must not receive the credential")

        slot.value = URLRequest(url: original)
        originGuard.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://evil.example:4096/api/info")!)
        ) { slot.value = $0 }
        XCTAssertNil(slot.value, "a host change must not receive the credential")

        slot.value = nil
        originGuard.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://host.example:4096/next")!)
        ) { slot.value = $0 }
        XCTAssertNotNil(slot.value, "same-origin redirects (path normalisation) still follow")
    }

    func testCrossOriginRedirectIsRefusedEndToEndSoTheCredentialNeverRides() async {
        // WIRING proof, not decision logic (review W13 r1): the
        // direct-call test above exercises the guard's decision; this
        // one drives the SAME guard through URLSession's redirect
        // machinery exactly as `perform` attaches it (per-task
        // delegate). If the delegate method failed to match the
        // optional requirement, URLSession would follow the 302 on its
        // own: the stub would see a second request — inheriting the
        // hand-set Authorization header — and the outcome would be the
        // follow-up's status, never the 302.
        let seen = Seen()
        StubURLProtocol.handler = { request in
            seen.capture(request)
            if request.url?.host == "evil.example" {
                let ok = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (ok, Data(#"{"data":{}}"#.utf8))
            }
            let redirect = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": "http://evil.example:4096/api/info"]
            )!
            return (redirect, Data())
        }

        do {
            _ = try await transport(credential: BasicCredential(secret: "stored"))
                .perform(APIRequest(operationID: "test.get", method: .get, path: "/api/info"))
            XCTFail("an unwired delegate would have FOLLOWED the redirect to a 200 — this means the 302 was delivered unfollowed")
        } catch TransportError.cancelled {
            // The refusal's observable outcome through a URLProtocol
            // stub: CFNetwork cancels the original protocol load while
            // processing the redirect decision, so the caller sees the
            // cancellation rather than the 302 body. The decisive
            // evidence is in the recorded requests below — an unwired
            // delegate would have followed (second request, final 200).
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(seen.all.count, 1, "nothing followed the cross-origin redirect")
        XCTAssertNotNil(
            seen.all.first?.value(forHTTPHeaderField: "Authorization"),
            "the credential was in play on the refused request — the guard is what stopped it"
        )
        XCTAssertFalse(
            seen.all.contains { $0.url?.host == "evil.example" },
            "the host secret never reached the redirect target"
        )
    }

    func testCredentialDescriptionsNeverPrintTheSecret() {
        // The type-level rule (APIRequest.swift): "Never log … or attach
        // to diagnostics." Every stringification path — interpolation,
        // String(reflecting:), dump, and any enclosing APIRequest —
        // must redact without caller discipline.
        let credential = BasicCredential(secret: "hunter2-secret")
        XCTAssertFalse("\(credential)".contains("hunter2-secret"))
        XCTAssertFalse(String(reflecting: credential).contains("hunter2-secret"))
        var dumped = ""
        dump(credential, to: &dumped)
        XCTAssertFalse(dumped.contains("hunter2-secret"))
        XCTAssertTrue(Mirror(reflecting: credential).children.isEmpty, "the mirror carries no fields to leak")

        let request = APIRequest(
            operationID: "test.get", method: .get, path: "/x", credential: credential
        )
        XCTAssertFalse("\(request)".contains("hunter2-secret"), "APIRequest embeds the credential")
    }

    func testConnectionFailureMapsToConnectionFailed() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await transport().perform(W01Requests.health(secret: "x"))
            XCTFail("Expected a thrown error")
        } catch let TransportError.connectionFailed(message) {
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testEventsStreamYieldsDecodedEvents() async throws {
        stub(
            body: ": heartbeat\n\ndata: {\"id\":\"evt_1\",\"type\":\"server.connected\",\"data\":{}}\n\n",
            contentType: "text/event-stream"
        )
        var received: [OpenCodeEvent] = []
        for try await event in transport(credential: BasicCredential(secret: "pw")).events() {
            received.append(event)
        }
        XCTAssertEqual(received.map(\.type), ["server.connected"])
    }

    /// The SSE spec allows CR-only line endings; such frames must still be
    /// delivered (the stream loop flushes on any line-break byte).
    func testEventsStreamDecodesCROnlyFrames() async throws {
        stub(
            body: "data: {\"id\":\"evt_2\",\"type\":\"server.idle\",\"data\":{}}\r\r",
            contentType: "text/event-stream"
        )
        var received: [OpenCodeEvent] = []
        for try await event in transport(credential: BasicCredential(secret: "pw")).events() {
            received.append(event)
        }
        XCTAssertEqual(received.map(\.type), ["server.idle"])
    }
}
