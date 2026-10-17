import SwiftUI

/// S01 — Welcome and guided setup (docs/navigation-screens.md).
/// Shown in the Projects tab while no host is configured.
struct WelcomeView: View {
    var onConnectHost: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image("HostConnection")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 8) {
                Text("Connect Your Own OpenCode Host")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("This app talks to an OpenCode server you host yourself, over HTTPS. Pair once with a pairing link or password; you can add more hosts later in Settings.")
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
        }
        .padding(24)
        .navigationTitle("OpenCode Client")
    }
}

#Preview {
    NavigationStack {
        WelcomeView(onConnectHost: {})
    }
}
