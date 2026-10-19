import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W01 flow tests against a canned transport: redemption, health check, and
/// the documented failure variants (docs/navigation-screens.md). Redemption
/// and completion are separate so a health failure can be retried with the
/// retained token instead of re-spending the single-use code.
final class HostPairingServiceTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [APIRequest] = []
        func record(_ request: APIRequest) { lock.lock(); recorded.append(request); lock.unlock() }
        var requests: [APIRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    private struct FakeTransport: OpenCodeTransport {
        let recorder: Recorder
        var redeem: Result<APIResponse, TransportError> = .failure(.connectionFailed("unstubbed redeem"))
        var health: Result<APIResponse, TransportError> = .failure(.connectionFailed("unstubbed health"))

        func perform(_ request: APIRequest) async throws -> APIResponse {
            recorder.record(request)
            switch request.operationID == "server.connect" ? redeem : health {
            case .success(let response): return response
            case .failure(let error): throw error
            }
        }

        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private let destination = URL(string: "https://192.168.1.20:4096")!

    private func service(
        recorder: Recorder,
        redeem: Result<APIResponse, TransportError>,
        health: Result<APIResponse, TransportError>
    ) -> HostPairingService {
        let transport = FakeTransport(recorder: recorder, redeem: redeem, health: health)
        return HostPairingService(makeTransport: { _ in transport })
    }

    private func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    // MARK: - Redeem

    func testRedeemReturnsTokenAndSendsNoAuthorization() async throws {
        let recorder = Recorder()
        let token = try await service(
            recorder: recorder,
            redeem: .success(json(#"{"token":"session-token"}"#)),
            health: .success(json(#"{"version":"2.0.25"}"#))
        ).redeem(code: "abc123", at: destination)

        XCTAssertEqual(token, "session-token")
        XCTAssertEqual(recorder.requests.map(\.operationID), ["server.connect"])
        XCTAssertEqual(recorder.requests.first?.path, "/auth/connect/abc123")
        XCTAssertNil(recorder.requests.first?.credential, "Redemption carries no stored credential")
    }

    func testRedeemUnauthorizedIsExpiredCode() async {
        do {
            _ = try await service(
                recorder: Recorder(),
                redeem: .failure(.http(status: 401, envelope: nil)),
                health: .success(json(#"{"version":"1"}"#))
            ).redeem(code: "spent", at: destination)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? HostPairingService.Failure, .expiredCode)
        }
    }

    func testRedeemUnreachableStaysUnreachable() async {
        do {
            _ = try await service(
                recorder: Recorder(),
                redeem: .failure(.connectionFailed("offline")),
                health: .success(json(#"{"version":"1"}"#))
            ).redeem(code: "c", at: destination)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? HostPairingService.Failure, .unreachable)
        }
    }

    func testRedeemMalformedSuccessPayloadIsInvalidResponse() async {
        do {
            _ = try await service(
                recorder: Recorder(),
                redeem: .success(json(#"{"not":"a token"}"#)),
                health: .success(json(#"{"version":"1"}"#))
            ).redeem(code: "c", at: destination)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? HostPairingService.Failure, .invalidResponse)
        }
    }

    func testRedeemNonJSONSuccessBodyIsInvalidResponse() async {
        // A reverse proxy's HTML page (or any 2xx non-JSON body) reaches
        // decodedJSON as .bytes → emptyBody. The host WAS reached; it
        // must never claim "The host couldn't be reached".
        do {
            _ = try await service(
                recorder: Recorder(),
                redeem: .success(APIResponse(
                    statusCode: 200, payload: .bytes(Data("<html>proxy</html>".utf8))
                )),
                health: .success(json(#"{"version":"1"}"#))
            ).redeem(code: "c", at: destination)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? HostPairingService.Failure, .invalidResponse)
        }
    }

    // MARK: - Complete pairing (health check)

    func testCompletePairingProvesTokenAndBuildsHost() async throws {
        let recorder = Recorder()
        let paired = try await service(
            recorder: recorder,
            redeem: .success(json(#"{"token":"t"}"#)),
            health: .success(json(#"{"version":"2.0.25","urls":[]}"#))
        ).completePairing(secret: "session-token", at: destination, displayName: "")

        XCTAssertEqual(paired.secret, "session-token")
        XCTAssertEqual(paired.host.address, destination)
        XCTAssertEqual(paired.host.lastVersion, "2.0.25")
        XCTAssertEqual(paired.host.displayName, "192.168.1.20", "Empty display name defaults to the host")

        XCTAssertEqual(recorder.requests.map(\.operationID), ["server.info"])
        XCTAssertEqual(recorder.requests.first?.credential?.secret, "session-token")
    }

    func testCompletePairingHonorsDisplayName() async throws {
        let paired = try await service(
            recorder: Recorder(),
            redeem: .success(json(#"{"token":"t"}"#)),
            health: .success(json(#"{"version":"1.0.0"}"#))
        ).completePairing(secret: "t", at: destination, displayName: "  Home server  ")
        XCTAssertEqual(paired.host.displayName, "Home server")
    }

    func testCompletePairingUnauthorizedIsRejectedCredential() async {
        do {
            _ = try await service(
                recorder: Recorder(),
                redeem: .success(json(#"{"token":"t"}"#)),
                health: .failure(.http(status: 401, envelope: nil))
            ).completePairing(secret: "t", at: destination, displayName: "")
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? HostPairingService.Failure, .rejectedCredential)
        }
    }

    func testCompletePairingUnreachableIsUnreachable() async {
        do {
            _ = try await service(
                recorder: Recorder(),
                redeem: .success(json(#"{"token":"t"}"#)),
                health: .failure(.connectionFailed("offline"))
            ).completePairing(secret: "t", at: destination, displayName: "")
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? HostPairingService.Failure, .unreachable)
        }
    }

    func testCompletePairingNonJSONSuccessBodyIsInvalidResponse() async {
        do {
            _ = try await service(
                recorder: Recorder(),
                redeem: .success(json(#"{"token":"t"}"#)),
                health: .success(APIResponse(
                    statusCode: 200, payload: .bytes(Data("<html>not opencode</html>".utf8))
                ))
            ).completePairing(secret: "t", at: destination, displayName: "")
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? HostPairingService.Failure, .invalidResponse,
                           "the address answered — it is not an OpenCode server")
        }
    }

    // MARK: - Manual password fallback

    func testVerifyPasswordRejectsNonContractUsernameBeforeAnyRequest() async {
        let recorder = Recorder()
        do {
            _ = try await service(
                recorder: recorder,
                redeem: .failure(.connectionFailed("unused")),
                health: .success(json(#"{"version":"1"}"#))
            ).verifyPassword(at: destination, username: "root", password: "pw", displayName: "")
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? HostPairingService.Failure, .unsupportedUsername)
        }
        XCTAssertTrue(recorder.requests.isEmpty, "No request may be sent with a non-contract username")
    }

    func testVerifyPasswordSucceedsWithContractUsername() async throws {
        let recorder = Recorder()
        let paired = try await service(
            recorder: recorder,
            redeem: .failure(.connectionFailed("unused")),
            health: .success(json(#"{"version":"2.0.25"}"#))
        ).verifyPassword(at: destination, username: "opencode", password: "host-password", displayName: "Lab")
        XCTAssertEqual(paired.secret, "host-password")
        XCTAssertEqual(paired.host.displayName, "Lab")
        XCTAssertEqual(recorder.requests.map(\.operationID), ["server.info"])
        XCTAssertEqual(recorder.requests.first?.credential?.secret, "host-password")
    }
}
