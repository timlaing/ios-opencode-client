import Foundation

/// Where the app and the local-push extension find their shared store.
///
/// With the App Group entitlement in place (added together with the
/// app-push entitlement per docs/design-review.md release gates), both
/// processes resolve the same group container. Without it, callers that
/// disallow the app-local fallback (the extension) get a thrown error and
/// fail closed instead of silently opening a second, diverging private
/// store. The app allows the fallback so it works before the entitlement
/// exists — its path is `Application Support/OpenCodeRemote`, the same
/// directory the app has always used.
///
/// NOTE for the entitlement slice: once the group container becomes
/// available the resolved directory CHANGES for the app; existing
/// app-local databases must be migrated to the group container then.
public enum SharedStoreLocation {
    /// Entitlement-gated group identifier; resolves only when the signed
    /// entitlement exists.
    public static let defaultAppGroupIdentifier = "group.uk.co.laingcorp.opencode-client.OpenCodeRemote"

    public enum LocationError: Error, Equatable {
        /// The App Group container is unavailable and the caller disallows
        /// the private fallback (extension-side fail-closed behaviour).
        case appGroupUnavailable
    }

    /// - Parameter allowAppLocalFallback: when `true` (the app), an
    ///   unavailable group container falls back to the app's private
    ///   Application Support directory. When `false` (the extension), the
    ///   absence of the group container throws `appGroupUnavailable`.
    public static func directory(
        appGroupIdentifier: String? = defaultAppGroupIdentifier,
        allowAppLocalFallback: Bool = true
    ) throws -> URL {
        #if os(iOS) || os(tvOS) || os(watchOS)
        if let appGroupIdentifier,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return container.appendingPathComponent("OpenCodeRemote", isDirectory: true)
        }
        #endif
        guard allowAppLocalFallback else { throw LocationError.appGroupUnavailable }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("OpenCodeRemote", isDirectory: true)
    }
}
