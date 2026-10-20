import XCTest
import UserNotifications
@testable import OpenCodeRemote

/// W17 S17: the library maps the OS permission to its S17 label,
/// never asks on its own, and records BOTH ask outcomes in the
/// diagnostic log (a denied permission is the one state that
/// silently stops delivery).
@MainActor
final class NotificationsLibraryTests: XCTestCase {
    private final class FakePermission: NotificationPermissionProviding, @unchecked Sendable {
        var status: UNAuthorizationStatus = .notDetermined
        var answer = false
        private(set) var askCount = 0

        func authorizationStatus() async -> UNAuthorizationStatus { status }
        func requestAuthorization() async -> Bool {
            askCount += 1
            // The OS moves its own state with the decision: a grant
            // reads back authorized, a refusal reads back denied.
            status = answer ? .authorized : .denied
            return answer
        }
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationsLibraryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func makeLibrary(_ permission: FakePermission) -> NotificationsLibrary {
        NotificationsLibrary(
            permission: permission,
            log: DiagnosticsLogStore(directory: directory)
        )
    }

    func testStatusLabelMapsEveryKnownStatus() async {
        let permission = FakePermission()
        let library = makeLibrary(permission)

        XCTAssertEqual(library.statusLabel, "Not Asked Yet", "nil status (nothing loaded) reads as not asked")

        for (status, label): (UNAuthorizationStatus, String) in [
            (.authorized, "Allowed"),
            (.denied, "Denied"),
            (.provisional, "Allowed (Quiet)"),
            (.ephemeral, "Allowed (Temporary)"),
            (.notDetermined, "Not Asked Yet"),
        ] {
            permission.status = status
            await library.load()
            XCTAssertEqual(library.statusLabel, label)
        }
    }

    func testAskGrantedReloadsStatusAndLogsTheOutcome() async {
        let permission = FakePermission()
        permission.answer = true
        let library = makeLibrary(permission)

        await library.ask()

        XCTAssertEqual(permission.askCount, 1)
        XCTAssertEqual(library.statusLabel, "Allowed", "the status reloads from the OS after the ask")
        let log = DiagnosticsLogStore(directory: directory)
        XCTAssertEqual(log.entries().map(\.message), ["Notification permission granted"])
        XCTAssertEqual(log.entries().map(\.severity), [.info])
    }

    func testAskDeniedIsRecordedAsAnError() async {
        let permission = FakePermission()
        permission.answer = false
        let library = makeLibrary(permission)

        await library.ask()

        XCTAssertEqual(library.statusLabel, "Denied", "the OS's refusal reads back as its own state")
        let log = DiagnosticsLogStore(directory: directory)
        XCTAssertEqual(log.entries().map(\.message), ["Notification permission not granted"])
        XCTAssertEqual(log.entries().map(\.severity), [.error], "denied is the state S20's last-error display must surface")
    }
}
