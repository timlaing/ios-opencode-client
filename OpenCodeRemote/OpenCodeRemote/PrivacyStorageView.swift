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
    @Environment(HostLibrary.self) private var hosts
    @Environment(CloudSettingsSync.self) private var cloud

    @State private var storage = StorageLibrary()
    @State private var cacheUsage: Int64?
    @State private var pendingRetention: DraftRetention?
    @State private var showingClearCache = false
    @State private var showingClearLocalData = false
    @State private var showingClearSynced = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            syncSection
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
        .navigationTitle("Privacy, Storage & Sync")
        .task {
            refreshCacheUsage()
            reconcileSync()
        }
        .onChange(of: settings.state.icloudSyncRequested) { _, _ in
            reconcileSync()
        }
    }

    // MARK: - App lock
    // WITHHELD (review W17 r4): appLockEnabled/appLockGrace persist
    // in the settings blob, but no LocalAuthentication mechanism
    // reads them — the honesty rule keeps the section off-screen
    // until the app-lock slice lands. A toggle the app does not
    // honour tells the user they are protected when they are not.

    // MARK: - iCloud (I6: opt-in, scoped, tombstoned)

    /// One pull-merge-push pass. The engine is opt-in gated: while
    /// the toggle is off it reads and writes nothing, so this call is
    /// safe at every screen open.
    private func reconcileSync() {
        cloud.reconcile(
            settings: settings,
            hostAddresses: Dictionary(
                hosts.entries.map { ($0.id.rawValue, $0.host.address.absoluteString) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    private var syncStatusLabel: String {
        switch cloud.status {
        case .off: "Off"
        case .upToDate: "Up to Date"
        case .error: "Not Synced"
        }
    }

    private var syncSection: some View {
        Section {
            Toggle("Sync Settings with iCloud", isOn: binding(\.icloudSyncRequested))
            if settings.state.icloudSyncRequested {
                LabeledContent("Status", value: syncStatusLabel)
                if case .error(let message) = cloud.status {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("S19.syncError")
                }
                if !cloud.lastReport.pendingCandidates.isEmpty {
                    LabeledContent("Addresses to Offer", value: "\(cloud.lastReport.pendingCandidates.count)")
                }
                Button("Clear Synced Settings…", role: .destructive) {
                    showingClearSynced = true
                }
                .accessibilityIdentifier("S19.clearSynced")
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Off until you opt in. Only appearance and host addresses sync — never credentials, drafts, notification choices, or attachment references. Turning sync off keeps every local setting. A removed host stays recorded in iCloud until you clear synced settings, so it cannot come back on its own.")
        }
        .confirmationDialog(
            "Clear synced settings in iCloud?",
            isPresented: $showingClearSynced,
            titleVisibility: .visible
        ) {
            Button("Clear Synced Settings", role: .destructive) {
                cloud.clearSyncedSettings()
            }
        } message: {
            Text("Removes the appearance and host-address records this app stored in iCloud, including removals it was keeping. Local settings, hosts, and credentials are untouched — the next sync uploads them again.")
        }
    }

    // MARK: - Backups (explanation only — no mechanism to control)

    private var backupsSection: some View {
        Section("Backups") {
            Text("Your device backup keeps preserved drafts, preferences, the local diagnostic log, notification history, and iCloud sync records. Credentials (keychain, this-device-only), staged files, and caches are excluded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        Section {
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
        }
        // No budget picker (review W17 r4): cacheSizePolicy
        // persists, but no eviction mechanism enforces it — Used
        // and Clear Cache are the controls with real mechanisms.
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
