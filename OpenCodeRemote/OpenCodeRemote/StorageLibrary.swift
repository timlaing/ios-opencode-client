import Foundation
import OpenCodeStorage

/// Local sizes and destructive local cleanup (S19 "actual local
/// sizes", Clear Cache, Clear Local Data — docs/navigation-screens.md).
/// Plain values over INJECTED directories so every test runs in temp
/// space; the app uses the standard Caches directory and the
/// app-private drafts location — the same Application Support fallback
/// shape as `HostLibrary.databaseDirectory`, since the App Group
/// entitlement is still pending (docs/local-push-implementation.md).
struct StorageLibrary: Sendable {
    let cacheDirectory: URL
    let draftsDirectory: URL

    init(
        cacheDirectory: URL = StorageLibrary.defaultCacheDirectory,
        draftsDirectory: URL = StorageLibrary.defaultDraftsDirectory
    ) {
        self.cacheDirectory = cacheDirectory
        self.draftsDirectory = draftsDirectory
    }

    static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var defaultDraftsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("OpenCodeRemote", isDirectory: true)
            .appendingPathComponent("drafts", isDirectory: true)
    }

    // MARK: - Refetchable cache

    /// Bytes currently occupying the refetchable cache. S19 shows the
    /// REAL number (walked from disk), never an estimate — a fresh
    /// install honestly reads zero (implementation-defaults.md
    /// "Cache size").
    func cacheUsageBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Clear Cache removes refetchable CONTENTS only: the directory
    /// itself stays, and drafts, credentials, and pending uploads live
    /// elsewhere by design — the budget must never silently delete
    /// them (implementation-defaults.md "Cache size"). A missing
    /// directory is already the desired state.
    func clearCache() throws {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for item in contents {
            try fm.removeItem(at: item)
        }
    }

    // MARK: - Drafts (Clear Local Data)

    /// The drafts half of Clear Local Data: opens the app-private
    /// store and removes every draft. A missing store is an empty
    /// drafts table — already the desired state. Draft rows hold text
    /// and attachment REFS only (no bytes past commit, I1), so this is
    /// the whole surface.
    func clearAllDrafts() throws {
        try DraftStore(writingAt: draftsDirectory)
            .deleteDrafts(olderThan: .distantFuture)
    }

    /// Every persisted draft's last-edit date (S19: a retention
    /// switch confirms against the drafts that exist NOW). An
    /// unreadable or missing store reads as no drafts.
    func existingDraftLastEdits() throws -> [Date] {
        try DraftStore(writingAt: draftsDirectory).allDrafts().map(\.updatedAt)
    }
}
