import XCTest
import OpenCodeDomain

final class OpenCodeRemoteTests: XCTestCase {
    func testHostDiagnosticsDescriptionRedactsAddress() throws {
        let host = Host(
            id: HostID(rawValue: "H-1"),
            displayName: "demo",
            address: try XCTUnwrap(URL(string: "https://secret-host.internal:4097"))
        )
        let description = host.redactedDiagnosticsDescription
        XCTAssertFalse(description.contains("secret-host"))
        XCTAssertTrue(description.contains("H-1"))
    }
}
