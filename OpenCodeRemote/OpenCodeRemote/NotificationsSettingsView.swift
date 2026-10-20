import SwiftUI
import OpenCodeDomain
import UserNotifications

/// S17 — Notifications & activities (docs/navigation-screens.md):
/// the iOS permission state and the app's own choices are SEPARATE
/// states, both shown. The dormant local-push pipeline is presented
/// with its honest status (docs/local-push-implementation.md §"Status
/// and diagnostics": an inactive manager or missing entitlement must
/// never read as healthy delivery). Controls match the
/// implementation-defaults.md "Notifications"/"Live Activities"
/// defaults exactly.
struct NotificationsSettingsView: View {
    @Environment(SettingsLibrary.self) private var settings
    @Environment(SessionLocalStateStore.self) private var localState
    @Environment(NotificationsLibrary.self) private var notifications
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            permissionSection
            contentSection
            categoriesSection
            scopeSection
            deliverySection
        }
        .scrollContentBackground(.hidden)
        .background(Color("AppBackgroundColor"))
        .navigationTitle("Notifications")
        .task { await notifications.load() }
    }

    // MARK: - Permission (the OS state)

    private var permissionSection: some View {
        Section {
            LabeledContent("iOS Permission", value: notifications.statusLabel)
            if notifications.status == .notDetermined || notifications.status == nil {
                Button {
                    Task { await notifications.ask() }
                } label: {
                    if notifications.askInFlight {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Asking iOS…")
                        }
                    } else {
                        Label("Ask for Notifications", systemImage: "bell.badge")
                    }
                }
                .disabled(notifications.askInFlight)
            }
            if notifications.status == .denied {
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        } header: {
            Text("Permission")
        } footer: {
            Text("Permission is iOS's own decision, shown separately from the choices below — an allowed permission with delivery switched off still sends nothing.")
        }
    }

    // MARK: - Content privacy (the app's choice)

    private var contentSection: some View {
        Section {
            Picker("Content", selection: contentBinding) {
                Text("Generic").tag(NotificationContentPrivacy.generic)
                Text("Detailed").tag(NotificationContentPrivacy.detailed)
            }
        } header: {
            Text("Content")
        } footer: {
            Text("Generic previews never include a session title or outcome text. Until you make the choice, content stays generic.")
        }
    }

    private var categoriesSection: some View {
        Section {
            Toggle("Turn Succeeded", isOn: categoryBinding(\.succeeded))
            Toggle("Turn Failed", isOn: categoryBinding(\.failed))
            Toggle("Turn Interrupted", isOn: categoryBinding(\.interrupted))
        } header: {
            Text("Categories")
        } footer: {
            Text("Only the enabled outcomes notify; every other event stays quiet.")
        }
    }

    // MARK: - Scope

    private var scopeSection: some View {
        Section {
            LabeledContent("Followed Sessions", value: "\(localState.state.followed.count)")
            Picker("Live Activities", selection: activityBinding) {
                ForEach(ActivityStartPreference.allCases, id: \.self) { preference in
                    Text(preference.label).tag(preference)
                }
            }
        } header: {
            Text("Scope")
        } footer: {
            Text("Follow sessions from a row's menu in Sessions — only app-started or followed sessions can notify. Live Activities show their last update time and can go stale while the app is suspended.")
        }
    }

    // MARK: - Delivery status (the dormant pipeline, honestly)

    private var deliverySection: some View {
        Section {
            LabeledContent("Local Delivery", value: "Not Active")
        } header: {
            Text("Delivery")
        } footer: {
            Text("Background delivery through Local Push Connectivity needs Apple to approve this app's push entitlement. Your settings here are saved and apply the moment delivery activates. Foreground banners for turns that finish while the app is inactive already work.")
        }
    }

    // MARK: - Bindings

    /// The content choice is optional in state (nil = generic until
    /// the onboarding choice is made); the picker always shows a real
    /// value and writes the chosen one.
    private var contentBinding: Binding<NotificationContentPrivacy> {
        Binding(
            get: { settings.state.notificationContentPrivacy ?? .generic },
            set: { newValue in settings.update { $0.notificationContentPrivacy = newValue } }
        )
    }

    private func categoryBinding(_ keyPath: WritableKeyPath<NotificationCategories, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.state.notificationCategories[keyPath: keyPath] },
            set: { newValue in settings.update { $0.notificationCategories[keyPath: keyPath] = newValue } }
        )
    }

    private var activityBinding: Binding<ActivityStartPreference> {
        Binding(
            get: { settings.state.activityStartPreference },
            set: { newValue in settings.update { $0.activityStartPreference = newValue } }
        )
    }
}

extension ActivityStartPreference {
    var label: String {
        switch self {
        case .ask: "Ask"
        case .automatic: "Start Automatically"
        case .manual: "Follow Session Only"
        }
    }
}
