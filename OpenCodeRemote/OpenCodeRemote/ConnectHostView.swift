import SwiftUI
import UIKit
import OpenCodeTransport

/// S03 — Connect Host (docs/navigation-screens.md).
///
/// The existing OpenCode pairing process is the default path: scan the QR code
/// printed by `opencode pair` (or paste its link), review the parsed
/// destination(s), and confirm. Manual host/user/password entry is the
/// fallback. Redemption, the health check, and saving the host ship with the
/// pairing transport in a follow-up slice, so Connect stays disabled rather
/// than pretending to pair — and reviewing a code never spends it.
struct ConnectHostView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Manual fallback (password form): address, username, password, name.
    @State private var host = ""
    @State private var port = ""
    @State private var username = BasicCredential.fixedUsername
    @State private var password = ""
    @State private var displayName = ""

    // Default path: scan the QR code or paste the printed link, then review.
    @State private var pairingLink = ""
    @State private var showScanner = false
    @State private var scannerMessage: String?
    @State private var review: Review?
    @State private var parseError: String?

    private struct Review: Identifiable {
        let id = UUID()
        let payload: PairingPayload
        var selectedDestination: URL
    }

    var body: some View {
        NavigationStack {
            // Transparent form over one screen-sized, clipped background; the
            // image is a background so it never affects the form's layout.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let review {
                        reviewSection(review)
                    } else {
                        scanSection
                        linkSection
                        manualSection
                    }
                    transportNote
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                Image("ConnectBackground")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
                    .ignoresSafeArea()
            }
            .navigationTitle("Connect Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showScanner, onDismiss: { scannerMessage = nil }) {
                scannerSheet
            }
        }
    }

    // MARK: - Default path: QR scan

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scan the pairing code")
                .font(.headline)
            Button {
                parseError = nil
                showScanner = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!QRScannerView.isSupported)
            if !QRScannerView.isSupported {
                Text("No camera is available here — paste a pairing link or enter the host details below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scannerSheet: some View {
        ZStack(alignment: .top) {
            QRScannerView(
                onScan: handleScan,
                onUnavailable: { scannerMessage = $0 }
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                Text("Point at the QR code shown by opencode pair")
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())

                if let scannerMessage {
                    VStack(spacing: 10) {
                        Text(scannerMessage)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                        if scannerMessage.contains("Settings") {
                            Button("Open Settings") {
                                if let settings = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(settings)
                                }
                            }
                        }
                        Button("Done") { showScanner = false }
                    }
                    .padding(16)
                    .frame(maxWidth: 320)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.top, 12)
        }
    }

    /// A valid scan stops the camera and opens the review state; an invalid
    /// payload is reported over the still-running scanner so the user can try
    /// again without losing the code's short window.
    private func handleScan(_ payload: String) {
        do {
            try startReview(of: payload)
            scannerMessage = nil
            showScanner = false
        } catch {
            scannerMessage = "That isn't an OpenCode pairing code. Point at the QR shown by opencode pair."
        }
    }

    /// Parses the input and opens the review state on its first destination.
    private func startReview(of input: String) throws {
        let parsed = try PairingParser.parse(input)
        review = Review(payload: parsed, selectedDestination: parsed.destinations[0])
    }

    // MARK: - Pasted pairing link

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledField(
                "Pairing link",
                text: $pairingLink,
                placeholder: "Paste the link printed by opencode pair"
            )
            Button("Review Link") {
                do {
                    try startReview(of: pairingLink)
                    parseError = nil
                } catch {
                    parseError = message(for: error)
                }
            }
            .buttonStyle(.bordered)
            if let parseError {
                Text(parseError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Fallback: manual host details

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Or enter host details")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                labeledField("Host or IP", text: $host, placeholder: "opencode.example.com")
                labeledField("Port", text: $port, placeholder: "Port", width: 92)
            }
            labeledField("Username", text: $username, placeholder: "Usually \"opencode\"")
            labeledSecureField("Password", text: $password, placeholder: "Host password or token")
            labeledField(
                "Display name (optional)",
                text: $displayName,
                placeholder: "e.g. Home server"
            )
            Button("Connect") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        }
    }

    // MARK: - Review (parsed destination(s) awaiting confirmation)

    private func reviewSection(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review destination")
                .font(.headline)
            if review.payload.destinations.count > 1 {
                ForEach(review.payload.destinations, id: \.self) { destination in
                    Button {
                        self.review?.selectedDestination = destination
                    } label: {
                        HStack {
                            Text(destination.absoluteString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if destination == review.selectedDestination {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Text("The code lists several addresses for the same host. The reviewed address is used when redemption ships.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(review.selectedDestination.absoluteString)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            labeledField("Display name (optional)", text: $displayName, placeholder: "e.g. Home server")
            Button("Connect") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
            Button("Scan a Different Code") {
                self.review = nil
                if QRScannerView.isSupported { showScanner = true }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Shared pieces

    private var transportNote: some View {
        Text("Redeeming a code, the health check, and saving the host ship with the pairing transport in a follow-up build slice. Reviewing a code never spends it, and nothing is sent from this screen.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func labeledField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        width: CGFloat? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(width: width)
        }
    }

    private func labeledSecureField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    /// Turns a pairing-parse failure into the S03 error variant copy
    /// (docs/navigation-screens.md): invalid/legacy link with next steps.
    private func message(for error: Error) -> String {
        switch error as? PairingParseError {
        case .legacyLink:
            return "That's an old-style pairing link. Generate a new one with opencode pair."
        case .unsupportedScheme:
            return "Only http and https pairing links are accepted."
        case .credentialBearingAddress:
            return "That address carries embedded credentials. Generate a fresh pairing link instead."
        case .invalidCode:
            return "That doesn't contain a valid pairing code."
        case .emptyInput:
            return "Paste the pairing link printed by opencode pair."
        default:
            return "That isn't an OpenCode pairing link. Paste the link printed by opencode pair."
        }
    }
}

#Preview {
    ConnectHostView()
}
