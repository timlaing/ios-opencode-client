import SwiftUI

/// S19 — Privacy/storage/sync subpage (docs/navigation-screens.md):
/// app lock + grace, real cache sizes with Clear Cache, draft
/// retention with the shortening confirmation, the backup
/// explanation, and Clear Local Data. Every destructive action names
/// EXACTLY what it removes before it runs, and never touches hosts or
/// credentials (Remove Host owns those — W17).
struct PrivacyStorageView: View {
    @Environment(SettingsLibrary.self) private var settings
    @Environment(SessionLocalStateStore.self) private var localState

    @State private var storage = StorageLibrary()
    @State private var cacheUsage: Int64?
    @State private var pendingRetention: DraftRetention?
    @State private var showingClearCache = false
    @State private var showingClearLocalData = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            appLockSection
            backupsSection
            cacheSection
            draftsSection
            localDataSection
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("S19.error")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("AppBackgroundColor"))
        .navigationTitle("Privacy & Storage")
        .task { refreshCacheUsage() }
    }

    // MARK: - App lock

    private var appLockSection: some View {
        Section {
            Toggle("Require App Lock", isOn: binding(\.appLockEnabled))
            if settings.state.appLockEnabled {
                Picker("Lock After", selection: binding(\.appLockGrace)) {
                    ForEach(AppLockGrace.allCases, id: \.self) { grace in
                        Text(grace.label).tag(grace)
                    }
                }
            }
        } header: {
            Text("App Lock")
        } footer: {
            Text("Unlocked with Face ID or Touch ID; your passcode is the fallback. Notifications keep working while the app is locked. iOS still shows the last screen as a snapshot in the app switcher.")
        }
    }

    // MARK: - Backups (explanation only — no mechanism to control)

    private var backupsSection: some View {
        Section("Backups") {
            Text("Your device backup keeps preserved drafts and preferences. Credentials, sync payloads, staged files, notification ledgers, and caches are excluded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        Section {
            Picker("Cache Size", selection: binding(\.cacheSizePolicy)) {
                ForEach(CacheSizePolicy.allCases, id: \.self) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            LabeledContent("Used") {
                if let cacheUsage {
                    Text(ByteCountFormatter.string(fromByteCount: cacheUsage, countStyle: .file))
                } else {
                    ProgressView()
                }
            }
            Button("Clear Cache", role: .destructive) {
                showingClearCache = true
            }
            .accessibilityIdentifier("S19.clearCache")
        } header: {
            Text("Cache")
        } footer: {
            Text("A soft budget for refetchable history, previews, and thumbnails within the 30-day window. Drafts and pending uploads are never removed to meet it.")
        }
        .confirmationDialog(
            "Clear the refetchable cache?",
            isPresented: $showingClearCache,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) { clearCache() }
        } message: {
            Text("Refetchable local data only — drafts, pending uploads, hosts, and credentials stay.")
        }
    }

    // MARK: - Drafts

    private var draftsSection: some View {
        Section {
            Picker("Keep Drafts", selection: draftRetentionBinding) {
                ForEach(DraftRetention.allCases, id: \.self) { retention in
                    Text(retention.label).tag(retention)
                }
            }
        } header: {
            Text("Drafts")
        } footer: {
            Text(draftRetentionFooter)
        }
        .confirmationDialog(
            "Remove older drafts?",
            isPresented: Binding(
                get: { pendingRetention != nil },
                set: { if !$0 { pendingRetention = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Shorten Retention", role: .destructive) {
                if let pending = pendingRetention {
                    settings.update { $0.draftRetention = pending }
                }
                pendingRetention = nil
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text("Drafts last edited beyond the new retention are removed the next time they are pruned. Cancel keeps your current retention and every draft.")
        }
    }

    private var draftRetentionFooter: String {
        switch settings.state.draftRetention {
        case .untilDiscarded:
            return "Drafts are kept until you send or discard them. Each draft's expiry appears on it once a limited retention is active."
        case .days(let days):
            return "Drafts expire \(days) days after their last edit; each draft shows its expiry date. Drafts never sync to iCloud."
        }
    }

    /// A SHORTENING retention confirms before it can remove existing
    /// drafts (implementation-defaults.md "Drafts"); lengthening and
    /// until-discarded apply immediately — they remove nothing.
    private var draftRetentionBinding: Binding<DraftRetention> {
        Binding(
            get: { settings.state.draftRetention },
            set: { newValue in
                let existing = (try? storage.existingDraftLastEdits()) ?? []
                guard settings.draftRetentionRemovesExisting(existing, switchingTo: newValue) else {
                    settings.update { $0.draftRetention = newValue }
                    return
                }
                pendingRetention = newValue
            }
        )
    }

    // MARK: - Clear Local Data

    private var localDataSection: some View {
        Section {
            Button("Clear Local Data…", role: .destructive) {
                showingClearLocalData = true
            }
            .accessibilityIdentifier("S19.clearLocalData")
        } header: {
            Text("Local Data")
        } footer: {
            Text("Hosts, their credentials, and anything on the server are untouched — manage hosts per host on the Servers tab.")
        }
        .confirmationDialog(
            "Clear all local data?",
            isPresented: $showingClearLocalData,
            titleVisibility: .visible
        ) {
            Button("Clear Local Data", role: .destructive) { clearLocalData() }
        } message: {
            Text("Removes the cache, saved drafts, session pins/follows/hides, and settings defaults. Hosts, their credentials, and server data are not touched.")
        }
    }

    // MARK: - Actions

    /// The walk is on-demand (screen open, after a clear) over a
    /// bounded cache; a future large cache moves it off-main whole.
    private func refreshCacheUsage() {
        cacheUsage = storage.cacheUsageBytes()
    }

    private func clearCache() {
        do {
            try storage.clearCache()
            errorMessage = nil
            refreshCacheUsage()
        } catch {
            errorMessage = "The cache could not be cleared: \(error.localizedDescription)"
        }
    }

    private func clearLocalData() {
        do {
            // Order matters: the throwing wipes first — settings and
            // pins reset only if the storage halves succeeded, so a
            // partial failure never hides data the wipe was meant to
            // remove behind a "clean" preferences state.
            try storage.clearCache()
            try storage.clearAllDrafts()
            localState.clear()
            settings.resetToDefaults()
            pendingRetention = nil
            errorMessage = nil
            refreshCacheUsage()
        } catch {
            errorMessage = "Local data was not fully cleared: \(error.localizedDescription)"
        }
    }

    // MARK: - Bindings

    /// Settings edits must PERSIST (`SettingsLibrary.update`): a
    /// straight `@Observable` binding would mutate the in-memory state
    /// and silently skip the UserDefaults write.
    private func binding<T>(_ keyPath: WritableKeyPath<SettingsState, T>) -> Binding<T> {
        Binding(
            get: { settings.state[keyPath: keyPath] },
            set: { newValue in settings.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
