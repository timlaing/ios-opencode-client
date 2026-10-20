import Foundation
import OpenCodeDomain

/// App-side local-push facts (docs/local-push-implementation.md
/// §"Status and diagnostics"): the eligibility shape the configuration
/// controller consumes, and the status rows this release can honestly
/// produce. The NEAppPushManager pipeline stays dormant until Apple
/// grants the app-push-provider entitlement — until then every
/// configured host answers `unsupportedEntitlement`, and nothing on
/// any screen is presented as delivering.
@MainActor
enum PushEligibility {
    /// The signed-entitlement truth, changed ONLY when Apple grants
    /// `app-push-provider` (stage 1). The eligibility feed below is
    /// built now so the entitlement slice only has to construct the
    /// controller and reconcile.
    static let entitlementGranted = false

    /// The exact `LocalPushHostEligibility` shape
    /// `LocalPushConfigurationController.reconcile(eligibility:)`
    /// consumes — built from the live per-host settings and
    /// credential facts, sorted by host ID so list reordering is
    /// never mistaken for a change.
    static func hostEligibility(
        hostIDs: [String],
        settings: SettingsLibrary,
        hasCredential: (String) -> Bool
    ) -> [LocalPushHostEligibility] {
        hostIDs.sorted().map { id in
            let host = settings.pushSettings(for: id)
            return LocalPushHostEligibility(
                hostID: id,
                enabled: host.enabled,
                hasCredential: hasCredential(id),
                ssids: host.ssids
            )
        }
    }

    /// Followed sessions across hosts — the manager payload source
    /// (`LocalPushConfigurationController.followedSessions`), keyed
    /// host+session in their storage form.
    static func followedSessions(_ localState: SessionLocalStateStore) -> [String] {
        localState.state.followed.sorted()
    }

    /// One host's honest status, in evidence order: a disabled host
    /// is off regardless of the platform; a host without a credential
    /// needs re-pairing before delivery could work; enabled with no
    /// SSIDs is not configured yet; configured-but-unentitled is the
    /// W17 truth; only a granted entitlement can reach the eligible-
    /// Wi-Fi wait (the app cannot confirm the extension's stream —
    /// that is the extension's own status to publish).
    static func status(
        enabled: Bool,
        hasCredential: Bool,
        ssids: [String],
        entitlementGranted: Bool = PushEligibility.entitlementGranted
    ) -> LocalPushStatus {
        guard enabled else { return .disabled }
        guard hasCredential else { return .missingCredential }
        guard !ssids.isEmpty else { return .notConfigured }
        return entitlementGranted ? .waitingForEligibleWiFi : .unsupportedEntitlement
    }
}

/// The delivery-status rows S17/S02/S20 share. Per-case copy
/// (footnotes) lives in the views, not here.
enum LocalPushStatus: Equatable, Sendable {
    case disabled
    case missingCredential
    case notConfigured
    case unsupportedEntitlement
    case waitingForEligibleWiFi

    var label: String {
        switch self {
        case .disabled: "Off"
        case .missingCredential: "Re-pair Required"
        case .notConfigured: "Not Configured"
        case .unsupportedEntitlement: "Unavailable — Approval Pending"
        case .waitingForEligibleWiFi: "Waiting for Eligible Wi-Fi"
        }
    }
}
