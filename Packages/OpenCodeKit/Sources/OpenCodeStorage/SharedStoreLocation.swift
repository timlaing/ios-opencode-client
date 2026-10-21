import Foundation

/// The app-local directory the shared store lives in (the host registry's
/// `hosts.sqlite`). Single-process: nothing else opens this file, so it
/// stays where it always has — the app's own Application Support
/// directory — with no container migration.
public enum SharedStoreLocation {
    /// `Application Support/OpenCodeRemote`; throws only when the base
    /// directory cannot be resolved.
    public static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("OpenCodeRemote", isDirectory: true)
    }
}
