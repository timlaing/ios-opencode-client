import XCTest
import OpenCodeDomain
@testable import OpenCodeRemote

/// W17 S17/S02: eligibility is the exact shape the configuration
/// controller consumes, followed sessions ride along sorted, and the
/// status mapping never claims more than the evidence — with the
/// entitlement pending, every configured host answers
/// `unsupportedEntitlement`.
@MainActor
final class PushEligibilityTests: XCTestCase {
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PushEligibilityTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    private func makeSettings() -> SettingsLibrary {
        SettingsLibrary(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testEntitlementIsPinnedToThePendingTruth() {
        XCTAssertFalse(
            PushEligibility.entitlementGranted,
            "the signed app-push-provider entitlement is still pending — nothing may present delivery as active"
        )
    }

    func testHostEligibilityBuildsTheControllerShapeSortedByHostID() {
        let settings = makeSettings()
        settings.updatePushSettings(for: "host_b") { value in
            value.enabled = true
            value.ssids = ["Home"]
        }

        let eligibility = PushEligibility.hostEligibility(
            hostIDs: ["host_b", "host_a"],
            settings: settings,
            hasCredential: { $0 == "host_a" }
        )

        XCTAssertEqual(eligibility.map(\.hostID), ["host_a", "host_b"], "sorted — list order is never a change")
        XCTAssertEqual(eligibility[0], LocalPushHostEligibility(hostID: "host_a", enabled: false, hasCredential: true, ssids: []))
        XCTAssertEqual(eligibility[1], LocalPushHostEligibility(hostID: "host_b", enabled: true, hasCredential: false, ssids: ["Home"]))
    }

    func testFollowedSessionsRideAlongSortedAcrossHosts() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let localState = SessionLocalStateStore(defaults: defaults)
        localState.togglePinned(SessionKey(hostID: HostID(rawValue: "h2"), sessionID: "ses_b"))
        localState.toggleFollowed(SessionKey(hostID: HostID(rawValue: "h1"), sessionID: "ses_z"))
        localState.toggleFollowed(SessionKey(hostID: HostID(rawValue: "h2"), sessionID: "ses_a"))

        let followed = PushEligibility.followedSessions(localState)

        XCTAssertEqual(followed.count, 2, "pinned is not followed")
        XCTAssertEqual(followed, followed.sorted(), "stable order — the payload never churns on dictionary order")
    }

    func testStatusNeverClaimsMoreThanTheEvidence() {
        // Disabled is off regardless of platform facts.
        XCTAssertEqual(
            PushEligibility.status(enabled: false, hasCredential: true, ssids: ["Home"], entitlementGranted: true),
            .disabled
        )
        // A missing credential needs re-pairing before anything else.
        XCTAssertEqual(
            PushEligibility.status(enabled: true, hasCredential: false, ssids: ["Home"], entitlementGranted: true),
            .missingCredential
        )
        // Enabled with no SSID is not configured yet.
        XCTAssertEqual(
            PushEligibility.status(enabled: true, hasCredential: true, ssids: [], entitlementGranted: true),
            .notConfigured
        )
        // The W17 truth: configured but unentitled is unsupported, never waiting.
        XCTAssertEqual(
            PushEligibility.status(enabled: true, hasCredential: true, ssids: ["Home"], entitlementGranted: false),
            .unsupportedEntitlement
        )
        // Only a granted entitlement can reach the eligible-Wi-Fi wait.
        XCTAssertEqual(
            PushEligibility.status(enabled: true, hasCredential: true, ssids: ["Home"], entitlementGranted: true),
            .waitingForEligibleWiFi
        )
    }

    func testDefaultStatusUsesThePinnedEntitlementTruth() {
        XCTAssertEqual(
            PushEligibility.status(enabled: true, hasCredential: true, ssids: ["Home"]),
            .unsupportedEntitlement,
            "callers that omit the flag get the pending-entitlement answer, never a hopeful one"
        )
    }
}
