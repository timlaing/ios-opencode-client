import Foundation
import GRDB

/// Transactional claim/delivery ledger for local notifications
/// (docs/local-push-implementation.md §"Notification classification and
/// scheduling"). Shared between the foreground app and the push extension
/// through the shared store directory, it deduplicates banners across
/// overlapping provider lifetimes (Wi-Fi transitions, restarts).
///
/// Scheduling is claimed with a bounded owner lease before touching
/// UNUserNotificationCenter; the scheduler result is then recorded. Claimed,
/// scheduled, and delivered are distinct: counts here are never delivery
/// acknowledgments. This reduces duplicates but cannot guarantee
/// exactly-once display across crashes, stream gaps and OS policy.
public struct NotificationLedger: Sendable {
    public enum State: String, Sendable {
        case claimed
        case scheduled
        case failed
        case delivered
    }

    private struct LedgerRecord: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "notification_ledger"

        var ledgerKey: String
        var hostID: String
        var category: String
        var sessionID: String
        var state: String
        var owner: String
        var leaseUntil: Date?
        var updatedAt: Date
    }

    private let db: DatabaseQueue
    private let now: @Sendable () -> Date

    public init(writingAt directoryURL: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        db = try DatabaseQueue(
            path: directoryURL.appendingPathComponent("notifications.sqlite").path,
            configuration: SharedDatabase.configuration
        )
        self.now = now
        try Self.migrate(db)
    }

    public init(inMemory: Void = (), now: @escaping @Sendable () -> Date = { Date() }) throws {
        db = try DatabaseQueue()
        self.now = now
        try Self.migrate(db)
    }

    private static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "notification_ledger") { t in
                t.column("ledgerKey", .text).primaryKey()
                t.column("hostID", .text).notNull()
                t.column("category", .text).notNull()
                t.column("sessionID", .text).notNull()
                t.column("state", .text).notNull()
                t.column("owner", .text).notNull()
                t.column("leaseUntil", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }
        }
        try migrator.migrate(db)
    }

    /// Tries to claim scheduling rights for one canonical transition.
    ///
    /// Returns `false` when the transition is already claimed by a live
    /// owner, already scheduled, or already delivered — the caller must not
    /// schedule a duplicate. A claimed row whose lease expired (crashed
    /// owner) may be reclaimed; failed rows may be retried.
    public func claim(
        key: String,
        hostID: String,
        category: String,
        sessionID: String,
        owner: String,
        lease: TimeInterval
    ) throws -> Bool {
        let timestamp = now()
        return try db.write { db in
            if var existing = try LedgerRecord.fetchOne(db, key: key) {
                switch State(rawValue: existing.state) {
                case .scheduled, .delivered:
                    return false
                case .claimed:
                    if let leaseUntil = existing.leaseUntil, leaseUntil > timestamp {
                        return false // another live owner
                    }
                case .failed, .none:
                    break // retry allowed
                }
                existing.state = State.claimed.rawValue
                existing.owner = owner
                existing.leaseUntil = timestamp.addingTimeInterval(lease)
                existing.updatedAt = timestamp
                try existing.update(db)
                return true
            }
            var inserted = LedgerRecord(
                ledgerKey: key,
                hostID: hostID,
                category: category,
                sessionID: sessionID,
                state: State.claimed.rawValue,
                owner: owner,
                leaseUntil: timestamp.addingTimeInterval(lease),
                updatedAt: timestamp
            )
            try inserted.insert(db)
            return true
        }
    }

    /// Records that the OS accepted the notification request.
    public func recordScheduled(key: String) throws {
        try mutate(key) { record in
            record.state = State.scheduled.rawValue
            record.leaseUntil = nil
        }
    }

    /// Records a scheduling failure and releases the claim, so a later
    /// event or reconciliation retry may attempt it again.
    public func recordFailed(key: String) throws {
        try mutate(key) { record in
            record.state = State.failed.rawValue
            record.leaseUntil = nil
        }
    }

    /// Records OS-observed delivery for diagnostics.
    public func recordDelivered(key: String) throws {
        try mutate(key) { record in
            record.state = State.delivered.rawValue
            record.leaseUntil = nil
        }
    }

    /// Crash/restart reconciliation against the OS. A claimed key the OS
    /// reports as delivered is recorded; one still pending with the OS
    /// becomes `.scheduled` (it reached the OS after all); anything else
    /// never reached the OS and is released — but ONLY once its lease has
    /// expired. Releasing a live lease would drop a claim whose owner may
    /// still be scheduling it, opening the door to a duplicate banner
    /// (docs: "on crash/restart reconcile pending/delivered notification
    /// identifiers before retrying a claimed item").
    public func reconcile(pendingIDs: Set<String>, deliveredIDs: Set<String>) throws {
        let timestamp = now()
        try db.write { db in
            let claimed = try LedgerRecord
                .filter(Column("state") == State.claimed.rawValue)
                .fetchAll(db)
            for var record in claimed {
                if deliveredIDs.contains(record.ledgerKey) {
                    record.state = State.delivered.rawValue
                    record.leaseUntil = nil
                    record.updatedAt = timestamp
                    try record.update(db)
                } else if pendingIDs.contains(record.ledgerKey) {
                    // It reached the OS: scheduling is done, so the claim
                    // settles into `.scheduled` rather than staying held.
                    record.state = State.scheduled.rawValue
                    record.leaseUntil = nil
                    record.updatedAt = timestamp
                    try record.update(db)
                } else if record.leaseUntil.map({ $0 <= timestamp }) ?? true {
                    // Absent from the OS AND the lease is over (or was
                    // never set): safe to release for retry.
                    try record.delete(db)
                }
                // Absent from the OS but the lease is still live: the owner
                // may be mid-schedule — keep the claim.
            }
        }
    }

    /// Current state for a key, for diagnostics.
    public func state(key: String) throws -> State? {
        try db.read { db in
            try LedgerRecord.fetchOne(db, key: key).flatMap { State(rawValue: $0.state) }
        }
    }

    private func mutate(_ key: String, _ change: (inout LedgerRecord) -> Void) throws {
        let timestamp = now()
        try db.write { db in
            guard var record = try LedgerRecord.fetchOne(db, key: key) else { return }
            change(&record)
            record.updatedAt = timestamp
            try record.update(db)
        }
    }
}
