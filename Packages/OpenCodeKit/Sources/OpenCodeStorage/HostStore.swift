import Foundation
import GRDB
import OpenCodeDomain

/// GRDB-backed host registry (S02). Credentials are never stored here — the
/// Keychain only (docs/implementation-defaults.md privacy rules).
public struct HostStore: Sendable {
    private struct HostRecord: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "hosts"

        var id: String
        var displayName: String
        var address: String
        var createdAt: Date
        var lastVersion: String?
    }

    private let db: DatabaseQueue

    public init(writingAt directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        db = try DatabaseQueue(
            path: directoryURL.appendingPathComponent("hosts.sqlite").path,
            configuration: SharedDatabase.configuration
        )
        try Self.migrate(db)
    }

    public init(inMemory: Void = ()) throws {
        db = try DatabaseQueue()
        try Self.migrate(db)
    }

    private static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "hosts") { t in
                t.column("id", .text).primaryKey()
                t.column("displayName", .text).notNull()
                t.column("address", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastVersion", .text)
            }
        }
        try migrator.migrate(db)
    }

    public func upsert(_ host: OpenCodeDomain.Host) throws {
        try db.write { db in
            try db.execute(
                sql: """
                INSERT INTO hosts (id, displayName, address, createdAt, lastVersion)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    displayName = excluded.displayName,
                    address = excluded.address,
                    lastVersion = excluded.lastVersion
                """,
                arguments: [
                    host.id.rawValue,
                    host.displayName,
                    host.address.absoluteString,
                    host.createdAt,
                    host.lastVersion,
                ]
            )
        }
    }

    /// All hosts in pairing order. Rows with an unparseable address (corrupt
    /// storage) are skipped rather than crashing the list.
    public func hosts() throws -> [OpenCodeDomain.Host] {
        try db.read { db in
            try HostRecord
                .order(Column("createdAt"))
                .fetchAll(db)
                .compactMap { record in
                    guard let address = URL(string: record.address) else { return nil }
                    return OpenCodeDomain.Host(
                        id: HostID(rawValue: record.id),
                        displayName: record.displayName,
                        address: address,
                        createdAt: record.createdAt,
                        lastVersion: record.lastVersion
                    )
                }
        }
    }

    public func host(id: HostID) throws -> OpenCodeDomain.Host? {
        try db.read { db in
            guard let record = try HostRecord.fetchOne(db, key: id.rawValue),
                  let address = URL(string: record.address) else { return nil }
            return OpenCodeDomain.Host(
                id: HostID(rawValue: record.id),
                displayName: record.displayName,
                address: address,
                createdAt: record.createdAt,
                lastVersion: record.lastVersion
            )
        }
    }

    public func deleteHost(id: HostID) throws {
        try db.write { _ = try HostRecord.deleteOne($0, key: id.rawValue) }
    }
}
