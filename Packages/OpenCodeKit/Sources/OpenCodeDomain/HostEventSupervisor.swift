import Foundation
import OpenCodeTransport

/// Readable per-host stream state (docs/local-push-implementation.md
/// §"Status and diagnostics"): Establishing / Available / Reconnecting /
/// Re-pair Required, plus stopped. Eligibility and notification permission
/// are tracked separately by the configuration/status layer.
public enum HostStreamStatus: Equatable, Sendable {
    case stopped
    case establishing
    case available
    case reconnecting(attempts: Int)
    /// The host rejected the stored credential; blind retries are stopped
    /// until pairing changes (docs/local-push-implementation.md §8).
    case repairRequired
}

/// Diagnostic counters per host. Counts are diagnostics only — never
/// delivery acknowledgments or proof a human saw a banner.
public struct HostStreamDiagnostics: Equatable, Sendable {
    public var generation: Int
    public var status: HostStreamStatus
    public var receivedEvents: Int
    public var relevantEvents: Int
    public var reconnectCount: Int
    public var lastEventAt: Date?
    /// Redacted reason text; never credentials or raw event bodies.
    public var lastReason: String?

    public init(
        generation: Int = 0,
        status: HostStreamStatus = .stopped,
        receivedEvents: Int = 0,
        relevantEvents: Int = 0,
        reconnectCount: Int = 0,
        lastEventAt: Date? = nil,
        lastReason: String? = nil
    ) {
        self.generation = generation
        self.status = status
        self.receivedEvents = receivedEvents
        self.relevantEvents = relevantEvents
        self.reconnectCount = reconnectCount
        self.lastEventAt = lastEventAt
        self.lastReason = lastReason
    }
}

/// One host's SSE observer for the local-push extension
/// (docs/local-push-implementation.md §"OpenCode-specific stream adapter").
///
/// Owns exactly one live stream per host: a reconnect loop with a jittered
/// 1–60 s schedule for transient failures, no retries after an auth
/// rejection, and generation tokens so callbacks from a stopped provider
/// generation cannot update current state. Relevant events are classified
/// inline and handed to the injected delivery sink (which owns the
/// transactional ledger); everything else is discarded without retention.
///
/// Lifecycle maps onto NEAppPushProvider: `start()`, `stop()`,
/// `handleTimerEvent()`, and `updatePolicy(_:)` for configuration diffs.
public actor HostEventSupervisor {
    /// Injectable I/O so tests run the loop deterministically.
    public struct Environment: Sendable {
        public var makeTransport: @Sendable (URL, BasicCredential?) -> any OpenCodeTransport
        public var credential: @Sendable () async throws -> BasicCredential?
        public var sleep: @Sendable (Duration) async throws -> Void
        /// Random source in `0.0...1.0` for backoff jitter.
        public var jitter: @Sendable () -> Double
        public var now: @Sendable () -> Date

        public init(
            makeTransport: @escaping @Sendable (URL, BasicCredential?) -> any OpenCodeTransport,
            credential: @escaping @Sendable () async throws -> BasicCredential?,
            sleep: @escaping @Sendable (Duration) async throws -> Void,
            jitter: @escaping @Sendable () -> Double,
            now: @escaping @Sendable () -> Date
        ) {
            self.makeTransport = makeTransport
            self.credential = credential
            self.sleep = sleep
            self.jitter = jitter
            self.now = now
        }
    }

    /// Cross-boundary effects the supervisor orchestrates but does not own.
    public struct Callbacks: Sendable {
        public var onStatus: @Sendable (HostStreamStatus) async -> Void
        public var deliver: @Sendable (NotificationDraft) async -> Void
        /// Called on every observed (re)connect marker (server.connected):
        /// the owner reconciles subscribed-session state here. It must not
        /// flood historical alerts — the stream never replays history.
        public var onReconnect: @Sendable () async -> Void

        public init(
            onStatus: @escaping @Sendable (HostStreamStatus) async -> Void,
            deliver: @escaping @Sendable (NotificationDraft) async -> Void,
            onReconnect: @escaping @Sendable () async -> Void
        ) {
            self.onStatus = onStatus
            self.deliver = deliver
            self.onReconnect = onReconnect
        }
    }

    /// First retry delay floor and the backoff cap, in seconds.
    public static let minimumBackoff: Double = 1
    public static let maximumBackoff: Double = 60

    private let host: OpenCodeDomain.Host
    private let environment: Environment
    private var callbacks: Callbacks
    private var classifier: EventClassifier

    private var generation = 0
    private var task: Task<Void, Never>?
    private(set) var diagnostics: HostStreamDiagnostics

    public init(
        host: OpenCodeDomain.Host,
        classifier: EventClassifier,
        environment: Environment,
        callbacks: Callbacks
    ) {
        self.host = host
        self.classifier = classifier
        self.environment = environment
        self.callbacks = callbacks
        diagnostics = HostStreamDiagnostics()
    }

    // MARK: - Lifecycle

    /// Starts (or restarts) the observer under a fresh generation. Old
    /// generation tasks are cancelled first and their callbacks ignored.
    public func start() {
        task?.cancel()
        generation += 1
        diagnostics = HostStreamDiagnostics(generation: generation)
        let generation = generation
        task = Task { await self.run(generation: generation) }
    }

    /// Cancels the stream, backoff waits and callbacks, and publishes
    /// stopped. Preferences/policy are never mutated by a stop.
    public func stop() async {
        generation += 1
        task?.cancel()
        task = nil
        diagnostics.status = .stopped
        await callbacks.onStatus(.stopped)
    }

    /// Applies a policy change (configuration diff). Takes effect for the
    /// next event without disturbing a healthy stream.
    public func updatePolicy(_ policy: NotificationPolicy) {
        classifier.policy = policy
    }

    /// System timer opportunity: restart a stopped observer. A healthy or
    /// backing-off stream is left alone — never a second live stream for
    /// the same host (docs/local-push-implementation.md §7).
    public func handleTimerEvent() async {
        switch diagnostics.status {
        case .stopped:
            start()
        case .repairRequired:
            break // credential must change before another attempt
        case .establishing, .available, .reconnecting:
            break // loop owns reconnection; no duplicate stream
        }
    }

    public func status() -> HostStreamStatus {
        diagnostics.status
    }

    // MARK: - Stream loop

    private func run(generation: Int) async {
        var attempt = 0
        while !Task.isCancelled, generation == self.generation {
            do {
                await publish(.establishing, generation: generation)
                let credential = try await environment.credential()
                let stream = environment.makeTransport(host.address, credential).events()
                var reconciled = false
                for try await event in stream {
                    guard generation == self.generation else { return }
                    diagnostics.receivedEvents += 1
                    diagnostics.lastEventAt = environment.now()
                    if event.type == "server.connected", !reconciled {
                        reconciled = true
                        // Only a proven connection resets the retry counter;
                        // failures without a connect keep growing the
                        // backoff (docs/local-push-implementation.md §5).
                        attempt = 0
                        await publish(.available, generation: generation)
                        await callbacks.onReconnect()
                    }
                    if let draft = classifier.classify(event) {
                        diagnostics.relevantEvents += 1
                        await callbacks.deliver(draft)
                    }
                }
                // A clean stream end still means the observer is down; fall
                // through to reconnect like any other failure.
                throw TransportError.connectionFailed("event stream ended")
            } catch {
                guard generation == self.generation else { return }
                if let transportError = error as? TransportError, transportError.isAuthenticationFailure {
                    diagnostics.lastReason = "credential rejected"
                    await publish(.repairRequired, generation: generation)
                    return
                }
                attempt += 1
                diagnostics.reconnectCount += 1
                diagnostics.lastReason = Self.redactedReason(for: error)
                await publish(.reconnecting(attempts: attempt), generation: generation)
                do {
                    try await environment.sleep(.seconds(Self.backoffDelay(attempt: attempt, jitter: environment.jitter())))
                } catch {
                    return // cancelled during backoff
                }
            }
        }
    }

    private func publish(_ status: HostStreamStatus, generation: Int) async {
        guard generation == self.generation else { return }
        diagnostics.status = status
        await callbacks.onStatus(status)
    }

    /// Jittered delay in `[minimumBackoff, maximumBackoff]`: doubling base
    /// with 50–100 % jitter, clamped to the documented bounds.
    static func backoffDelay(attempt: Int, jitter: Double) -> Double {
        let base = min(Self.maximumBackoff, pow(2, Double(max(attempt - 1, 0))))
        let jittered = base * (0.5 + 0.5 * min(max(jitter, 0), 1))
        return min(max(jittered, Self.minimumBackoff), Self.maximumBackoff)
    }

    /// Transport errors are already sanitized; log only the case name.
    static func redactedReason(for error: Error) -> String {
        guard let error = error as? TransportError else { return "transport failure" }
        switch error {
        case .http(let status, _): return "http \(status)"
        case .connectionFailed: return "connection failed"
        case .decodingFailed: return "decoding failed"
        case .emptyBody: return "empty response"
        case .invalidURL: return "invalid address"
        case .cancelled: return "cancelled"
        }
    }
}
