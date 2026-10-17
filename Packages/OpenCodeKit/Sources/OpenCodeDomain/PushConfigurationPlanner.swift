import Foundation

/// Eligibility of one host for local push, evaluated from current local
/// settings (docs/local-push-implementation.md §"App-side manager
/// configuration" step 1).
public struct LocalPushHostEligibility: Codable, Equatable, Sendable {
    public var hostID: String
    public var enabled: Bool
    public var hasCredential: Bool
    /// User-entered eligible SSIDs for this host. Empty means unconfigured.
    public var ssids: [String]

    public init(hostID: String, enabled: Bool, hasCredential: Bool, ssids: [String]) {
        self.hostID = hostID
        self.enabled = enabled
        self.hasCredential = hasCredential
        self.ssids = ssids
    }
}

/// One managed NEAppPushManager configuration, reduced to diffable identity.
/// `hostIDs` is always sorted and deduplicated so list reordering never
/// counts as a change (spec step 1).
public struct ManagedPushConfiguration: Equatable, Sendable {
    public var ssid: String
    public var hostIDs: [String]
    public var revision: Int

    public init(ssid: String, hostIDs: [String], revision: Int) {
        self.ssid = ssid
        self.hostIDs = hostIDs
        self.revision = revision
    }
}

/// The diff between desired and current manager configurations: managers to
/// save and SSIDs whose stale managed configurations to remove (spec steps
/// 4–5; removal, not merely disabling, is the supported stop mechanism).
public struct PushConfigurationPlan: Equatable, Sendable {
    public var upserts: [ManagedPushConfiguration]
    public var removals: [String]

    public init(upserts: [ManagedPushConfiguration] = [], removals: [String] = []) {
        self.upserts = upserts
        self.removals = removals
    }

    public var isEmpty: Bool { upserts.isEmpty && removals.isEmpty }
}

/// Versioned configuration payload carried inside an NEAppPushManager's
/// `providerConfiguration`. Identifiers and revision only — never passwords,
/// tokens, prompts or transcript text (docs/local-push-implementation.md
/// §"App-side manager configuration" step 3). Encoded by the app, decoded by
/// the local-push extension.
public struct PushProviderConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var revision: Int
    public var hostIDs: [String]

    public init(schemaVersion: Int = PushProviderConfiguration.currentSchemaVersion, revision: Int, hostIDs: [String]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.hostIDs = hostIDs
    }
}

/// Pure desired-state computation for NEAppPushManager preferences. The
/// NetworkExtension work itself stays behind the app-side adapter; this
/// planner is the tested policy half.
public enum PushConfigurationPlanner {
    /// SSID → sorted/deduplicated host IDs for every eligible host.
    /// Ineligible entries (disabled, missing credential, no usable SSID)
    /// never appear — an ineligible host must not keep a manager alive.
    public static func desiredState(from eligibility: [LocalPushHostEligibility]) -> [String: [String]] {
        var desired: [String: Set<String>] = [:]
        for host in eligibility where host.enabled && host.hasCredential {
            for rawSSID in host.ssids {
                let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ssid.isEmpty else { continue }
                desired[ssid, default: []].insert(host.hostID)
            }
        }
        return desired.mapValues { Array($0).sorted() }
    }

    /// Compares desired state against current managed configurations and
    /// returns the minimal diff. Identical desired state is a no-op; an
    /// SSID present in `current` but absent from `desired` is removed.
    public static func plan(
        desired: [String: [String]],
        current: [ManagedPushConfiguration],
        revision: Int
    ) -> PushConfigurationPlan {
        let currentBySSID = Dictionary(uniqueKeysWithValues: current.map { ($0.ssid, $0) })
        var upserts: [ManagedPushConfiguration] = []
        for ssid in desired.keys.sorted() {
            let hostIDs = (desired[ssid] ?? []).sorted()
            if currentBySSID[ssid]?.hostIDs != hostIDs {
                upserts.append(ManagedPushConfiguration(ssid: ssid, hostIDs: hostIDs, revision: revision))
            }
        }
        let removals = currentBySSID.keys.filter { desired[$0] == nil }.sorted()
        return PushConfigurationPlan(upserts: upserts, removals: removals)
    }
}
