import XCTest
import OpenCodeDomain
@testable import OpenCodeRemote

/// Reconciliation controller tests (docs/local-push-implementation.md
/// §"App-side manager configuration" steps 4–6 and the derived native test
/// list): save/remove application, no-op on identical state, coalescing
/// without losing the latest request, and failure release.
@MainActor
final class LocalPushConfigurationControllerTests: XCTestCase {
    private final class FakeAdapter: PushManagerAdapter {
        struct Failure: Error, LocalizedError {
            let errorDescription: String? = "preferences unavailable"
        }

        var stored: [ManagedPushConfiguration] = []
        var failNextLoad = false
        var saveDelay: TimeInterval = 0
        private(set) var loadCount = 0
        private(set) var saves: [ManagedPushConfiguration] = []
        private(set) var removes: [String] = []

        func loadAll() async throws -> [ManagedPushConfiguration] {
            loadCount += 1
            if failNextLoad {
                failNextLoad = false
                throw Failure()
            }
            return stored
        }

        func save(_ configuration: ManagedPushConfiguration) async throws {
            if saveDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(saveDelay * 1_000_000_000))
            }
            saves.append(configuration)
            stored.removeAll { $0.ssid == configuration.ssid }
            stored.append(configuration)
        }

        func remove(ssid: String) async throws {
            removes.append(ssid)
            stored.removeAll { $0.ssid == ssid }
        }
    }

    private func eligibility(host: String = "host_a", ssid: String = "Home") -> [LocalPushHostEligibility] {
        [LocalPushHostEligibility(hostID: host, enabled: true, hasCredential: true, ssids: [ssid])]
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(label)")
    }

    func testAppliesPlanWithSaveRemoveAndReload() async throws {
        let adapter = FakeAdapter()
        adapter.stored = [ManagedPushConfiguration(ssid: "Garage", hostIDs: ["host_b"], revision: 1)]
        let controller = LocalPushConfigurationController(adapter: adapter, settleDelay: 0)

        controller.reconcile(eligibility: eligibility())
        try await waitUntil("reload after save") { adapter.loadCount >= 2 }

        XCTAssertEqual(adapter.removes, ["Garage"], "stale managers are removed, not merely disabled")
        XCTAssertEqual(adapter.saves.count, 1)
        XCTAssertEqual(adapter.saves.first?.ssid, "Home")
        XCTAssertEqual(adapter.saves.first?.hostIDs, ["host_a"])
        XCTAssertEqual(adapter.saves.first?.revision, 1)
        XCTAssertNil(controller.lastFailure)
    }

    func testIdenticalDesiredStateIsANoOpWithoutReload() async throws {
        let adapter = FakeAdapter()
        adapter.stored = [ManagedPushConfiguration(ssid: "Home", hostIDs: ["host_a"], revision: 41)]
        let controller = LocalPushConfigurationController(adapter: adapter, settleDelay: 0)

        controller.reconcile(eligibility: eligibility())
        try await waitUntil("loop finished") { adapter.loadCount >= 1 }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(adapter.saves, [])
        XCTAssertEqual(adapter.removes, [])
        XCTAssertEqual(adapter.loadCount, 1, "identical desired state must not save or reload")
    }

    func testInFlightCoalescingAppliesLatestAndDropsIntermediate() async throws {
        let adapter = FakeAdapter()
        adapter.saveDelay = 0.05
        let controller = LocalPushConfigurationController(adapter: adapter, settleDelay: 0)

        controller.reconcile(eligibility: eligibility(host: "host_a"))
        try await waitUntil("first apply in flight") { adapter.loadCount >= 1 }
        controller.reconcile(eligibility: eligibility(host: "host_b")) // dropped
        controller.reconcile(eligibility: eligibility(host: "host_c")) // wins

        try await waitUntil("latest applied") { adapter.saves.count >= 2 }
        XCTAssertEqual(adapter.saves.map(\.hostIDs), [["host_a"], ["host_c"]], "intermediate churn is dropped; the latest request is never lost")
    }

    func testFailureSurfacesAndLaterRequestSucceeds() async throws {
        let adapter = FakeAdapter()
        adapter.failNextLoad = true
        let controller = LocalPushConfigurationController(adapter: adapter, settleDelay: 0)

        controller.reconcile(eligibility: eligibility())
        try await waitUntil("failure surfaced") { controller.lastFailure != nil }
        XCTAssertTrue(controller.lastFailure?.contains("preferences unavailable") ?? false)

        controller.reconcile(eligibility: eligibility(host: "host_z"))
        try await waitUntil("retry applied") { adapter.saves.count >= 1 }
        XCTAssertNil(controller.lastFailure, "a successful apply clears the failure")
        XCTAssertEqual(adapter.saves.first?.hostIDs, ["host_z"])
    }

    func testRequestQueuedDuringFailedApplyIsNotLost() async throws {
        let adapter = FakeAdapter()
        adapter.failNextLoad = true
        adapter.saveDelay = 0
        let controller = LocalPushConfigurationController(adapter: adapter, settleDelay: 0)

        controller.reconcile(eligibility: eligibility(host: "host_a"))
        try await waitUntil("first apply in flight") { adapter.loadCount >= 1 }
        controller.reconcile(eligibility: eligibility(host: "host_b"))

        try await waitUntil("queued request applied") { adapter.saves.count >= 1 }
        XCTAssertEqual(adapter.saves.first?.hostIDs, ["host_b"])
        XCTAssertNil(controller.lastFailure, "the queued request runs after the failure and clears it")
    }
}
