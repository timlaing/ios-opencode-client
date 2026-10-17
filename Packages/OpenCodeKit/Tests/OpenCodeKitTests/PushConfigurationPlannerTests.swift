import XCTest
@testable import OpenCodeDomain

/// Desired-config planner tests (docs/local-push-implementation.md
/// §"App-side manager configuration" steps 1–4 and the derived native test
/// list): grouping, eligibility, sort/dedup stability, and minimal diffs.
final class PushConfigurationPlannerTests: XCTestCase {
    func testMultipleHostsOnOneSSIDProduceOneManager() {
        let desired = PushConfigurationPlanner.desiredState(from: [
            LocalPushHostEligibility(hostID: "host_b", enabled: true, hasCredential: true, ssids: ["Home"]),
            LocalPushHostEligibility(hostID: "host_a", enabled: true, hasCredential: true, ssids: ["Home"]),
        ])
        XCTAssertEqual(desired, ["Home": ["host_a", "host_b"]], "IDs are sorted so order never matters")
    }

    func testOneHostOnTwoSSIDsHasBothMemberships() {
        let desired = PushConfigurationPlanner.desiredState(from: [
            LocalPushHostEligibility(hostID: "host_a", enabled: true, hasCredential: true, ssids: ["Home", "Office"])
        ])
        XCTAssertEqual(desired, ["Home": ["host_a"], "Office": ["host_a"]])
    }

    func testEligibilityExcludesDisabledCredentiallessAndBlankEntries() {
        let desired = PushConfigurationPlanner.desiredState(from: [
            LocalPushHostEligibility(hostID: "host_a", enabled: false, hasCredential: true, ssids: ["Home"]),
            LocalPushHostEligibility(hostID: "host_b", enabled: true, hasCredential: false, ssids: ["Home"]),
            LocalPushHostEligibility(hostID: "host_c", enabled: true, hasCredential: true, ssids: ["  "]),
            LocalPushHostEligibility(hostID: "host_d", enabled: true, hasCredential: true, ssids: []),
            LocalPushHostEligibility(hostID: "host_e", enabled: true, hasCredential: true, ssids: [" Home "]),
        ])
        XCTAssertEqual(desired, ["Home": ["host_e"]], "whitespace is trimmed; blank entries never create managers")
    }

    func testDuplicateAndReorderedEntriesAreStable() {
        let a = PushConfigurationPlanner.desiredState(from: [
            LocalPushHostEligibility(hostID: "host_a", enabled: true, hasCredential: true, ssids: ["Home", "Home"]),
            LocalPushHostEligibility(hostID: "host_b", enabled: true, hasCredential: true, ssids: ["Home"]),
        ])
        let b = PushConfigurationPlanner.desiredState(from: [
            LocalPushHostEligibility(hostID: "host_b", enabled: true, hasCredential: true, ssids: ["Home"]),
            LocalPushHostEligibility(hostID: "host_a", enabled: true, hasCredential: true, ssids: ["Home"]),
        ])
        XCTAssertEqual(a, b)
    }

    func testIdenticalDesiredStateIsANoOp() {
        let desired = ["Home": ["host_a", "host_b"], "Office": ["host_a"]]
        let current = [
            ManagedPushConfiguration(ssid: "Home", hostIDs: ["host_a", "host_b"], revision: 1),
            ManagedPushConfiguration(ssid: "Office", hostIDs: ["host_a"], revision: 1),
        ]
        let plan = PushConfigurationPlanner.plan(desired: desired, current: current, revision: 2)
        XCTAssertTrue(plan.isEmpty, "identical desired state must not churn preferences")
    }

    func testChangedAndNewSSIDsUpsertRemovedSSIDsAreRemoved() {
        let desired = ["Home": ["host_a"], "Office": ["host_a", "host_c"]]
        let current = [
            ManagedPushConfiguration(ssid: "Home", hostIDs: ["host_a", "host_b"], revision: 1),
            ManagedPushConfiguration(ssid: "Garage", hostIDs: ["host_b"], revision: 1),
        ]
        let plan = PushConfigurationPlanner.plan(desired: desired, current: current, revision: 7)
        XCTAssertEqual(
            plan.upserts,
            [
                ManagedPushConfiguration(ssid: "Home", hostIDs: ["host_a"], revision: 7),
                ManagedPushConfiguration(ssid: "Office", hostIDs: ["host_a", "host_c"], revision: 7),
            ],
            "upserts are sorted by SSID and carry the new revision"
        )
        XCTAssertEqual(plan.removals, ["Garage"])
    }

    func testDisablingAHostRemovesItsLastManager() {
        let eligibility = [
            LocalPushHostEligibility(hostID: "host_a", enabled: false, hasCredential: true, ssids: ["Home"])
        ]
        let desired = PushConfigurationPlanner.desiredState(from: eligibility)
        XCTAssertTrue(desired.isEmpty)
        let plan = PushConfigurationPlanner.plan(
            desired: desired,
            current: [ManagedPushConfiguration(ssid: "Home", hostIDs: ["host_a"], revision: 1)],
            revision: 2
        )
        XCTAssertEqual(plan.upserts, [])
        XCTAssertEqual(plan.removals, ["Home"], "stale managers are removed, not merely disabled")
    }

    func testPlanIsDeterministic() {
        let desired = ["Zulu": ["host_z"], "Alpha": ["host_a"]]
        let planA = PushConfigurationPlanner.plan(desired: desired, current: [], revision: 3)
        let planB = PushConfigurationPlanner.plan(desired: desired, current: [], revision: 3)
        XCTAssertEqual(planA, planB)
        XCTAssertEqual(planA.upserts.map(\.ssid), ["Alpha", "Zulu"])
    }
}
