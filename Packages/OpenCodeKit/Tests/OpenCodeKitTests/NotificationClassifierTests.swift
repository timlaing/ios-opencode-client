import XCTest
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W16 classification tests (docs/local-push-implementation.md §"Notification
/// classification and scheduling"): only followed sessions notify, in the
/// selected categories, at the selected content-privacy level; everything
/// else on the host-wide stream is discarded without retention.
final class NotificationClassifierTests: XCTestCase {
    private func event(
        type: String,
        id: String? = "evt_1",
        sessionID: String? = "ses_a",
        extra: [String: JSONValue] = [:]
    ) -> OpenCodeEvent {
        var data: [String: JSONValue] = [:]
        if let sessionID { data["sessionID"] = .string(sessionID) }
        for (key, value) in extra { data[key] = value }
        return OpenCodeEvent(id: id, type: type, data: .object(data))
    }

    private func classifier(
        followed: Set<String> = ["ses_a"],
        enabled: Bool = true,
        categories: Set<NotificationCategory> = Set(NotificationCategory.allCases),
        level: NotificationContentLevel = .minimal
    ) -> EventClassifier {
        EventClassifier(
            hostID: "host_1",
            policy: NotificationPolicy(
                enabled: enabled,
                followedSessions: followed,
                categories: categories,
                contentLevel: level
            )
        )
    }

    func testSucceededExecutionNotifiesFollowedSessionWithStableIdentity() {
        let draft = classifier().classify(event(type: "session.execution.succeeded"))
        XCTAssertEqual(draft?.category, .sessionCompleted)
        XCTAssertEqual(draft?.sessionID, "ses_a")
        XCTAssertNil(draft?.ownerID)
        XCTAssertEqual(
            draft?.ledgerKey,
            "host:host_1|session:ses_a|owner:-|transition:evt_1"
        )
        XCTAssertNotNil(draft?.title)
        XCTAssertNotNil(draft?.body)
    }

    func testFailedExecutionNotifies() {
        XCTAssertEqual(classifier().classify(event(type: "session.execution.failed"))?.category, .sessionFailed)
    }

    func testInterruptedExecutionDoesNotNotify() {
        // User-initiated stop: they already know; no banner noise.
        XCTAssertNil(classifier().classify(event(type: "session.execution.interrupted")))
    }

    func testUnfollowedSessionIsDiscarded() {
        XCTAssertNil(classifier(followed: []).classify(event(type: "session.execution.succeeded")))
        XCTAssertNil(classifier(followed: ["ses_b"]).classify(event(type: "session.execution.succeeded")))
    }

    func testDisabledPolicyDiscardsEverything() {
        XCTAssertNil(classifier(enabled: false).classify(event(type: "session.execution.succeeded")))
        XCTAssertNil(classifier(enabled: false).classify(event(type: "permission.asked")))
    }

    func testCategoryGating() {
        let onlyPermissions = classifier(categories: [.permissionRequested])
        XCTAssertNil(onlyPermissions.classify(event(type: "session.execution.succeeded")))
        XCTAssertEqual(
            onlyPermissions.classify(event(type: "permission.asked", extra: ["requestID": .string("req_9")]))?.category,
            .permissionRequested
        )
    }

    func testPermissionAndFormRouteToOwnerIdentifiers() {
        let permission = classifier().classify(
            event(type: "permission.asked", extra: ["requestID": .string("req_9")])
        )
        XCTAssertEqual(permission?.category, .permissionRequested)
        XCTAssertEqual(permission?.ownerID, "req_9")
        XCTAssertEqual(
            permission?.ledgerKey,
            "host:host_1|session:ses_a|owner:req_9|transition:evt_1"
        )

        let form = classifier().classify(
            event(type: "form.created", extra: ["id": .string("form_3")])
        )
        XCTAssertEqual(form?.category, .formRequested)
        XCTAssertEqual(form?.ownerID, "form_3")
    }

    func testIrrelevantFamiliesAreDiscardedEarly() {
        for type in [
            "session.text.delta", "session.text.ended", "session.reasoning.delta",
            "session.step.started", "session.step.ended", "session.status",
            "session.inbox.enqueued", "session.tool.success", "config.updated",
            "server.connected", "rpc.demo.future", "session.usage.updated",
        ] {
            XCTAssertNil(classifier().classify(event(type: type)), type)
        }
    }

    func testMissingTransitionIdentityNeverNotifies() {
        // No event id → no stable ledger key → no banner (dedup impossible).
        XCTAssertNil(classifier().classify(event(type: "session.execution.succeeded", id: nil)))
    }

    func testMissingSessionIdentityNeverNotifies() {
        XCTAssertNil(classifier().classify(event(type: "session.execution.succeeded", sessionID: nil)))
    }

    func testFailureSummaryRespectsContentPrivacyLevel() {
        let withMessage: [String: JSONValue] = ["error": .object(["message": .string("boom")])]

        // Minimal: generic copy only, even when the server sent a message.
        let minimal = classifier(level: .minimal).classify(
            event(type: "session.execution.failed", extra: withMessage)
        )
        XCTAssertEqual(minimal?.body, "The session stopped with an error.")
        XCTAssertFalse(minimal?.body.contains("boom") ?? true)

        // Summaries: short server-provided reason is allowed.
        let summaries = classifier(level: .summaries).classify(
            event(type: "session.execution.failed", extra: withMessage)
        )
        XCTAssertEqual(summaries?.body, "boom")

        // String-shaped error tolerated too.
        let stringError = classifier(level: .summaries).classify(
            event(type: "session.execution.failed", extra: ["error": .string("offline")])
        )
        XCTAssertEqual(stringError?.body, "offline")

        // Unrecognized shape falls back to generic copy.
        let objectError = classifier(level: .summaries).classify(
            event(type: "session.execution.failed", extra: ["error": .object(["code": .number(1)])])
        )
        XCTAssertEqual(objectError?.body, "The session stopped with an error.")
    }

    func testLedgerKeyIsStableAcrossClassifierInstances() {
        let a = classifier().classify(event(type: "session.execution.succeeded"))?.ledgerKey
        let b = classifier(followed: ["ses_a", "ses_z"]).classify(
            event(type: "session.execution.succeeded")
        )?.ledgerKey
        XCTAssertEqual(a, b)
    }
}
