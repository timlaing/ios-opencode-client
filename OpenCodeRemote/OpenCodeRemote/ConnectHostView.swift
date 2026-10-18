import SwiftUI
import UIKit
import OpenCodeDomain
import OpenCodeTransport

/// S03 — Connect Host (docs/navigation-screens.md).
///
/// The existing OpenCode pairing process is the default path: scan the QR code
/// printed by `opencode pair` (or paste its link), review the parsed
/// destination(s), and confirm. Manual host/user/password entry is the
/// fallback. Connect redeems the code (or proves the password) with a health
/// check against the reviewed destination, then saves the host and its
/// credential; reviewing a code never spends it.
struct ConnectHostView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(HostLibrary.self) private var library

    // Manual fallback (password form): server URL, username, password, name.
    @State private var serverURL = ""
    @State private var username = BasicCredential.fixedUsername
    @State private var password = ""
    @State private var displayName = ""
    @FocusState private var manualURLFocused: Bool

    // Default path: scan the QR code or paste the printed link, then review.
    @State private var pairingLink = ""
    @State private var showScanner = false
    @State private var scannerMessage: String?
    @State private var review: Review?
    @State private var parseError: String?
    /// Token retained after the code is redeemed: a failed health check
    /// retries against the same host without re-spending the single-use code
    /// (docs/navigation-screens.md). Never displayed or logged.
    @State private var redeemedToken: String?

    // Pairing progress and failure variants (idle → working → saved).
    @State private var phase: Phase = .idle
    @State private var connectionFailure: String?

    private let pairing = HostPairingService()

    private enum Phase {
        case idle
        case working
    }

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
                        .disabled(phase == .working)
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
                connectionFailure = nil
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

    /// Mock HTTP is a development-only transport profile (docs/navigation-
    /// screens.md): DEBUG builds may pair with the reference mock on plain
    /// http; release builds refuse cleartext before a pairing code or
    /// credential can travel on it.
    private static var allowsInsecureHTTP: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Parses the input and opens the review state on its first destination.
    private func startReview(of input: String) throws {
        let parsed = try PairingParser.parse(input, allowsInsecureHTTP: Self.allowsInsecureHTTP)
        review = Review(payload: parsed, selectedDestination: parsed.destinations[0])
        redeemedToken = nil
        connectionFailure = nil
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
            labeledField(
                "Server URL",
                text: $serverURL,
                placeholder: "https://opencode.example.com:4096",
                keyboardType: .URL,
                submitLabel: .done,
                focus: $manualURLFocused,
                onSubmit: { manualURLFocused = false }
            )
            labeledField("Username", text: $username, placeholder: "Usually \"opencode\"")
            labeledSecureField("Password", text: $password, placeholder: "Host password or token")
            labeledField(
                "Display name (optional)",
                text: $displayName,
                placeholder: "e.g. Home server"
            )
            Button {
                Task { await connectManually() }
            } label: {
                if phase == .working {
                    ProgressView()
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(phase == .working || serverURL.trimmed.isEmpty || password.isEmpty)
            failureLabel
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
                        // The retained token stays valid: every address in one
                        // pairing payload is the same host, so a health check
                        // may retry against another listed address without
                        // re-spending the code (docs/navigation-screens.md).
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
                    // Locked while pairing is in flight so the in-progress
                    // redeem/health run keeps its reviewed destination.
                    .disabled(phase == .working)
                }
                Text("The code lists several addresses for the same host. Connect uses the reviewed address.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(review.selectedDestination.absoluteString)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            labeledField("Display name (optional)", text: $displayName, placeholder: "e.g. Home server")
            Button {
                Task { await redeemAndConnect(review) }
            } label: {
                if phase == .working {
                    ProgressView()
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(phase == .working)
            failureLabel
            Button("Scan a Different Code") {
                self.review = nil
                redeemedToken = nil
                connectionFailure = nil
                if QRScannerView.isSupported { showScanner = true }
            }
            .buttonStyle(.bordered)
            .disabled(phase == .working)
        }
    }

    // MARK: - Pairing actions

    /// Redeem flow: the single-use code exchanges for a token (spent exactly
    /// once — a retained token from a previous attempt is reused), the token
    /// is proven with a health check, then host + credential are saved.
    private func redeemAndConnect(_ review: Review) async {
        phase = .working
        connectionFailure = nil
        defer { phase = .idle }
        do {
            let secret: String
            if let redeemedToken {
                secret = redeemedToken
            } else {
                let token = try await pairing.redeem(code: review.payload.code, at: review.selectedDestination)
                redeemedToken = token
                secret = token
            }
            let paired = try await pairing.completePairing(
                secret: secret,
                at: review.selectedDestination,
                displayName: displayName
            )
            try library.add(paired)
            dismiss()
        } catch {
            connectionFailure = message(for: error)
        }
    }

    /// Manual fallback: the supplied password is proven by the health check
    /// itself, then host + credential are saved.
    private func connectManually() async {
        phase = .working
        connectionFailure = nil
        defer { phase = .idle }
        do {
            let address = try PairingParser.manualAddress(
                serverURL,
                allowsInsecureHTTP: Self.allowsInsecureHTTP
            )
            let paired = try await pairing.verifyPassword(
                at: address,
                username: username,
                password: password,
                displayName: displayName
            )
            try library.add(paired)
            dismiss()
        } catch {
            connectionFailure = message(for: error)
        }
    }

    // MARK: - Shared pieces

    private var failureLabel: some View {
        Group {
            if let connectionFailure {
                Text(connectionFailure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var transportNote: some View {
        Text("Pairing codes are single-use and expire about five minutes after opencode pair prints them. The credential is stored in this device's Keychain only; reviewing a code never spends it.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func labeledField(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        width: CGFloat? = nil,
        keyboardType: UIKeyboardType = .default,
        submitLabel: SubmitLabel = .return,
        focus: FocusState<Bool>.Binding? = nil,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                let field = TextField(placeholder, text: text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let focus {
                    field.focused(focus)
                } else {
                    field
                }
            }
            .keyboardType(keyboardType)
            .submitLabel(submitLabel)
            .onSubmit { onSubmit?() }
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

    /// Turns a parse or pairing failure into the S03 error variant copy
    /// (docs/navigation-screens.md): invalid link with next steps, expired or
    /// spent code, unreachable address, rejected credential.
    private func message(for error: Error) -> String {
        if let failure = error as? HostPairingService.Failure {
            switch failure {
            case .expiredCode:
                return "That pairing code has expired or was already used. Generate a new one with opencode pair."
            case .unreachable:
                return "The host couldn't be reached at that address. Check the address, port, and that the server is running."
            case .rejectedCredential:
                return "The host rejected the credential. Check the password and try again."
            case .unsupportedUsername:
                return "OpenCode hosts use the username \"opencode\" — change it back and retry."
            case .invalidResponse:
                return "That address responded, but not as an OpenCode server. Check the address and port."
            }
        }
        if error is HostLibrary.LibraryError {
            return "This device's storage is unavailable, so the host can't be saved. Free up space and try again."
        }
        switch error as? PairingParseError {
        case .legacyLink:
            return "That's an old-style pairing link. Generate a new one with opencode pair."
        case .unsupportedScheme:
            return "Only http and https pairing links are accepted."
        case .credentialBearingAddress:
            return "That address carries embedded credentials. Generate a fresh pairing link instead."
        case .invalidCode:
            return "That doesn't contain a valid pairing code."
        case .invalidAddress:
            return "Enter a valid server URL — for example https://opencode.example.com:4096 (or just the host, which defaults to https)."
        case .emptyInput:
            return "Paste the pairing link printed by opencode pair."
        default:
            return "That isn't an OpenCode pairing link. Paste the link printed by opencode pair."
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    ConnectHostView()
        .environment(HostLibrary())
}
