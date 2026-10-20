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

/// Presents execution banners while the app is still considered
/// FOREGROUND (review W16 r10): iOS delivers an app-posted
/// notification SILENTLY in that state unless a delegate answers
/// `willPresent` — and the `.inactive` cases this feature targets
/// (app switcher, Control Center) are exactly that state, so
/// without this the banner only appeared on a real background
/// transition. The notifier already gates on scene activity
/// (`sceneActive`), so presenting here never interrupts a user who
/// is watching the screen.
final class ExecutionNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.options(for: notification.request.identifier)
    }

    /// Only this app's execution banners present in-foreground;
    /// every other notification keeps the system's own rules.
    static func options(for identifier: String) -> UNNotificationPresentationOptions {
        identifier.hasPrefix("opencode.execution.") ? [.banner, .sound] : []
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
/// The suspension truth (review W16 r7): iOS suspends the app a few
/// seconds after it leaves the foreground, which stops the stream —
/// so in practice banners cover the inactive/early-background window
/// (app switcher, Control Center, a brief background), never a turn
/// that ends AFTER suspension; that terminal is reconciled on the
/// next foreground without a banner. That window is preserved by
/// `ExecutionNotificationPresenter` (the `willPresent` delegate —
/// iOS delivers app-posted notifications SILENTLY while the app is
/// still foreground-ish, review W16 r10). A `beginBackgroundTask`
/// was considered and deliberately rejected — it buys only a
/// bounded ~30 seconds in exchange for balanced-start/end lifecycle
/// risk — and the entitlement-gated push provider (stage 1) is the
/// real path for post-suspension delivery.
///
/// The three terminal outcomes are the contract's canonical
/// notification transitions (succeeded / failed / interrupted).
@MainActor
final class ExecutionNotifier {
    private let notifier: UserNotifying
    private let dedup: NotificationDedupStore
    /// S20 diagnostics (W17): permission outcomes and posted banners
    /// are recorded; nil keeps the W16 behaviour untouched (tests
    /// never write log files). Set by the conversation when the
    /// subscription starts.
    var diagnostics: DiagnosticsLogStore?

    /// Kept fresh by the view's `.onChange(of: scenePhase)`; true
    /// while the app is active — a banner would interrupt the user
    /// who is already looking at the screen.
    var sceneActive = true

    private var authorization: Bool?
    private var authorizing: Task<Bool, Never>?

    init(
        notifier: UserNotifying = NotificationCenterNotifier(),
        dedup: NotificationDedupStore = NotificationDedupStore(),
        diagnostics: DiagnosticsLogStore? = nil
    ) {
        self.notifier = notifier
        self.dedup = dedup
        self.diagnostics = diagnostics
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
        // One record per process: the lazy ask's outcome is the fact
        // S20's last-error display needs when delivery later proves
        // silent.
        if let diagnostics {
            if authorization == true {
                diagnostics.record(.notifications, "Notification permission granted")
            } else {
                diagnostics.record(.notifications, severity: .error, "Notification permission not granted")
            }
        }
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
        // The consent alert held the scene INACTIVE through the first
        // check; answering it returns the app to the foreground — the
        // user may be watching the screen again by now, and a banner
        // then interrupts exactly who the gate protects (review W16
        // r12).
        guard !sceneActive else { return }

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
        diagnostics?.record(.notifications, "Banner posted: \(event.type)")
    }
}
