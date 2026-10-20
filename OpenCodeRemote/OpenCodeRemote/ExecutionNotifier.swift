import Foundation
import Observation
import OpenCodeTransport
import UserNotifications

/// The two OS touch points, behind a protocol so the decision logic
/// below is testable without UNUserNotificationCenter.
protocol UserNotifying: Sendable {
    /// One lazy ask (the OS answers subsequent calls from its cached
    /// decision without re-prompting).
    func requestAuthorization() async -> Bool
    func post(identifier: String, title: String, body: String) async
}

/// The real UserNotifications bridge.
struct NotificationCenterNotifier: UserNotifying {
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(identifier: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A nil trigger delivers immediately: the event's ARRIVAL is
        // the moment — not a schedule derived from its timestamp.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Stable-identity dedup for posted notifications
/// (docs/implementation-defaults.md): keyed by the server's own event
/// id, persisted SEVEN days with a 10,000-entry ceiling — the same
/// event can never banner twice, and the store cannot grow without
/// bound. Not actor-isolated: UserDefaults access is thread-safe and
/// the store must be constructible as a default argument.
final class NotificationDedupStore {
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let ceiling = 10_000

    private let defaults: UserDefaults
    private let now: () -> Date
    private let key: String
    private let retention: TimeInterval
    private let ceiling: Int

    init(
        defaults: UserDefaults = .standard,
        retention: TimeInterval = NotificationDedupStore.retention,
        ceiling: Int = NotificationDedupStore.ceiling,
        now: @escaping () -> Date = { Date() },
        key: String = "w16.notification.posted"
    ) {
        self.defaults = defaults
        self.retention = retention
        self.ceiling = ceiling
        self.now = now
        self.key = key
    }

    func alreadyPosted(_ identifier: String) -> Bool {
        // The window applies on READ: an entry older than the
        // retention is not remembered — only markPosted's prune
        // actually removes it, but expiry is a fact, not a cleanup.
        guard let stored = entries()[identifier] else { return false }
        return stored >= now().timeIntervalSince1970 - retention
    }

    func markPosted(_ identifier: String) {
        var stored = entries()
        stored[identifier] = now().timeIntervalSince1970
        // Prune first: the window must be honoured BEFORE the ceiling
        // trims, so ancient entries never crowd out live ones.
        let cutoff = now().timeIntervalSince1970 - retention
        stored = stored.filter { $0.value >= cutoff }
        if stored.count > ceiling {
            let oldest = stored.sorted { $0.value < $1.value }.prefix(stored.count - ceiling)
            for key in oldest.map(\.key) { stored.removeValue(forKey: key) }
        }
        defaults.set(stored, forKey: key)
    }

    private func entries() -> [String: Double] {
        defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
    }
}

/// W16 initial local notifications (S17 half — docs/api-contract.md
/// W16, docs/implementation-defaults.md notification rules): an
/// execution TERMINAL event for the open conversation banners when the
/// app is NOT active — the user sent a prompt, left the app, and the
/// turn's outcome arrives over the live event stream.
///
/// Honest scope, deliberately narrower than the dormant push
/// extension: only events RECEIVED live on the on-screen
/// conversation's subscription can notify. A reconnect fetches state
/// and never emits a backlog of historical completion alerts; a
/// conversation that is not mounted is not subscribed; and a terminal
/// the user WATCHES arrive (app active) needs no banner — that gate
/// is `sceneActive`, kept fresh by the view's scenePhase observer.
///
/// The three terminal outcomes are the contract's canonical
/// notification transitions (succeeded / failed / interrupted).
@MainActor
final class ExecutionNotifier {
    private let notifier: UserNotifying
    private let dedup: NotificationDedupStore

    /// Kept fresh by the view's `.onChange(of: scenePhase)`; true
    /// while the app is active — a banner would interrupt the user
    /// who is already looking at the screen.
    var sceneActive = true

    private var authorization: Bool?
    private var authorizing: Task<Bool, Never>?

    init(
        notifier: UserNotifying = NotificationCenterNotifier(),
        dedup: NotificationDedupStore = NotificationDedupStore()
    ) {
        self.notifier = notifier
        self.dedup = dedup
    }

    /// Asks for notification authorization once, lazily, when the
    /// first subscription starts. Single-flight: a terminal event
    /// arriving while the prompt is up awaits the same ask.
    func prepare() async {
        if authorization != nil { return }
        if let authorizing {
            authorization = await authorizing.value
            return
        }
        let ask = Task { await notifier.requestAuthorization() }
        authorizing = ask
        authorization = await ask.value
        authorizing = nil
    }

    /// Handles one execution terminal event. All gates in order:
    /// app active → no banner; already posted (stable identity) → no
    /// banner; unauthorized → no banner; an id-less event cannot be
    /// deduplicated → never posted (a duplicate banner is worse than
    /// a missed one on an event whose identity we do not know).
    func handleTerminal(_ event: OpenCodeEvent, sessionTitle: String?) async {
        guard !sceneActive else { return }
        guard let identifier = event.id, !identifier.isEmpty else { return }
        guard !dedup.alreadyPosted(identifier) else { return }
        if authorization == nil {
            await prepare()
        }
        guard authorization == true else { return }

        let phrase: String
        switch event.type {
        case "session.execution.succeeded":
            phrase = "The turn completed."
        case "session.execution.failed":
            phrase = "The turn failed."
        case "session.execution.interrupted":
            phrase = "The turn was stopped."
        default:
            // Only canonical terminal types banner — an unknown type
            // never invents an outcome.
            return
        }
        dedup.markPosted(identifier)
        await notifier.post(
            identifier: "opencode.execution.\(identifier)",
            title: sessionTitle ?? "OpenCode Client",
            body: phrase
        )
    }
}
