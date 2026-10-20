import SwiftUI
import OpenCodeDomain

/// S02 touchpoint from S18 (docs/navigation-screens.md): per-host
/// local-notification settings — enablement and the eligible Wi-Fi
/// list, the exact shape `PushEligibility` feeds to the local-push
/// configuration controller. The delivery row per host shows the
/// honest status (the entitlement is still pending — see
/// `PushEligibility.entitlementGranted`); destructive host management
/// stays on the Servers tab (Remove Host owns credentials).
struct HostsSettingsView: View {
    @Environment(HostLibrary.self) private var hosts
    @Environment(SettingsLibrary.self) private var settings

    @State private var newSSIDByHost: [String: String] = [:]

    var body: some View {
        List {
            if hosts.entries.isEmpty {
                Section {
                    Text("No hosts yet — pair one on the Servers tab.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(hosts.entries) { entry in
                hostSection(entry)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("AppBackgroundColor"))
        .navigationTitle("Hosts")
    }

    private func hostSection(_ entry: HostLibrary.Entry) -> some View {
        let hostID = entry.id.rawValue
        let push = settings.pushSettings(for: hostID)
        let status = PushEligibility.status(
            enabled: push.enabled,
            hasCredential: hosts.credential(for: entry.id) != nil,
            ssids: push.ssids
        )
        return Section {
            Toggle("Notify for This Host", isOn: enabledBinding(hostID))
            if push.enabled {
                ForEach(push.ssids, id: \.self) { ssid in
                    LabeledContent("Eligible Wi-Fi") {
                        HStack(spacing: 8) {
                            Text(ssid)
                                .lineLimit(1)
                            Button {
                                settings.updatePushSettings(for: hostID) { value in
                                    value.ssids.removeAll { $0 == ssid }
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(ssid)")
                        }
                    }
                }
                TextField("Network name (SSID)", text: ssidBinding(hostID))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add Eligible Wi-Fi") {
                    let ssid = (newSSIDByHost[hostID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !ssid.isEmpty else { return }
                    settings.updatePushSettings(for: hostID) { value in
                        if !value.ssids.contains(ssid) { value.ssids.append(ssid) }
                    }
                    newSSIDByHost[hostID] = ""
                }
                .disabled((newSSIDByHost[hostID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            LabeledContent("Delivery", value: status.label)
        } header: {
            Text(entry.host.displayName)
        } footer: {
            Text(statusFooter(status))
        }
    }

    private func statusFooter(_ status: LocalPushStatus) -> String {
        switch status {
        case .disabled:
            return "This host never notifies while off; foreground banners for the open conversation still work."
        case .missingCredential:
            return "The saved credential is gone — re-pair this host on the Servers tab before delivery could work."
        case .notConfigured:
            return "Add at least one eligible Wi-Fi network; delivery only listens on those networks."
        case .unsupportedEntitlement:
            return "Configured. Background delivery needs Apple to approve this app's push entitlement; the settings here are saved and apply the moment it activates."
        case .waitingForEligibleWiFi:
            return "Configured; delivery starts when the device joins an eligible network and the host stream connects."
        }
    }

    // MARK: - Bindings

    private func enabledBinding(_ hostID: String) -> Binding<Bool> {
        Binding(
            get: { settings.pushSettings(for: hostID).enabled },
            set: { newValue in settings.updatePushSettings(for: hostID) { $0.enabled = newValue } }
        )
    }

    private func ssidBinding(_ hostID: String) -> Binding<String> {
        Binding(
            get: { newSSIDByHost[hostID] ?? "" },
            set: { newSSIDByHost[hostID] = $0 }
        )
    }
}
