import Foundation

/// The app-local directory the store lives in (the host registry's
/// `hosts.sqlite`). Single-process: nothing else opens this file, so it
/// stays where it always has — the app's own Application Support
/// directory. No container migration is owed: the App Group path the
/// removed local-push extension needed was never entitlement-backed in
/// any build (no committed config ever carried `application-groups`),
/// so it never resolved and no group-side database was ever created —
/// verified against git history and the simulator containers
/// (review: removal r3).
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
