import SwiftUI

/// S01 — Welcome and guided setup (docs/navigation-screens.md).
/// Shown in the Servers tab while no host is configured.
struct WelcomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    var onConnectHost: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            connectionArtwork
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Connect Your Own OpenCode Host")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("This app talks to an OpenCode server you host yourself, over HTTPS. Pair once with a pairing link or password; you can add more hosts later on the Servers tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            Button(action: onConnectHost) {
                Label("Connect an OpenCode Host", systemImage: "server.rack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Demo mode using bundled data arrives with a later build slice.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                Text("Notifications: iOS asks the first time a turn finishes while the app is closed — content stays generic until you choose otherwise in Settings ▸ Notifications.")
                Text("Background delivery is pending Apple approval of the app's push entitlement; banners while the app is inactive already work.")
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .navigationTitle("OpenCode Client")
    }

    private var connectionArtwork: some View {
        let image = Image("HostConnection")
            .resizable()
            .scaledToFit()
        return Group {
            if colorScheme == .dark {
                image.colorInvert()
            } else {
                image
            }
        }
    }
}

#Preview {
    NavigationStack {
        WelcomeView(onConnectHost: {})
    }
}
