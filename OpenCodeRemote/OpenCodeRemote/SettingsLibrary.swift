import Foundation
import Observation

/// Light/dark/system (implementation-defaults.md: "Follow system light/
/// dark mode and Dynamic Type" by default; the control is
/// light/dark/system).
enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

/// Compact/comfortable text spacing — comfortable is the default.
enum TextSpacing: String, Codable, CaseIterable, Sendable {
    case comfortable, compact
}

/// Code font size relative to Dynamic Type (the control exists; the
/// defaults table fixes no numeric size, so medium mirrors the system
/// default and small/large are relative steps).
enum CodeFontSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large
}

/// Cache-size soft budget in MiB: 100, 500 (default), 1024, 2048.
/// Refetchable history only — never drafts or pending uploads
/// (implementation-defaults.md "Cache size").
enum CacheSizePolicy: Int, Codable, CaseIterable, Sendable {
    case mib100 = 100
    case mib500 = 500
    case mib1024 = 1024
    case mib2048 = 2048

    var label: String {
        switch self {
        case .mib100: "100 MiB"
        case .mib500: "500 MiB"
        case .mib1024: "1 GiB"
        case .mib2048: "2 GiB"
        }
    }
}

/// Draft retention since last edit: until sent/discarded (default),
/// 7, 30 or 90 days (implementation-defaults.md "Drafts").
enum DraftRetention: Codable, Equatable, Hashable, Sendable {
    case untilDiscarded
    case days(Int)

    static let allCases: [DraftRetention] = [.untilDiscarded, .days(7), .days(30), .days(90)]

    var label: String {
        switch self {
        case .untilDiscarded: "Until discarded"
        case .days(let days): "\(days) days since last edit"
        }
    }
}

/// Per-upload warning threshold: above 50 MiB by default; choices
/// 10/50/100 MiB or no warning (implementation-defaults.md "Uploads").
/// A warning only — never a hard limit.
enum UploadWarningThreshold: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case mib10 = 10
    case mib50 = 50
    case mib100 = 100

    var label: String {
        self == .off ? "No Warning" : "Above \(rawValue) MiB"
    }
}

/// App-lock grace after leaving the app: one minute by default;
/// Immediate/1/5/15 minutes (implementation-defaults.md "App lock").
enum AppLockGrace: Int, Codable, CaseIterable, Sendable {
    case immediate = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var label: String {
        switch self {
        case .immediate: "Immediately"
        case .oneMinute: "After 1 minute"
        case .fiveMinutes: "After 5 minutes"
        case .fifteenMinutes: "After 15 minutes"
        }
    }
}

/// Reopening behavior: restore last screen/session (default) or always
/// open projects (implementation-defaults.md "Reopening").
enum ReopenBehavior: String, Codable, CaseIterable, Sendable {
    case restoreLast
    case openProjects
}

/// Notification content privacy: generic (the safe default) or
/// detailed. Optional because the docs require an onboarding CHOICE —
/// until it is made, generic content is shown (implementation-
/// defaults.md "Notifications").
enum NotificationContentPrivacy: String, Codable, CaseIterable, Sendable {
    case generic
    case detailed
}

/// Which terminal outcomes notify (S17 "category switches") — all on
/// by default.
struct NotificationCategories: Codable, Equatable, Sendable {
    var succeeded = true
    var failed = true
    var interrupted = true
}

/// Live Activities start preference: ask during onboarding (default),
/// start automatically for app-started sessions, or manual Follow
/// Session only (implementation-defaults.md "Live Activities").
enum ActivityStartPreference: String, Codable, CaseIterable, Sendable {
    case ask
    case automatic
    case manual
}

/// Device-wide settings with the EXACT defaults from
/// docs/implementation-defaults.md (W17 S18/S19). Every field's
/// default there is mirrored here; tests pin them.
struct SettingsState: Codable, Equatable, Sendable {
    // Appearance
    var appearance: AppearanceMode = .system
    var spacing: TextSpacing = .comfortable
    /// Wrap is chosen as the native-default-on: unwrapped code would
    /// hide content behind horizontal scroll the docs never required.
    var wrapCodeLines = true
    var codeFontSize: CodeFontSize = .medium

    // Storage
    var cacheSizePolicy: CacheSizePolicy = .mib500
    var draftRetention: DraftRetention = .untilDiscarded
    /// History retention is FIXED at 30 days initially — not a
    /// setting (implementation-defaults.md "History").
    static let historyRetentionDays = 30

    // Attachments & network
    var uploadWarningThreshold: UploadWarningThreshold = .mib50
    var allowCellularUploads = true
    var continueBackgroundUploads = true

    // Privacy
    var appLockEnabled = false
    var appLockGrace: AppLockGrace = .oneMinute

    // Sync (off until opted in)
    var icloudSyncRequested = false

    // Reopening
    var reopen: ReopenBehavior = .restoreLast

    // Notifications & activities
    /// nil until the onboarding privacy choice is made → generic.
    var notificationContentPrivacy: NotificationContentPrivacy?
    var notificationCategories = NotificationCategories()
    var activityStartPreference: ActivityStartPreference = .ask
}

/// Persisted local settings (W17): device-wide state in one Codable
/// blob. Same UserDefaults-injection pattern as
/// `SessionLocalStateStore` so tests run on fresh domains.
@MainActor
@Observable
final class SettingsLibrary {
    @ObservationIgnored static let stateKey = "settings.state.v1"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var state: SettingsState

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.stateKey),
           let decoded = try? JSONDecoder().decode(SettingsState.self, from: data) {
            state = decoded
        } else {
            state = SettingsState()
        }
    }

    // MARK: - Device settings

    /// Mutates one field and persists the whole state blob. Settings
    /// changes are reversible and local (implementation-defaults.md
    /// "Settings boundaries").
    func update(_ mutate: (inout SettingsState) -> Void) {
        mutate(&state)
        persist()
    }

    /// Clear Local Data (S19): preferences return to the documented
    /// defaults. Hosts and their credentials are untouched: Remove
    /// Host owns those (design-review.md defines the pair together).
    func resetToDefaults() {
        state = SettingsState()
        persist()
        // Legacy per-host push preferences (removed feature) are local
        // data too: the old settings.hostpush.v1 blob must not survive
        // Clear Local Data (review: removal r1).
        defaults.removeObject(forKey: "settings.hostpush.v1")
    }

    // MARK: - Draft expiry (S19)

    /// The expiry date for a draft last edited at `lastEdit`; nil =
    /// kept until discarded (the default retention never expires).
    func draftExpiry(lastEdit: Date) -> Date? {
        switch state.draftRetention {
        case .untilDiscarded:
            return nil
        case .days(let days):
            return lastEdit.addingTimeInterval(Double(days) * 86_400)
        }
    }

    /// Switching to `retention` must be CONFIRMED when it would remove
    /// any existing draft (docs: "confirm shortening retention if
    /// existing drafts would be removed"). Lengthening never needs the
    /// confirmation, and until-discarded removes nothing.
    func draftRetentionRemovesExisting(_ existingLastEdits: [Date], now: Date = Date(), switchingTo retention: DraftRetention) -> Bool {
        switch retention {
        case .untilDiscarded:
            return false
        case .days(let days):
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            return existingLastEdits.contains { $0 < cutoff }
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }
}
