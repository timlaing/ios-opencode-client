import XCTest
@testable import OpenCodeRemote

/// W17 S20: the diagnostic log is bounded (7 days / 5 MiB per
/// docs/implementation-defaults.md "Diagnostics"), redacts URL/IP
/// shaped content before storage, tolerates corrupt lines, and its
/// export is a copy — the documented defaults stay pinned.
final class DiagnosticsLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    private func store(
        ceiling: Int = DiagnosticsLogStore.byteCeiling,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> DiagnosticsLogStore {
        DiagnosticsLogStore(directory: directory, ceiling: ceiling, now: now)
    }

    /// Mutable clock, safe to hand to the engine's `@Sendable` `now`
    /// closure — a captured `var` is a warning today and a hard
    /// error under stricter concurrency (review W17 r1).
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    func testDocumentedDefaultsArePinned() {
        XCTAssertEqual(DiagnosticsLogStore.retention, 7 * 86_400, "kept 7 days")
        XCTAssertEqual(DiagnosticsLogStore.byteCeiling, 5 * 1024 * 1024, "capped at 5 MiB")
    }

    func testMissingFileReadsAsAnEmptyLog() {
        XCTAssertTrue(store().entries().isEmpty)
        XCTAssertNil(store().latestError())
    }

    func testRecordRoundTripsCategorySeverityAndMessage() {
        let log = store()
        log.record(.notifications, "permission granted")
        log.record(.storage, severity: .error, "clear failed")

        let entries = log.entries()
        XCTAssertEqual(entries.map(\.message), ["permission granted", "clear failed"])
        XCTAssertEqual(entries.map(\.category), [.notifications, .storage])
        XCTAssertEqual(entries.map(\.severity), [.info, .error])
        XCTAssertEqual(log.latestError()?.message, "clear failed", "last-error display reads the newest error entry")
    }

    func testRedactionScrubsURLsAndAddressesBeforeStorage() throws {
        let log = store()
        log.record(.push, "reconnect to https://host.internal:4096/api/event failed at 192.168.1.24")

        let stored = try XCTUnwrap(log.entries().first)
        XCTAssertFalse(stored.message.contains("host.internal"), "URLs never reach storage")
        XCTAssertFalse(stored.message.contains("192.168.1.24"), "addresses never reach storage")
        XCTAssertTrue(stored.message.contains("<redacted-url>"))
        XCTAssertTrue(stored.message.contains("<redacted-address>"))
    }

    func testRetentionDropsEntriesOlderThanSevenDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = Clock(start)
        let log = store(now: { clock.now })

        log.record(.storage, "old event")
        clock.now = start.addingTimeInterval(8 * 86_400)
        log.record(.storage, "fresh event")

        XCTAssertEqual(log.entries().map(\.message), ["fresh event"], "the 7-day window applies on write")
    }

    func testCeilingDropsOldestEntriesFirst() {
        let log = store(ceiling: 600)
        for index in 0..<10 {
            log.record(.storage, "event \(index) with some padding text to occupy bytes")
        }

        let messages = log.entries().map(\.message)
        XCTAssertLessThan(messages.count, 10, "the ceiling trimmed the log")
        XCTAssertFalse(messages.contains("event 0 with some padding text to occupy bytes"), "oldest entries go first")
        XCTAssertTrue(messages.last?.hasSuffix("event 9 with some padding text to occupy bytes") ?? false, "newest entry survives")
    }

    func testCorruptLinesAreSkippedNotFatal() throws {
        let log = store()
        log.record(.storage, "good entry")
        let file = directory.appendingPathComponent("diagnostics.ndjson")
        var data = try Data(contentsOf: file)
        data.append("not json at all\n".data(using: .utf8)!)
        try data.write(to: file)

        XCTAssertEqual(log.entries().map(\.message), ["good entry"], "one bad line never breaks the log")
    }

    func testClearRemovesEverythingIncludingTheLastError() {
        let log = store()
        log.record(.storage, severity: .error, "boom")
        log.clear()

        XCTAssertTrue(log.entries().isEmpty)
        XCTAssertNil(log.latestError())
    }

    func testExportWritesACopyAndTheLiveLogStaysIntact() throws {
        let log = store()
        log.record(.notifications, "banner posted")

        let url = try log.exportURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let exported = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(exported.contains("banner posted"))
        log.record(.notifications, "a later append")
        XCTAssertFalse(
            try String(contentsOf: url, encoding: .utf8).contains("a later append"),
            "the export is a snapshot — a later append cannot race the share"
        )
        XCTAssertEqual(log.entries().count, 2, "the live log is untouched by exporting")
    }
}
