import GRDB

/// Database configuration for the stores the app AND the LocalPushProvider
/// extension open over one App Group file (HostStore's `hosts.sqlite`,
/// NotificationLedger's `notifications.sqlite`).
///
/// GRDB's default `busyMode` is `.immediateError`: a read or write while the
/// other process holds the SQLite lock throws SQLITE_BUSY at once — and both
/// callers swallow that error (`(try? hostStore.hosts()) ?? []` starts no
/// observers until the next timer event; `schedule`'s
/// `(try? ledger.claim(...)) ?? false` drops the notification outright).
/// Waiting briefly for the lock instead keeps routine contention invisible
/// to users. In-memory stores (every test) and the app-private DraftStore
/// are single-process and keep GRDB's defaults.
enum SharedDatabase {
    static var configuration: Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        return configuration
    }
}
