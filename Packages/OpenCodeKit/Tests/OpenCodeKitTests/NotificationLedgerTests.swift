import XCTest
@testable import OpenCodeStorage

/// Ledger tests (docs/local-push-implementation.md §"Notification
/// classification and scheduling"): transactional claims with owner leases,
/// scheduler-result recording, and crash/restart reconciliation against the
/// OS pending/delivered identifier sets.
final class NotificationLedgerTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date = Date(timeIntervalSince1970: 1_000)) { self.date = date }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(seconds) }
    }

    private let key = "host:host_1|session:ses_a|owner:-|transition:evt_1"

    private func ledger(_ clock: TestClock) throws -> NotificationLedger {
        try NotificationLedger(inMemory: (), now: clock.now)
    }

    private func claim(
        _ ledger: NotificationLedger,
        owner: String = "extension",
        lease: TimeInterval = 30
    ) throws -> Bool {
        try ledger.claim(key: key, hostID: "host_1", category: "sessionCompleted", sessionID: "ses_a", owner: owner, lease: lease)
    }

    func testFreshClaimSucceedsAndDuplicateClaimIsRejected() throws {
        let clock = TestClock()
        let ledger = try ledger(clock)
        XCTAssertTrue(try claim(ledger))
        XCTAssertFalse(try claim(ledger, owner: "other-lifetime"), "already claimed: no duplicate scheduling")
    }

    func testExpiredLeaseIsReclaimableAfterCrash() throws {
        let clock = TestClock()
        let ledger = try ledger(clock)
        XCTAssertTrue(try claim(ledger, lease: 30))
        clock.advance(31)
        XCTAssertTrue(try claim(ledger, owner: "restarted"), "a crashed claimer's expired lease may be reclaimed")
    }

    func testLiveLeaseIsNotStolen() throws {
        let clock = TestClock()
        let ledger = try ledger(clock)
        XCTAssertTrue(try claim(ledger, lease: 30))
        clock.advance(29)
        XCTAssertFalse(try claim(ledger, owner: "overlapping-lifetime"))
    }

    func testScheduledBlocksReclaim() throws {
        let clock = TestClock()
        let ledger = try ledger(clock)
        XCTAssertTrue(try claim(ledger))
        try ledger.recordScheduled(key: key)
        clock.advance(600)
        XCTAssertFalse(try claim(ledger), "the OS already holds the request")
        XCTAssertEqual(try ledger.state(key: key), .scheduled)
    }

    func testFailedReleasesTheClaimForRetry() throws {
        let clock = TestClock()
        let ledger = try ledger(clock)
        XCTAssertTrue(try claim(ledger))
        try ledger.recordFailed(key: key)
        XCTAssertEqual(try ledger.state(key: key), .failed)
        XCTAssertTrue(try claim(ledger, owner: "retry"), "scheduling failures are retried")
    }

    func testRecordedDeliveryBlocksFurtherClaims() throws {
        let clock = TestClock()
        let ledger = try ledger(clock)
        XCTAssertTrue(try claim(ledger))
        try ledger.recordScheduled(key: key)
        try ledger.recordDelivered(key: key)
        clock.advance(600)
        XCTAssertFalse(try claim(ledger))
        XCTAssertEqual(try ledger.state(key: key), .delivered)
    }

    func testReconcileKeepsPendingRecordsDeliveredOnesAndReleasesExpiredClaims() throws {
        let clock = TestClock()
        let ledger = try ledger(clock)

        let keptKey = "kept"
        let deliveredKey = "delivered"
        let lostKey = "lost"
        for (key, owner) in [(keptKey, "a"), (deliveredKey, "b"), (lostKey, "c")] {
            XCTAssertTrue(try ledger.claim(key: key, hostID: "h", category: "c", sessionID: "s", owner: owner, lease: 30))
        }

        try ledger.reconcile(
            pendingIDs: [keptKey],
            deliveredIDs: [deliveredKey]
        )

        XCTAssertEqual(try ledger.state(key: keptKey), .scheduled, "still pending with the OS: it reached the OS, scheduling is recorded")
        XCTAssertEqual(try ledger.state(key: deliveredKey), .delivered, "OS-delivered is recorded, not retried")
        // The live lease is never released: its owner may be between claim
        // and UN add, and releasing now would let a second claim race a
        // duplicate banner.
        XCTAssertEqual(try ledger.state(key: lostKey), .claimed, "absent from the OS but the lease is live: keep the claim")
        XCTAssertFalse(try ledger.claim(key: lostKey, hostID: "h", category: "c", sessionID: "s", owner: "c2", lease: 30), "a live lease still blocks reclamation")

        // Once the lease expires the owner is presumed gone: the claim that
        // never reached the OS is released for retry.
        clock.advance(31)
        try ledger.reconcile(pendingIDs: [], deliveredIDs: [])
        XCTAssertNil(try ledger.state(key: lostKey), "expired and never reached the OS: released for retry")
        XCTAssertTrue(try ledger.claim(key: lostKey, hostID: "h", category: "c", sessionID: "s", owner: "c2", lease: 30))
    }

    func testUnknownKeyStateIsNil() throws {
        let ledger = try ledger(TestClock())
        XCTAssertNil(try ledger.state(key: "missing"))
        try ledger.recordFailed(key: "missing")
        XCTAssertNil(try ledger.state(key: "missing"))
    }
}
