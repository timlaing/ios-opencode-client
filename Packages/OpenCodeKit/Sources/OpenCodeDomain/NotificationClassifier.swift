import Foundation
import OpenCodeTransport

/// Categories the user may enable for local-push banners
/// (docs/local-push-implementation.md §"Notification classification").
public enum NotificationCategory: String, Codable, CaseIterable, Sendable {
    case sessionCompleted
    case sessionFailed
    case permissionRequested
    case formRequested
}

/// How much event-derived text a banner may carry
/// (docs/local-push-implementation.md privacy rules: never transcript text,
/// tool arguments, or file content).
public enum NotificationContentLevel: String, Codable, CaseIterable, Sendable {
    /// Category copy only; no event-derived message text at all.
    case minimal
    /// Minimal plus a short server-provided failure summary when present.
    case summaries
}

/// The local-push notification policy for one host. Only app-started or
/// explicitly followed sessions notify; everything else on the host-wide
/// stream is discarded.
public struct NotificationPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var followedSessions: Set<String>
    public var categories: Set<NotificationCategory>
    public var contentLevel: NotificationContentLevel

    public init(
        enabled: Bool = true,
        followedSessions: Set<String> = [],
        categories: Set<NotificationCategory> = Set(NotificationCategory.allCases),
        contentLevel: NotificationContentLevel = .minimal
    ) {
        self.enabled = enabled
        self.followedSessions = followedSessions
        self.categories = categories
        self.contentLevel = contentLevel
    }
}

/// One deduplicated notification decision for a canonical transition. Carries
/// only routing identifiers and policy-approved copy — no transcript text.
public struct NotificationDraft: Equatable, Sendable {
    public var category: NotificationCategory
    public var sessionID: String
    /// Permission requestID or form ID when the category routes to its owner.
    public var ownerID: String?
    /// Stable identity across app/extension and restarts: host, session,
    /// interaction and canonical transition (the ledger key, also used as
    /// the UNNotificationRequest identifier so the OS dedupes repeats).
    public var ledgerKey: String
    public var title: String
    public var body: String

    public init(
        category: NotificationCategory,
        sessionID: String,
        ownerID: String?,
        ledgerKey: String,
        title: String,
        body: String
    ) {
        self.category = category
        self.sessionID = sessionID
        self.ownerID = ownerID
        self.ledgerKey = ledgerKey
        self.title = title
        self.body = body
    }
}

/// Maps the host-wide SSE event stream to notification drafts
/// (docs/api-contract.md W16, docs/local-push-implementation.md
/// §"OpenCode-specific stream adapter").
///
/// The stream is host-wide and volatile: irrelevant payloads are discarded
/// here without being retained. Canonical alert-driving transitions are
/// execution succeeded/failed plus new permission/form requests; interrupts
/// are user-initiated and never notify. Bootstrap flood protection is the
/// caller's job (the ledger dedupes by `ledgerKey`, and history before the
/// current generation is not replayed by the stream).
public struct EventClassifier: Sendable {
    public var hostID: String
    public var policy: NotificationPolicy

    public init(hostID: String, policy: NotificationPolicy) {
        self.hostID = hostID
        self.policy = policy
    }

    public func classify(_ event: OpenCodeEvent) -> NotificationDraft? {
        guard policy.enabled,
              let type = event.type,
              let sessionID = event.data?["sessionID"]?.stringValue,
              !sessionID.isEmpty,
              policy.followedSessions.contains(sessionID)
        else { return nil }

        // No canonical transition identity means no stable ledger key, and
        // therefore no banner (repeats could not be deduplicated).
        guard let transitionID = event.id, !transitionID.isEmpty else { return nil }

        let category: NotificationCategory
        let ownerID: String?
        let title: String
        let body: String
        switch type {
        case "session.execution.succeeded":
            category = .sessionCompleted
            ownerID = nil
            title = "Session completed"
            body = "The session finished successfully."
        case "session.execution.failed":
            category = .sessionFailed
            ownerID = nil
            title = "Session failed"
            if policy.contentLevel == .summaries, let summary = failureSummary(event.data) {
                body = summary
            } else {
                body = "The session stopped with an error."
            }
        case "permission.asked":
            category = .permissionRequested
            ownerID = event.data?["requestID"]?.stringValue
            title = "Permission needed"
            body = "A tool permission request is waiting for your reply."
        case "form.created":
            category = .formRequested
            ownerID = event.data?["id"]?.stringValue
            title = "Question waiting"
            body = "A question needs your answer."
        default:
            // Deltas, tool traffic, status, inbox, config: not alert material.
            return nil
        }

        guard policy.categories.contains(category) else { return nil }

        return NotificationDraft(
            category: category,
            sessionID: sessionID,
            ownerID: ownerID,
            ledgerKey: Self.ledgerKey(
                hostID: hostID,
                sessionID: sessionID,
                ownerID: ownerID,
                transitionID: transitionID
            ),
            title: title,
            body: body
        )
    }

    /// Stable ledger/notification identity for one canonical transition.
    public static func ledgerKey(hostID: String, sessionID: String, ownerID: String?, transitionID: String) -> String {
        "host:\(hostID)|session:\(sessionID)|owner:\(ownerID ?? "-")|transition:\(transitionID)"
    }

    /// Short failure reason at the summaries level, tolerating both string
    /// and object error shapes; anything else falls back to generic copy.
    private func failureSummary(_ data: JSONValue?) -> String? {
        guard let error = data?["error"] else { return nil }
        switch error {
        case .string(let text):
            return text.isEmpty ? nil : text
        default:
            if let text = error["message"]?.stringValue, !text.isEmpty { return text }
            if let text = error["data"]?["message"]?.stringValue, !text.isEmpty { return text }
            return nil
        }
    }
}
