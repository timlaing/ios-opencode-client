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
        private var request: URLRequest?
        func capture(_ request: URLRequest) { lock.lock(); self.request = request; lock.unlock() }
        var current: URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
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
}
