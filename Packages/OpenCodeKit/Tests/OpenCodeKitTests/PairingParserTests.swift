import XCTest
@testable import OpenCodeTransport

final class PairingParserTests: XCTestCase {
    // MARK: - Pinned link form

    func testPairingLinkParsesOriginAndCode() throws {
        let payload = try PairingParser.parse("https://192.168.1.20:4096/auth/connect/abc-DEF_123")
        XCTAssertEqual(payload.code, "abc-DEF_123")
        XCTAssertEqual(payload.destinations.map(\.absoluteString), ["https://192.168.1.20:4096"])
    }

    func testPlainHTTPLinkIsAcceptedForMockParity() throws {
        let payload = try PairingParser.parse("http://127.0.0.1:4097/auth/connect/c1")
        XCTAssertEqual(payload.destinations.map(\.absoluteString), ["http://127.0.0.1:4097"])
    }

    func testLinkOriginDropsUserinfoQueryAndFragmentLikePinnedOrigin() throws {
        let payload = try PairingParser.parse("https://user:pass@host.example:1/auth/connect/x1?a=2#frag")
        XCTAssertEqual(payload.destinations.map(\.absoluteString), ["https://host.example:1"])
        XCTAssertEqual(payload.code, "x1")
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        let payload = try PairingParser.parse("\n  https://host.example/auth/connect/x1  \n")
        XCTAssertEqual(payload.destinations.map(\.absoluteString), ["https://host.example"])
    }

    func testLegacyCredentialBearingConnectLinkIsRejected() {
        XCTAssertThrowsError(try PairingParser.parse("https://host.example/connect#opencode://token")) { error in
            XCTAssertEqual(error as? PairingParseError, .legacyLink)
        }
        XCTAssertThrowsError(try PairingParser.parse("https://host.example/connect?data=abc")) { error in
            XCTAssertEqual(error as? PairingParseError, .legacyLink)
        }
    }

    func testNonConnectPathIsRejected() {
        for value in [
            "https://host.example/auth/connect",
            "https://host.example/auth/connect/x1/extra",
            "https://host.example/connect/x1",
        ] {
            XCTAssertThrowsError(try PairingParser.parse(value)) { error in
                XCTAssertEqual(error as? PairingParseError, .notAPairingLink, value)
            }
        }
    }

    func testUnsupportedSchemeIsRejected() {
        XCTAssertThrowsError(try PairingParser.parse("ftp://host.example/auth/connect/x1")) { error in
            XCTAssertEqual(error as? PairingParseError, .unsupportedScheme)
        }
    }

    func testNonURLTextIsRejectedAsNotAPairingLink() {
        for value in ["hello world", "opencode pair", "not a link"] {
            XCTAssertThrowsError(try PairingParser.parse(value)) { error in
                XCTAssertEqual(error as? PairingParseError, .notAPairingLink, value)
            }
        }
    }

    func testEmptyInputIsRejected() {
        XCTAssertThrowsError(try PairingParser.parse("   \n ")) { error in
            XCTAssertEqual(error as? PairingParseError, .emptyInput)
        }
    }

    // MARK: - Pinned JSON QR payload

    func testJSONPayloadKeepsAddressOrder() throws {
        let qr = #"{"code":"x1","urls":["https://a.example:1","https://b.example:2"]}"#
        let payload = try PairingParser.parse(qr)
        XCTAssertEqual(payload.code, "x1")
        XCTAssertEqual(payload.destinations.map(\.absoluteString), ["https://a.example:1", "https://b.example:2"])
    }

    func testJSONPayloadCollapsesDuplicateAddresses() throws {
        let qr = #"{"code":"x1","urls":["https://a.example","https://a.example"]}"#
        let payload = try PairingParser.parse(qr)
        XCTAssertEqual(payload.destinations.map(\.absoluteString), ["https://a.example"])
    }

    func testJSONPayloadIgnoresUnknownKeys() throws {
        let qr = #"{"code":"x1","urls":["https://a.example"],"extra":42}"#
        XCTAssertEqual(try PairingParser.parse(qr).code, "x1")
    }

    func testOneInvalidAddressRejectsWholeJSONPayload() {
        for (value, expected) in [
            (#"{"code":"x1","urls":["https://ok.example","ftp://bad.example"]}"#, PairingParseError.unsupportedScheme),
            (#"{"code":"x1","urls":["https://ok.example","https://user:pass@bad.example"]}"#, PairingParseError.credentialBearingAddress),
            (#"{"code":"x1","urls":["https://ok.example?q=1"]}"#, PairingParseError.credentialBearingAddress),
            (#"{"code":"x1","urls":["https://ok.example#frag"]}"#, PairingParseError.credentialBearingAddress),
        ] {
            XCTAssertThrowsError(try PairingParser.parse(value)) { error in
                XCTAssertEqual(error as? PairingParseError, expected, value)
            }
        }
    }

    func testInvalidCodeInJSONPayloadIsRejected() {
        XCTAssertThrowsError(try PairingParser.parse(#"{"code":"a b","urls":["https://a.example"]}"#)) { error in
            XCTAssertEqual(error as? PairingParseError, .invalidCode)
        }
    }

    func testEmptyOrMissingURLsRejectsJSONPayload() {
        XCTAssertThrowsError(try PairingParser.parse(#"{"code":"x1","urls":[]}"#)) { error in
            XCTAssertEqual(error as? PairingParseError, .noDestinations)
        }
        XCTAssertThrowsError(try PairingParser.parse(#"{"code":"x1"}"#)) { error in
            XCTAssertEqual(error as? PairingParseError, .notAPairingLink)
        }
        XCTAssertThrowsError(try PairingParser.parse(#"{"urls":["https://a.example"]}"#)) { error in
            XCTAssertEqual(error as? PairingParseError, .notAPairingLink)
        }
    }

    func testTruncatedJSONIsRejected() {
        XCTAssertThrowsError(try PairingParser.parse(#"{"code":"x1","ur"#)) { error in
            XCTAssertEqual(error as? PairingParseError, .notAPairingLink)
        }
    }

    // MARK: - Manual (password-fallback) address

    func testManualAddressDefaultsToHTTPSWithExplicitPort() throws {
        let url = try PairingParser.manualAddress(host: "192.168.1.20", port: "4096")
        XCTAssertEqual(url.absoluteString, "https://192.168.1.20:4096")
    }

    func testManualAddressHonorsExplicitHTTPPrefix() throws {
        let url = try PairingParser.manualAddress(host: "http://192.168.1.20", port: "4097")
        XCTAssertEqual(url.absoluteString, "http://192.168.1.20:4097")
    }

    func testManualAddressAllowsLocalhostAndDottedHostsWithoutPort() throws {
        XCTAssertEqual(try PairingParser.manualAddress(host: "localhost", port: "").absoluteString, "https://localhost")
        XCTAssertEqual(try PairingParser.manualAddress(host: "opencode.local", port: "").absoluteString, "https://opencode.local")
    }

    func testManualAddressRejectsSingleLabelHostWithoutPort() {
        XCTAssertThrowsError(try PairingParser.manualAddress(host: "nas", port: "")) { error in
            XCTAssertEqual(error as? PairingParseError, .invalidAddress)
        }
        XCTAssertEqual(try PairingParser.manualAddress(host: "nas", port: "4096").absoluteString, "https://nas:4096")
    }

    func testManualAddressRejectsEmptyHostAndBadPorts() {
        for (host, port) in [("", "4096"), ("host.example", "abc"), ("host.example", "99999")] {
            XCTAssertThrowsError(try PairingParser.manualAddress(host: host, port: port)) { error in
                XCTAssertEqual(error as? PairingParseError, .invalidAddress, "\(host):\(port)")
            }
        }
    }

    func testManualAddressRejectsCredentialBearingHost() {
        XCTAssertThrowsError(try PairingParser.manualAddress(host: "https://user:pass@host.example", port: "")) { error in
            XCTAssertEqual(error as? PairingParseError, .credentialBearingAddress)
        }
    }

    func testManualAddressAcceptsProxyPrefixPath() throws {
        let url = try PairingParser.manualAddress(host: "https://gateway.example/opencode", port: "")
        XCTAssertEqual(url.absoluteString, "https://gateway.example/opencode")
    }
}
