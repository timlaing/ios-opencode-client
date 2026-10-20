import Foundation
import Observation
import UserNotifications

/// The OS permission touch points behind a protocol so the S17
/// status/ask logic is testable without UNUserNotificationCenter.
protocol NotificationPermissionProviding: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
}

/// The real UserNotifications bridge.
struct CenterNotificationPermission: NotificationPermissionProviding {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await (try? UNUserNotificationCenter.current().notificationSettings())?.authorizationStatus
            ?? .notDetermined
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}

/// S17: the iOS notification permission state, shown SEPARATELY from
/// the app's own category/privacy choices (docs/navigation-screens.md
/// S17: "these are separate states"). The ask is user-initiated (the
/// S17 button, or the lazy first-event ask W16 already performs) —
/// this library never asks on its own.
@MainActor
@Observable
final class NotificationsLibrary {
    @ObservationIgnored let permission: NotificationPermissionProviding
    @ObservationIgnored let log: DiagnosticsLogStore

    private(set) var status: UNAuthorizationStatus?
    private(set) var askInFlight = false

    init(
        permission: NotificationPermissionProviding = CenterNotificationPermission(),
        log: DiagnosticsLogStore = DiagnosticsLogStore()
    ) {
        self.permission = permission
        self.log = log
    }

    func load() async {
        status = await permission.authorizationStatus()
    }

    /// User-initiated ask. The OS answers subsequent asks from its
    /// own cached decision; `false` means denied-or-failed — the
    /// reloaded status tells them apart (denied vs still undecided).
    /// Both outcomes land in diagnostics: a denied permission is the
    /// one state that silently stops delivery.
    func ask() async {
        guard !askInFlight else { return }
        askInFlight = true
        defer { askInFlight = false }
        let granted = await permission.requestAuthorization()
        await load()
        if granted {
            log.record(.notifications, "Notification permission granted")
        } else {
            log.record(.notifications, severity: .error, "Notification permission not granted")
        }
    }

    /// The S17 display label; code paths branch on the raw status.
    var statusLabel: String {
        switch status {
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .provisional: "Allowed (Quiet)"
        case .ephemeral: "Allowed (Temporary)"
        case .notDetermined, nil: "Not Asked Yet"
        @unknown default: "Unknown"
        }
    }
}
