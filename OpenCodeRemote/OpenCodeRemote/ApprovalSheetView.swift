import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S11 approval detail (W09, docs/navigation-screens.md S08/S11): the
/// exact action/resources and the host's save scope BEFORE the
/// buttons; Allow Once is the default primary; “Allow and Remember” is
/// a distinct action offered only where the request carries a real
/// save scope (never renamed “Allow everything”); Reject and the
/// optional explanation stay visible. Response buttons are disabled
/// while one is submitting. A stale 404 replaces the buttons with the
/// settled “Answered Elsewhere” status and a Return to Chat action —
/// never a local success. Several pending approvals count in the
/// header; answering advances to the next one in place.
struct ApprovalSheetView: View {
    let host: OpenCodeDomain.Host
    let session: Session
    /// The conversation's live approvals — passed INTO the sheet's
    /// closure: state on the presenting view does not reach a sheet.
    let approvals: ApprovalLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var submitting = false
    @State private var submitError: String?
    /// Set only by a stale 404 — an accepted reply advances/ dismisses
    /// through the shrunken queue instead of a settled status.
    @State private var answeredElsewhere = false
    /// The entry this sheet is answering, pinned while on screen. Adopted
    /// from the queue head once it exists and advanced only by an accepted
    /// reply: a refresh that reshuffles the queue must never redirect a
    /// tap on "Allow" from the request on screen to a different one.
    @State private var presented: ApprovalLibrary.Entry?

    var body: some View {
        NavigationStack {
            Group {
                if answeredElsewhere {
                    settledStatus
                } else if let entry = presented {
                    detail(for: entry)
                } else if approvals.entries.isEmpty, approvals.refreshError == nil {
                    // Nothing pinned and nothing pending: the approval
                    // settled (answered elsewhere, refreshed away) before
                    // the sheet could adopt it — the spinner branch would
                    // never resolve. Mirrors FormSheetView's `.empty`
                    // scene; the refresh keeps entries on screen while in
                    // flight, so an empty list here is a completed truth,
                    // not a load in progress.
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "No Pending Approvals",
                            systemImage: "checkmark.shield",
                            description: Text("This approval is no longer pending.")
                        )
                        Button("Return to Chat") { dismiss() }
                            .accessibilityIdentifier("S11.permission.return")
                    }
                } else if approvals.refreshError == nil {
                    ProgressView("Checking Pending Approvals…")
                } else {
                    // Refresh failed before anything arrived — the dock
                    // is empty, so offer the honest state and a way out.
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "Approvals Unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text(approvals.refreshError ?? "")
                        )
                        Button("Return to Chat") { dismiss() }
                            .accessibilityIdentifier("S11.permission.return")
                    }
                }
            }
            .navigationTitle("Approval Needed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { resetReplyState() }
        // Adopt the queue head only while nothing is pinned (first load).
        // `initial: true` because the sheet is presented only once requests
        // are already pending: onChange's default skips that first value,
        // which would leave `presented` nil and the body stuck on the
        // loading state. Adoption still only ever fills an empty pin — a
        // refresh that reshuffles the dock can never retarget the buttons
        // at a request the user never saw.
        .onChange(of: approvals.entries, initial: true) { _, entries in
            if presented == nil { presented = entries.first }
        }
    }

    // MARK: - Detail

    private func detail(for entry: ApprovalLibrary.Entry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if approvals.pendingCount > 1 {
                    Label(
                        "\(approvals.pendingCount) waiting",
                        systemImage: "list.bullet.rectangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if entry.isLinked {
                    // Linked entry: the actual owner session ID stays
                    // visible — this approval belongs to that session.
                    Label(
                        "Child session \(entry.request.sessionID)",
                        systemImage: "arrow.turn.down.right"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // Requested action + resources + ask text — all BEFORE
                // any button (S11).
                Group {
                    Text(entry.request.action)
                        .font(.title3.weight(.semibold))
                    if let ask = entry.request.message {
                        Text(ask)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entry.request.resources, id: \.self) { resource in
                            Text(resource)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    if let source = entry.request.source, source.isTool {
                        Text("Tool \(source.id) · \(source.messageID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // The host's EXACT save scope, before the buttons —
                    // the only basis for an Always action.
                    if entry.request.offersSaveScope {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Remember this choice:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(entry.request.save ?? [], id: \.self) { scope in
                                Text(scope)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                TextField("Optional explanation", text: $message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)

                if let refreshError = approvals.refreshError {
                    Text(refreshError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let submitError {
                    Text(submitError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                // Response buttons — disabled while submitting.
                VStack(spacing: 10) {
                    Button {
                        answer(.once)
                    } label: {
                        if submitting { ProgressView() } else { Text("Allow Once") }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(submitting)
                    .accessibilityIdentifier("S11.permission.once")

                    if entry.request.offersSaveScope {
                        Button {
                            answer(.always)
                        } label: {
                            Text("Allow and Remember")
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(submitting)
                        .accessibilityIdentifier("S11.permission.always")
                    }

                    Button(role: .destructive) {
                        answer(.reject)
                    } label: {
                        Text("Reject")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(submitting)
                    .accessibilityIdentifier("S11.permission.reject")
                }
            }
            .padding()
        }
    }

    // MARK: - Settled (answered elsewhere)

    private var settledStatus: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Answered Elsewhere")
                .font(.headline)
            Text("This approval is no longer pending — it was already handled or withdrawn. Nothing was approved by this reply.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Return to Chat") { dismiss() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("S11.permission.return")
        }
        .padding()
    }

    // MARK: - Actions

    private func answer(_ decision: PermissionDecision) {
        // The PINNED entry is answered — never the dock's live head, which
        // a refresh could have replaced since this screen was rendered.
        guard !submitting, let entry = presented else { return }
        submitting = true
        submitError = nil
        Task {
            let outcome = await approvals.submit(
                entry,
                decision: decision,
                message: message.isEmpty ? nil : message,
                host: host
            )
            submitting = false
            switch outcome {
            case .accepted:
                // The queue advanced: fresh local state, then adopt the
                // new head in place (its explanation is not this one's),
                // or back to the chat when nothing is pending anymore.
                resetReplyState()
                presented = approvals.entries.first
                if presented == nil { dismiss() }
            case .answeredElsewhere:
                answeredElsewhere = true
            case .failed(let reason):
                submitError = reason
            }
        }
    }

    /// Fresh local state for the NEXT pending entry — the sheet's
    /// onAppear, and after an accepted reply advances the queue.
    private func resetReplyState() {
        message = ""
        submitError = nil
        answeredElsewhere = false
    }
}
