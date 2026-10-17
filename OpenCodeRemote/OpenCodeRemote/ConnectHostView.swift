import SwiftUI

/// S03 — Connect Host (docs/navigation-screens.md).
/// The surface and review state are here now; pairing itself (link redemption,
/// health checks, credential storage) lands in a follow-up slice, so Connect
/// stays unavailable rather than pretending to pair.
struct ConnectHostView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var pairingLink = ""
    @State private var displayName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Image("ConnectBackground")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        labeledField("Pairing link", text: $pairingLink, placeholder: "Paste the pairing link from your host")
                        labeledField("Display name (optional)", text: $displayName, placeholder: "e.g. Home server")
                        Text("Connect is unavailable until the pairing transport ships in a follow-up build slice. Nothing is sent from this screen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Connect Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }
}

#Preview {
    ConnectHostView()
}
