import Foundation

/// Where the app and the local-push extension find their shared store.
///
/// With the App Group entitlement in place (added together with the
/// app-push entitlement per docs/design-review.md release gates), both
/// processes resolve the same group container. Without it,
/// `containerURL` returns nil and the caller falls back to the app-local
/// Application Support directory, which the sandboxed extension cannot
/// read — the extension then fails closed instead of pairing a second
/// private store. Never silently diverge the two processes' stores.
public enum SharedStoreLocation {
    /// Entitlement-gated group identifier; resolves only when the signed
    /// entitlement exists. Placeholder value is documented in project.yml.
    public static let defaultAppGroupIdentifier = "group.uk.co.laingcorp.opencode-client.OpenCodeRemote"

    public static func directory(appGroupIdentifier: String? = defaultAppGroupIdentifier) throws -> URL {
        #if os(iOS) || os(tvOS) || os(watchOS)
        if let appGroupIdentifier,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return container.appendingPathComponent("OpenCodeRemote", isDirectory: true)
        }
        #endif
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("OpenCodeRemote", isDirectory: true)
    }
}
