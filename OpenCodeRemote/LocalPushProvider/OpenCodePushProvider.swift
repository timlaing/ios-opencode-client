import Foundation
import NetworkExtension
import os
import OpenCodeDomain
import OpenCodeStorage
import OpenCodeTransport
import UserNotifications

/// Local Push Connectivity provider for OpenCode hosts
/// (docs/local-push-implementation.md).
///
/// Activation on a device still requires the approved app-push-provider
/// entitlement on app and provider targets plus the App Group/Keychain
/// sharing groups (docs/design-review.md release gates); those entitlement
/// files are deliberately absent from the repository until Apple approves.
/// Everything below the entitlement — configuration decoding, per-host
/// observers, classification, ledger-backed scheduling — is complete and
/// runs the moment the signed entitlement exists.
final class OpenCodePushProvider: NEAppPushProvider {
    /// Versioned configuration payload carried in `providerConfiguration`.
    /// Identifiers and revision only — never passwords, tokens, prompts or
    /// transcript text (spec §"App-side manager configuration" step 3).
    typealias ConfigurationPayload = PushProviderConfiguration

    private let logger = Logger(
        subsystem: "uk.co.laingcorp.opencode-client.LocalPushProvider",
        category: "OpenCodePushProvider"
    )

    /// Serialises every entry point: NetworkExtension documents no single
    /// queue for start/stop/handleTimerEvent, and the providerConfiguration
    /// KVO callback runs on the thread that set the value. Unsynchronised
    /// dictionary access could crash — or start a second stream for one
    /// host, breaking one-stream-per-host (spec §7).
    private let stateQueue = DispatchQueue(label: "uk.co.laingcorp.opencode-client.LocalPushProvider.state")

    private var generation = 0
    private var supervisors: [String: HostEventSupervisor] = [:]
    /// The secret each supervisor was BUILT with (memory-only, never
    /// logged): a re-pair can keep the same host ID, so no configuration
    /// diff ever arrives for it — comparing the freshly read Keychain
    /// secret against this is the only way to notice the old observer is
    /// presenting a credential the host now rejects.
    private var secretsByHost: [String: String] = [:]
    private var ledger: NotificationLedger?
    private var hostStore: HostStore?
    private let credentials = KeychainCredentialStore()
    private var configurationObservation: NSKeyValueObservation?
    /// Whether the provider is between a successful start and a stop. Read
    /// and written only on `stateQueue`; guards deferred work (a KVO block
    /// enqueued before stop may run after it) from restarting observers on
    /// a stopped provider.
    private var running = false

    // MARK: - NEAppPushProvider lifecycle

    override func start(completionHandler: @escaping (Error?) -> Void) {
        stateQueue.async { [self] in
            generation += 1
            logger.info("start (generation \(self.generation))")
            do {
                let configuration = try decodeConfiguration()
                try prepareStores()
                startObservers(for: configuration, generation: generation)
                observeConfigurationChanges()
                running = true
                // Per-host status stays authoritative: a success callback is not
                // evidence that every stream is ready (spec §7).
                completionHandler(nil)
            } catch {
                logger.error("start failed: \(String(describing: error))")
                completionHandler(error)
            }
        }
    }

    override func stop(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        stateQueue.async { [self] in
            logger.info("stop reason \(String(describing: reason))")
            generation += 1 // stale callbacks from the old generation are ignored
            running = false
            configurationObservation = nil
            let stopping = supervisors.values
            supervisors = [:]
            secretsByHost = [:]
            Task { @Sendable in
                for supervisor in stopping {
                    await supervisor.stop()
                }
                completionHandler()
            }
        }
    }

    override func handleTimerEvent() {
        stateQueue.async { [self] in
            // A timer opportunity delivered after stop (the system can race
            // a pending timer) must not resurrect observers.
            guard running else { return }
            // A host whose observer could not start — most importantly a
            // Keychain read that failed while the device was locked
            // (errSecInteractionNotAllowed) — is retried here; startObservers
            // skips hosts whose supervisor already holds the CURRENT secret
            // (and replaces one whose secret changed), so healthy streams
            // are untouched.
            if let configuration = try? decodeConfiguration() {
                startObservers(for: configuration, generation: generation)
            }
            for supervisor in supervisors.values {
                Task { await supervisor.handleTimerEvent() }
            }
        }
    }

    /// Applies configuration diffs: start new hosts, stop removed hosts,
    /// leave healthy streams untouched (spec §7). Cancel old observers
    /// before replacing them.
    private func observeConfigurationChanges() {
        configurationObservation = observe(\.providerConfiguration, options: [.new]) { [weak self] _, _ in
            // KVO fires on the thread that set providerConfiguration — join
            // the same serial queue before touching shared state.
            self?.stateQueue.async { self?.applyConfigurationChange() }
        }
    }

    private func applyConfigurationChange() {
        // A configuration change deferred behind stop (KVO fired on another
        // thread while stop ran) must not restart observers.
        guard running else { return }
        generation += 1
        let generation = generation
        do {
            let configuration = try decodeConfiguration()
            let desired = Set(configuration.hostIDs)
            for (hostID, supervisor) in supervisors where !desired.contains(hostID) {
                supervisors.removeValue(forKey: hostID)
                secretsByHost.removeValue(forKey: hostID)
                Task { await supervisor.stop() }
                logger.info("stopped removed host observer")
            }
            // Reopen only when missing: a configuration change must not
            // build a second HostStore/NotificationLedger (two GRDB queues
            // on one file) while running supervisors still deliver through
            // the ledger captured when they were created.
            if hostStore == nil || ledger == nil {
                try prepareStores()
            }
            startObservers(for: configuration, generation: generation)
            // Existing streams keep running; only their notification policy
            // diff (followed sessions) is refreshed.
            let followed = Set(configuration.followedSessions)
            for supervisor in supervisors.values {
                Task { await supervisor.updatePolicy(NotificationPolicy(followedSessions: followed)) }
            }
        } catch {
            logger.error("configuration change rejected: \(String(describing: error))")
        }
    }

    // MARK: - Wiring

    private func decodeConfiguration() throws -> ConfigurationPayload {
        guard let raw = providerConfiguration?["payload"] as? Data else {
            throw StoreIssue.missingConfiguration
        }
        let payload = try JSONDecoder().decode(ConfigurationPayload.self, from: raw)
        guard payload.schemaVersion == ConfigurationPayload.currentSchemaVersion else {
            throw StoreIssue.unsupportedSchema(payload.schemaVersion)
        }
        return payload
    }

    private enum StoreIssue: Error {
        case missingConfiguration
        case unsupportedSchema(Int)
        case storesUnavailable
    }

    private func prepareStores() throws {
        // Extension fail-closed: without the App Group container there is no
        // shared store, so refuse to run against a private diverging one.
        let directory = try SharedStoreLocation.directory(allowAppLocalFallback: false)
        hostStore = try HostStore(writingAt: directory)
        ledger = try NotificationLedger(writingAt: directory)
    }

    private func startObservers(for configuration: ConfigurationPayload, generation: Int) {
        guard let hostStore, let ledger else { return }
        let followed = Set(configuration.followedSessions)
        let hosts = (try? hostStore.hosts()) ?? []
        for host in hosts where configuration.hostIDs.contains(host.id.rawValue) {
            // Keychain FIRST: the existing-supervisor check below must be
            // able to compare secrets, and a re-pair under the same host ID
            // produces no configuration diff (hostIDs unchanged → no KVO),
            // so this read is the only chance to notice the change.
            let secret: String?
            do {
                secret = try credentials.secret(for: host.id.rawValue)
            } catch {
                // A Keychain READ failure (a locked device returns
                // errSecInteractionNotAllowed) is not "no credential":
                // leave this host unsupervised so handleTimerEvent retries
                // it instead of logging a misleading absence. An existing
                // supervisor keeps running on the secret it was built with.
                logger.error("keychain read failed for host; observer deferred: \(String(describing: error))")
                continue
            }
            guard let secret else {
                logger.warning("host has no stored credential; observer not started")
                continue
            }
            if let existing = supervisors[host.id.rawValue] {
                // Never a second stream per host — but a changed secret
                // (re-pair) must REPLACE the observer built with the old
                // one: its credential closure captured the rejected secret
                // and it would keep it until the system restarts the
                // provider, leaving the host silently unsupervised.
                guard secretsByHost[host.id.rawValue] != secret else { continue }
                logger.info("credential changed for host; replacing observer")
                Task { await existing.stop() }
            }
            let supervisor = makeSupervisor(
                host: host,
                secret: secret,
                followedSessions: followed,
                ledger: ledger,
                generation: generation
            )
            supervisors[host.id.rawValue] = supervisor
            secretsByHost[host.id.rawValue] = secret
            Task { await supervisor.start() }
        }
    }

    private func makeSupervisor(
        host: OpenCodeDomain.Host,
        secret: String,
        followedSessions: Set<String>,
        ledger: NotificationLedger,
        generation: Int
    ) -> HostEventSupervisor {
        let logger = self.logger
        return HostEventSupervisor(
            host: host,
            classifier: EventClassifier(
                hostID: host.id.rawValue,
                policy: NotificationPolicy(followedSessions: followedSessions)
            ),
            environment: .init(
                makeTransport: { address, credential in
                    URLSessionTransport(baseURL: address, credential: credential)
                },
                credential: { BasicCredential(secret: secret) },
                sleep: { duration in
                    try await Task.sleep(for: duration)
                },
                jitter: { Double.random(in: 0...1) },
                now: { Date() }
            ),
            callbacks: .init(
                onStatus: { status in
                    // Status publication to the shared store ships with the
                    // S17 status/diagnostics screens; transitions are logged
                    // redacted meanwhile (spec §"Status and diagnostics").
                    logger.info("host stream status: \(String(describing: status))")
                },
                deliver: { draft in
                    await Self.schedule(draft: draft, hostID: host.id.rawValue, ledger: ledger, logger: logger)
                },
                onReconnect: {
                    // Reconciliation of followed sessions uses the W03/W04
                    // read APIs once those slices land; the stream never
                    // replays history, so bootstrap cannot flood alerts
                    // (spec §"OpenCode-specific stream adapter").
                }
            )
        )
    }

    /// Ledger-claimed scheduling through UNUserNotificationCenter. The
    /// ledger key is the request identifier, so the OS dedupes repeats and
    /// overlapping provider lifetimes cannot double-schedule a transition.
    private static func schedule(
        draft: NotificationDraft,
        hostID: String,
        ledger: NotificationLedger,
        logger: Logger
    ) async {
        let claimed = (try? ledger.claim(
            key: draft.ledgerKey,
            hostID: hostID,
            category: draft.category.rawValue,
            sessionID: draft.sessionID,
            owner: "provider",
            lease: 60
        )) ?? false
        guard claimed else { return }

        let content = UNMutableNotificationContent()
        content.title = draft.title
        content.body = draft.body
        // Routing identifiers only — no transcript text, tool arguments or
        // file content; a tap leads to reauthentication/refetch, never an
        // automatic approval (spec §"Notification classification").
        content.userInfo = [
            "ledgerKey": draft.ledgerKey,
            "sessionID": draft.sessionID,
            "ownerID": draft.ownerID ?? "",
            "category": draft.category.rawValue,
        ]
        let request = UNNotificationRequest(identifier: draft.ledgerKey, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            try ledger.recordScheduled(key: draft.ledgerKey)
        } catch {
            try? ledger.recordFailed(key: draft.ledgerKey)
            logger.error("notification scheduling failed")
        }
    }
}
