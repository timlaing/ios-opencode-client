import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport

/// W16 live event subscription for ONE host while its conversation is
/// open (docs/api-contract.md W16, docs/navigation-screens.md S08).
///
/// The stream is volatile: `GET /api/event` covers all locations, has
/// no replay (Last-Event-ID is not honoured), and a slow consumer can
/// lose frames — so reconnect NEVER replays writes; the reconnect is
/// signalled to the reconciler, which fetches authoritative state.
///
/// Liveness needs no client-side heartbeat tracking: the server sends
/// `: heartbeat` comments roughly every 15 seconds, which keep
/// URLSession's idle timer (60s default) reset, and a stream that goes
/// genuinely silent is terminated by that timer — the `for try await`
/// ends or throws and this supervisor reconnects with the documented
/// backoff (docs/implementation-defaults.md: 1, 2, 4, 8, 16, 32, then
/// 60 seconds, ±20% jitter). An authentication failure stops the
/// retry loop outright and surfaces Re-pair Required — a credential
/// problem never heals by retrying.
@MainActor
@Observable
final class EventLibrary {
    enum Phase: Equatable {
        case idle
        case connecting
        case live
        case retrying(afterSeconds: Double)
        case repairRequired(String)
    }

    typealias CredentialProvider = @MainActor (HostID) -> BasicCredential?
    typealias TransportFactory = @Sendable (URL, BasicCredential?) -> any OpenCodeTransport

    /// The reconciler's two hooks: every event, and the `server.connected`
    /// opening frame of each (re)connection is ALSO delivered as an event —
    /// the reconciler classifies it into the full authoritative refresh,
    /// so no separate connect callback exists (one path, no double refresh).
    var onEvent: ((OpenCodeEvent) async -> Void)?

    private(set) var phase: Phase = .idle

    /// docs/implementation-defaults.md transient-failure ladder.
    static let backoff: [Double] = [1, 2, 4, 8, 16, 32, 60]

    private let makeTransport: TransportFactory
    /// Injectable sleep so tests observe the ladder without waiting on it.
    private let sleep: (UInt64) async -> Void
    /// Injectable ±20% jitter; identity in tests pins the ladder exactly.
    private let jitter: (Double) -> Double
    private var credentialProvider: CredentialProvider?

    private var task: Task<Void, Never>?
    /// Bumped by every watch()/stop(): a resumed loop that finds a newer
    /// token exits without touching phase (the W14 stale-token rule).
    private var generation = 0

    init(
        makeTransport: @escaping TransportFactory = { URLSessionTransport(baseURL: $0, credential: $1) },
        sleep: @escaping (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0 * 1_000_000_000) },
        jitter: @escaping (Double) -> Double = { delay in delay * Double.random(in: 0.8...1.2) },
        credentialProvider: CredentialProvider? = nil
    ) {
        self.makeTransport = makeTransport
        self.sleep = sleep
        self.jitter = jitter
        self.credentialProvider = credentialProvider
    }

    /// Late-binds credential access to the host library (SwiftUI creates
    /// view state before the environment is available). Re-read on EVERY
    /// reconnect attempt, so a mid-flight re-pair is picked up.
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] in hosts?.credential(for: $0) }
    }

    /// Starts (or RE-targets) the subscription. One conversation is open
    /// per view; a second watch supersedes the first.
    func watch(host: OpenCodeDomain.Host) {
        generation += 1
        task?.cancel()
        let token = generation
        phase = .connecting
        task = Task { [weak self] in
            await self?.run(host: host, token: token)
        }
    }

    /// A dismissed conversation stops watching — nothing polls or streams
    /// on its behalf (the same rule as the post-send watches).
    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func run(host: OpenCodeDomain.Host, token: Int) async {
        var failures = 0
        while generation == token {
            guard let credential = credentialProvider?(host.id) else {
                phase = .repairRequired("Re-pair this host to follow its events.")
                return
            }
            if failures > 0 {
                let delay = jitteredDelay(failures)
                phase = .retrying(afterSeconds: delay)
                await sleep(UInt64(delay.rounded()))
                guard generation == token else { return }
            }
            phase = .connecting
            let transport = makeTransport(host.address, credential)
            var delivered = false
            do {
                for try await event in transport.events() {
                    guard generation == token else { return }
                    if !delivered {
                        // A delivered frame proves the connection: reset
                        // the ladder, like the web client's reconnect.
                        delivered = true
                        failures = 0
                        phase = .live
                    }
                    await onEvent?(event)
                }
                // The server closed the stream cleanly (restart, deploy):
                // still a transient failure — reconnect with backoff.
                guard generation == token else { return }
                failures += 1
            } catch is CancellationError {
                return
            } catch let error as TransportError {
                guard generation == token else { return }
                if error.isAuthenticationFailure {
                    phase = .repairRequired("Re-pair this host to follow its events.")
                    return
                }
                failures += 1
            } catch {
                guard generation == token else { return }
                failures += 1
            }
        }
    }

    /// The documented ladder, capped at 60s, ±20% jittered.
    func jitteredDelay(_ failures: Int) -> Double {
        let base = Self.backoff[min(max(failures, 1), Self.backoff.count) - 1]
        return min(60, jitter(base))
    }
}
