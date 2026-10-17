import Foundation
import NetworkExtension
import os

/// Local Push Connectivity provider for OpenCode hosts.
///
/// Deliberately built without the `app-push-provider` entitlement hook: the
/// entitlement must be requested from Apple and added in Xcode signing
/// capabilities before this extension can be activated on a device
/// (docs/design-review.md release gates, docs/local-push-implementation.md §1).
/// The host-event observers, shared GRDB store, and notification classifier
/// are wired in follow-up slices on top of this lifecycle.
final class OpenCodePushProvider: NEAppPushProvider {
    private let logger = Logger(
        subsystem: "uk.co.laingcorp.opencode-client.LocalPushProvider",
        category: "OpenCodePushProvider"
    )

    private var generation = 0

    override func start(completionHandler: @escaping (Error?) -> Void) {
        generation += 1
        logger.info("start (generation \(self.generation))")
        // Host observers start here once the shared store and credentials are
        // wired (follow-up slice). Completion without error keeps the system
        // connection alive for configuration changes.
        completionHandler(nil)
    }

    override func stop(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("stop reason \(String(describing: reason))")
        completionHandler()
    }

    override func handleTimerEvent() {
        // Observers reconcile on timer: healthy hosts keep their single stream;
        // stopped/cancelled hosts back off (docs/local-push-implementation.md §5–6).
    }
}
