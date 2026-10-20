import Foundation
import GRDB

/// An offline composer draft (S08). Attachment *bytes* are excluded — refs only
/// (docs/implementation-defaults.md §I1/I7).
public struct Draft: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "drafts"

    public var id: String
    public var hostUUID: String
    public var directory: String?
    public var sessionID: String?
    public var text: String
    public var updatedAt: Date
    public var attachmentRefs: Data?

    public init(
        id: String,
        hostUUID: String,
        directory: String? = nil,
        sessionID: String? = nil,
        text: String,
        updatedAt: Date = Date(),
        attachmentRefs: Data? = nil
    ) {
        self.id = id
        self.hostUUID = hostUUID
        self.directory = directory
        self.sessionID = sessionID
        self.text = text
        self.updatedAt = updatedAt
        self.attachmentRefs = attachmentRefs
    }
}

/// GRDB-backed draft persistence. App-private storage for now; the App Group
/// location for the shared push-extension store is wired once entitlements
/// exist (docs/implementation-defaults.md §I1).
public struct DraftStore: Sendable {
    private let db: DatabaseQueue

    public init(writingAt directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        db = try DatabaseQueue(path: directoryURL.appendingPathComponent("drafts.sqlite").path)
        try Self.migrate(db)
    }

    public init(inMemory: Void = ()) throws {
        db = try DatabaseQueue()
        try Self.migrate(db)
    }

    private static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: Draft.databaseTableName) { t in
                t.column("id", .text).primaryKey()
                t.column("hostUUID", .text).notNull()
                t.column("directory", .text)
                t.column("sessionID", .text)
                t.column("text", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("attachmentRefs", .blob)
            }
            try db.create(
                index: "idx_drafts_scope",
                on: Draft.databaseTableName,
                columns: ["hostUUID", "directory", "sessionID"]
            )
            try db.create(index: "idx_drafts_updated", on: Draft.databaseTableName, columns: ["updatedAt"])
        }
        try migrator.migrate(db)
    }

    public func upsert(_ draft: Draft) throws {
        var record = draft
        try db.write { try record.save($0) }
    }

    public func draft(id: String) throws -> Draft? {
        try db.read { try Draft.fetchOne($0, key: id) }
    }

    /// Most recently updated drafts for a composer scope.
    public func drafts(hostUUID: String, directory: String?, sessionID: String?) throws -> [Draft] {
        try db.read { db in
            try Draft
                .filter(
                    Column("hostUUID") == hostUUID
                        && Column("directory") == directory
                        && Column("sessionID") == sessionID
                )
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    /// Every draft, most recently updated first (S19: switching the
    /// retention must see ALL existing drafts to confirm that the new
    /// policy would remove none — docs/implementation-defaults.md
    /// "Drafts").
    public func allDrafts() throws -> [Draft] {
        try db.read { try Draft.order(Column("updatedAt").desc).fetchAll($0) }
    }

    public func deleteDraft(id: String) throws {
        try db.write { _ = try Draft.deleteOne($0, key: id) }
    }

    public func deleteDrafts(olderThan cutoff: Date) throws {
        try db.write { db in
            _ = try Draft.filter(Column("updatedAt") < cutoff).deleteAll(db)
        }
    }
}
