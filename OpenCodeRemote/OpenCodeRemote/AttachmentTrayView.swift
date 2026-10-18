import SwiftUI
import OpenCodeDomain

/// S09 attachment tray (W08): the full list behind the composer's chips.
/// Every item shows its name, size and honest state, and offers per-item
/// remove/cancel/retry plus the photo copy options (Original/Balanced,
/// Include Location for COPIES). Nothing here claims capabilities the
/// contract doesn't give: a model that can't ingest a type is labelled,
/// and a staged file remains a host-side file.
struct AttachmentTrayView: View {
    @Bindable var attachments: AttachmentLibrary
    let host: OpenCodeDomain.Host
    /// The selected model's `input` capabilities — drives the honest
    /// "can't read directly" labels; nil when unknown.
    var inputCapabilities: Set<String>?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if attachments.drafts.contains(where: \.isPhoto) {
                    Section("Photo Copies") {
                        Picker("Default", selection: $attachments.photoCopy) {
                            ForEach(AttachmentLibrary.PhotoCopy.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .accessibilityIdentifier("S09.photoCopy.default")
                        Toggle("Include Location", isOn: $attachments.includeLocation)
                            .accessibilityIdentifier("S09.includeLocation")
                        Text("Balanced copies fit to 2048 pixels and remove location unless included. Originals are sent as picked.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Attachments") {
                    if attachments.drafts.isEmpty {
                        Text("No attachments yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(attachments.drafts) { draft in
                        row(draft)
                    }
                }
            }
            .navigationTitle("Attachments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("S09.done")
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ draft: AttachmentLibrary.Draft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: draft.mimeType))
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(sizeLabel(draft))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                stateLabel(draft)
            }
            if let reason = AttachmentLibrary.unsupportedReason(
                mimeType: draft.mimeType, inputCapabilities: inputCapabilities
            ) {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if draft.isPhoto, !isUploading(draft) {
                Picker("Copy", selection: Binding(
                    get: { draft.photoMode },
                    set: { attachments.setPhotoCopy($0, for: draft.id, host: host) }
                )) {
                    ForEach(AttachmentLibrary.PhotoCopy.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            HStack(spacing: 16) {
                if case .uploading = draft.state {
                    Button("Cancel", role: .cancel) { attachments.cancel(draft.id) }
                        .accessibilityIdentifier("S09.item.cancel")
                }
                if case .failed = draft.state {
                    Button("Retry") { attachments.retry(draft.id, host: host) }
                        .accessibilityIdentifier("S09.item.retry")
                }
                Spacer()
                Button("Remove", role: .destructive) { attachments.remove(draft.id) }
                    .accessibilityIdentifier("S09.item.remove")
            }
            .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stateLabel(_ draft: AttachmentLibrary.Draft) -> some View {
        switch draft.state {
        case .preparing:
            HStack(spacing: 6) {
                ProgressView()
                Text("Preparing…").font(.caption).foregroundStyle(.secondary)
            }
        case .uploading:
            HStack(spacing: 6) {
                ProgressView()
                Text("Uploading…").font(.caption).foregroundStyle(.secondary)
            }
        case .ready(let staged, _):
            // A remote host reference is ready WITHOUT any upload — it must
            // not read as "inline" content that was never sent.
            if case .hostReference = draft.source {
                Label("Referenced on host", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label(staged ? "Ready (staged on host)" : "Ready (inline)",
                      systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func isUploading(_ draft: AttachmentLibrary.Draft) -> Bool {
        if case .uploading = draft.state { return true }
        return false
    }

    private func iconName(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        return "doc"
    }

    private func sizeLabel(_ draft: AttachmentLibrary.Draft) -> String {
        // A remote host reference downloads nothing, so its size is unknown
        // by design — label it as a reference rather than showing a MIME type
        // that would imply uploaded content.
        if case .hostReference = draft.source { return "Host reference" }
        guard draft.byteCount > 0 else { return draft.mimeType }
        let size = draft.byteCount.formatted(.byteCount(style: .file))
        return "\(size) · \(draft.mimeType)"
    }
}
