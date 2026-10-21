import GRDB

/// Database configuration for the file-backed store (HostStore's
/// `hosts.sqlite`).
///
/// GRDB's default `busyMode` is `.immediateError`: a read or write while
/// the lock is held throws SQLITE_BUSY at once, and callers swallow that
/// error (`(try? hostStore.hosts()) ?? []` starts no observers until the
/// next refresh). Waiting briefly for the lock instead keeps routine
/// contention invisible to users. In-memory stores (every test) and the
/// app-private DraftStore keep GRDB's defaults.
enum SharedDatabase {
    static var configuration: Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        return configuration
    }
}
