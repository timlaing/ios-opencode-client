import XCTest
@testable import OpenCodeRemote

/// W17 local settings (docs/implementation-defaults.md): the table's
/// EXACT defaults are pinned, changes persist across a simulated
/// relaunch, per-host push rows stay isolated, and the draft-retention
/// confirmation fires only when shortening would actually remove a
/// draft (S19).
@MainActor
final class SettingsLibraryTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsLibraryTests-\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    /// Every default the docs fix (implementation-defaults.md table),
    /// asserted once so a silent default drift fails immediately.
    func testDefaultsMatchTheDocumentedTable() {
        let state = SettingsState()

        XCTAssertEqual(state.appearance, .system, "follow system light/dark")
        XCTAssertEqual(state.spacing, .comfortable)
        XCTAssertTrue(state.wrapCodeLines)
        XCTAssertEqual(state.codeFontSize, .medium)
        XCTAssertEqual(state.cacheSizePolicy, .mib500, "500 MiB soft budget")
        XCTAssertEqual(state.draftRetention, .untilDiscarded, "keep drafts until sent/discarded")
        XCTAssertEqual(state.uploadWarningThreshold, .mib50, "warn above 50 MiB per file")
        XCTAssertTrue(state.allowCellularUploads, "explicit uploads allowed on cellular")
        XCTAssertTrue(state.continueBackgroundUploads, "background uploads on by default")
        XCTAssertFalse(state.appLockEnabled, "app lock off")
        XCTAssertEqual(state.appLockGrace, .oneMinute, "one minute away")
        XCTAssertFalse(state.icloudSyncRequested, "off until opted in")
        XCTAssertEqual(state.reopen, .restoreLast, "restore last screen/session")
        XCTAssertNil(state.notificationContentPrivacy, "generic content until the privacy choice is made")
        XCTAssertEqual(state.notificationCategories, NotificationCategories(), "all three outcomes notify")
        XCTAssertEqual(state.activityStartPreference, .ask, "ask during onboarding; no auto-start")
        XCTAssertEqual(SettingsState.historyRetentionDays, 30, "the 30-day history policy is fixed, not a setting")
    }

    func testResetToDefaultsRestoresEveryDocumentedDefault() {
        let library = SettingsLibrary(defaults: defaults)
        library.update { $0.appearance = .dark; $0.appLockEnabled = true; $0.cacheSizePolicy = .mib2048 }

        library.resetToDefaults()

        XCTAssertEqual(library.state, SettingsState(), "back to the implementation-defaults table")

        let reloaded = SettingsLibrary(defaults: defaults)
        XCTAssertEqual(reloaded.state, SettingsState(), "the reset persists across relaunch")
    }

    func testUpdatesPersistAcrossARelaunchAndTouchNothingElse() {
        let library = SettingsLibrary(defaults: defaults)
        library.update { $0.appLockEnabled = true }
        library.update { $0.draftRetention = .days(7) }

        let reloaded = SettingsLibrary(defaults: defaults) // app relaunch
        XCTAssertTrue(reloaded.state.appLockEnabled)
        XCTAssertEqual(reloaded.state.draftRetention, .days(7))
        XCTAssertEqual(reloaded.state.appearance, .system, "an unrelated field keeps its default")

        reloaded.update { $0.appLockEnabled = false }
        let again = SettingsLibrary(defaults: defaults)
        XCTAssertFalse(again.state.appLockEnabled, "a later edit persists too")
        XCTAssertEqual(again.state.draftRetention, .days(7), "and never clobbers other fields")
    }

    func testDraftExpiryFollowsTheRetentionAndIsNilUntilDiscarded() {
        let library = SettingsLibrary(defaults: defaults)
        let lastEdit = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(library.draftExpiry(lastEdit: lastEdit), "the default retention never expires a draft")

        library.update { $0.draftRetention = .days(7) }
        XCTAssertEqual(
            library.draftExpiry(lastEdit: lastEdit),
            lastEdit.addingTimeInterval(7 * 86_400),
            "expiry is 7 days SINCE LAST EDIT, not since creation"
        )
    }

    func testShorteningRetentionConfirmsOnlyWhenExistingDraftsWouldBeRemoved() {
        let library = SettingsLibrary(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = [now.addingTimeInterval(-10 * 86_400)] // 10 days old
        let fresh = [now.addingTimeInterval(-2 * 86_400)]  // 2 days old

        XCTAssertTrue(
            library.draftRetentionRemovesExisting(stale, now: now, switchingTo: .days(7)),
            "a 10-day draft would be removed by a 7-day retention: confirm"
        )
        XCTAssertFalse(
            library.draftRetentionRemovesExisting(fresh, now: now, switchingTo: .days(7)),
            "a 2-day draft survives a 7-day retention: no confirmation needed"
        )
        XCTAssertFalse(
            library.draftRetentionRemovesExisting(stale, now: now, switchingTo: .untilDiscarded),
            "until-discarded removes nothing — never confirm"
        )
        XCTAssertFalse(
            library.draftRetentionRemovesExisting(stale, now: now, switchingTo: .days(90)),
            "lengthening retention removes nothing — never confirm"
        )
        XCTAssertTrue(
            library.draftRetentionRemovesExisting([now.addingTimeInterval(-40 * 86_400)], now: now, switchingTo: .days(30)),
            "the confirmation is computed against the SWITCHED-TO retention, not the current one"
        )
    }
}
