import Foundation

/// One redacted diagnostic event (S20: view/export/clear and the
/// last-error display — docs/navigation-screens.md S20,
/// docs/implementation-defaults.md "Diagnostics": kept 7 days, capped
/// at 5 MiB, never uploaded automatically).
struct DiagnosticsEntry: Codable, Equatable, Sendable, Identifiable {
    enum Category: String, Codable, Sendable {
        case notifications, push, storage
    }

    enum Severity: String, Codable, Sendable {
        case info, error
    }

    var id: UUID
    var date: Date
    var category: Category
    var severity: Severity
    /// Redacted BEFORE storage — an export can only ever leak what a
    /// single line holds (SSIDs/addresses never enter the log raw).
    var message: String
}

/// App-private diagnostic log over one NDJSON file. A plain value:
/// every operation is a bounded file read/write, so the same store
/// works from views, libraries and tests (tests inject a temp
/// directory, a clock, and a small ceiling).
struct DiagnosticsLogStore: Sendable {
    /// docs/implementation-defaults.md "Diagnostics": 7 days.
    static let retention: TimeInterval = 7 * 86_400
    /// docs/implementation-defaults.md "Diagnostics": 5 MiB.
    static let byteCeiling = 5 * 1024 * 1024

    let directory: URL
    /// The size cap in bytes; the static above is the docs default,
    /// this instance slot exists so tests can use a small ceiling.
    let ceiling: Int
    private let now: @Sendable () -> Date

    init(
        directory: URL = DiagnosticsLogStore.defaultDirectory,
        ceiling: Int = DiagnosticsLogStore.byteCeiling,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.ceiling = ceiling
        self.now = now
    }

    /// Same Application Support fallback shape as the drafts store
    /// (the App Group entitlement is still pending, so nothing here
    /// is shared with the extension).
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OpenCodeRemote", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("diagnostics.ndjson")
    }

    /// Appends one entry and prunes. Pruning re-reads and rewrites
    /// the file, which is fine at this cadence: entries are rare
    /// (permission outcomes, banner posts, storage wipes) and the
    /// file is hard-capped at the ceiling.
    func record(
        _ category: DiagnosticsEntry.Category,
        severity: DiagnosticsEntry.Severity = .info,
        _ message: String
    ) {
        let entry = DiagnosticsEntry(
            id: UUID(),
            date: now(),
            category: category,
            severity: severity,
            message: Self.redact(message)
        )
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
        prune()
    }

    /// Oldest-first. A corrupt line is skipped, never fatal —
    /// diagnostics must not be able to break the screen that reads
    /// them.
    func entries() -> [DiagnosticsEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(DiagnosticsEntry.self, from: Data(line))
        }
    }

    /// The most recent error-level entry (S20 "last-error display"),
    /// or nil when nothing has failed.
    func latestError() -> DiagnosticsEntry? {
        entries().last { $0.severity == .error }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// A copy for the share sheet — the live log file is never handed
    /// out, so a later append cannot race the share.
    func exportURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-diagnostics-\(Int(now().timeIntervalSince1970)).ndjson")
        try Self.encode(entries()).write(to: url)
        return url
    }

    /// Defensive scrub for URL- and IP-shaped content. SSIDs are
    /// arbitrary user strings no heuristic can find — so callers
    /// record COUNTS, never SSID values (pinned by the caller tests).
    static func redact(_ message: String) -> String {
        message
            .replacingOccurrences(
                of: #"\b(?:https?|wss?)://\S+"#,
                with: "<redacted-url>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#,
                with: "<redacted-address>",
                options: .regularExpression
            )
    }

    // MARK: - Internals

    /// Retention first, then the size ceiling drops the OLDEST
    /// entries — recent diagnostics are the ones worth keeping.
    private func prune() {
        let cutoff = now().timeIntervalSince1970 - Self.retention
        var all = entries().filter { $0.date.timeIntervalSince1970 >= cutoff }
        var payload = (try? Self.encode(all)) ?? Data()
        while payload.count > ceiling, !all.isEmpty {
            all.removeFirst()
            payload = (try? Self.encode(all)) ?? Data()
        }
        try? payload.write(to: fileURL, options: .atomic)
    }

    private static func encode(_ entries: [DiagnosticsEntry]) throws -> Data {
        let encoder = JSONEncoder()
        let lines = try entries.map { try encoder.encode($0) }
        return lines.reduce(into: Data()) { data, line in
            data.append(line)
            data.append(0x0A)
        }
    }
}
