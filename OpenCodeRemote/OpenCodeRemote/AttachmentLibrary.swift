import Foundation
import Observation
import OpenCodeDomain
import OpenCodeTransport
import PhotosUI
import SwiftUI
import UIKit

/// S09 attachment preparation (W08): the draft tray behind the composer's
/// chips. Each draft moves through honest states — preparing (reading/
/// deciding), uploading (staging on the host), ready (an inline `data:`
/// URI or a staged `file:` URI), failed (with retry/remove still offered).
/// The web inline/staging rule lives in `AttachmentRouter`; this library
/// never invents URIs and never sends an iOS sandbox path to a host.
///
/// Drafts survive failed staging (bytes kept for retry) and cancelled
/// uploads (failed with "Cancelled" — removable, retryable). Duplicate
/// picks and files over the warning threshold ask BEFORE routing; Send
/// waits while anything is pending.
@MainActor
@Observable
final class AttachmentLibrary {
    typealias CredentialProvider = @MainActor (HostID) -> BasicCredential?

    /// Photo copy modes (docs/implementation-defaults.md): Balanced fits
    /// to the 2048-pixel longest edge without upscaling (JPEG 0.85,
    /// alpha preserved as PNG); Original keeps the picked bytes as-is.
    enum PhotoCopy: String, CaseIterable, Identifiable {
        case original
        case balanced
        var id: String { rawValue }
        var label: String { self == .original ? "Original" : "Balanced" }
    }

    enum State: Equatable {
        case preparing
        case uploading
        case ready(staged: Bool, uri: String)
        case failed(String)
    }

    struct Draft: Identifiable {
        enum Source {
            case file(url: URL)
            case photo(PhotosPickerItem)
            case prepared(data: Data, mimeType: String)
        }

        let id = UUID()
        var name: String
        var mimeType: String
        var byteCount: Int
        var state: State = .preparing
        var source: Source
        /// Held while a confirmation is pending or staging failed — the
        /// only case a retry can re-route without re-reading the source.
        var bytes: Data?
        var isPhoto: Bool
        var photoMode: PhotoCopy = .balanced
        var task: Task<Void, Never>?
        /// Identity of the routing attempt in flight; a cancelled or
        /// superseded attempt's late completion lands nowhere.
        var routeToken: UUID?
    }

    /// A confirmation the user must answer before a pick is routed: over
    /// the warning threshold (never a hard limit), or already in the tray.
    struct PendingConfirmation: Identifiable, Equatable {
        enum Kind: Equatable {
            case oversized(byteCount: Int)
            case duplicate
        }

        let id: UUID
        let name: String
        var kind: Kind
    }

    /// Default copy mode for NEW photo/camera picks; each photo row can
    /// still override its own.
    var photoCopy: PhotoCopy = .balanced
    /// Photo/camera COPIES strip location metadata unless this is on —
    /// explicit per the defaults; originals are sent byte-for-byte.
    var includeLocation = false
    /// The implementation-defaults warning point — a confirmation the
    /// user answers, never a hard limit (adjustable when settings land).
    var warningThresholdBytes: Int = AttachmentRouter.warningThresholdBytes
    var pendingConfirmation: PendingConfirmation?

    private(set) var drafts: [Draft] = []
    var credentialProvider: CredentialProvider?

    /// The host's staging directory, fetched once per conversation —
    /// `paths.tmp` does not change mid-flight and every staged file
    /// after the first reuses it.
    private var cachedTmpDirectory: String?

    private let stager: AttachmentStager

    init(stager: AttachmentStager? = nil, credentialProvider: CredentialProvider? = nil) {
        self.stager = stager ?? AttachmentStager(makeTransport: { URLSessionTransport(baseURL: $0) })
        self.credentialProvider = credentialProvider
    }

    /// Same wiring as the other libraries: pull host credentials from the
    /// shared store unless the caller injected its own provider (tests).
    func attach(hosts: HostLibrary) {
        guard credentialProvider == nil else { return }
        credentialProvider = { [weak hosts] id in hosts?.credential(for: id) }
    }

    // MARK: - Adding picks

    func addPhotos(_ items: [PhotosPickerItem], host: OpenCodeDomain.Host) {
        for item in items {
            let draft = Draft(
                name: "Photo",
                mimeType: item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg",
                byteCount: 0,
                source: .photo(item),
                isPhoto: true,
                photoMode: photoCopy
            )
            drafts.append(draft)
            loadThenPrepare(draftID: draft.id, host: host)
        }
    }

    func addFiles(_ urls: [URL], host: OpenCodeDomain.Host) {
        for url in urls {
            let draft = Draft(
                name: url.lastPathComponent,
                mimeType: "application/octet-stream", // sniffed from the real bytes
                byteCount: 0,
                source: .file(url: url),
                isPhoto: false
            )
            drafts.append(draft)
            loadThenPrepare(draftID: draft.id, host: host)
        }
    }

    func addCameraImage(_ image: UIImage, host: OpenCodeDomain.Host) {
        // A camera capture has no on-disk original: the full-resolution
        // JPEG becomes the source the copy modes re-prepare from.
        guard let data = image.jpegData(compressionQuality: 1.0) else { return }
        let draft = Draft(
            name: "Photo \(Self.timestampName()).jpg",
            mimeType: "image/jpeg",
            byteCount: data.count,
            source: .prepared(data: data, mimeType: "image/jpeg"),
            isPhoto: true,
            photoMode: photoCopy
        )
        drafts.append(draft)
        start(draftID: draft.id, host: host, bytes: data, mimeType: "image/jpeg")
    }

    // MARK: - Tray operations

    func remove(_ draftID: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[index].task?.cancel()
        drafts[index].routeToken = nil
        drafts.remove(at: index)
        if pendingConfirmation?.id == draftID { pendingConfirmation = nil }
    }

    /// Cancelling an in-flight upload leaves an honest failed draft — the
    /// reference is preserved, never silently dropped.
    func cancel(_ draftID: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[index].task?.cancel()
        drafts[index].routeToken = nil
        if drafts[index].state == .uploading {
            drafts[index].state = .failed("Cancelled")
        }
    }

    func retry(_ draftID: UUID, host: OpenCodeDomain.Host) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }),
              case .failed = drafts[index].state else { return }
        drafts[index].state = .preparing
        if drafts[index].bytes != nil {
            // Staging failed with the bytes still held — re-route at once.
            route(draftID, host: host)
        } else {
            loadThenPrepare(draftID: draftID, host: host)
        }
    }

    /// Re-prepares a photo under its new copy mode (pipeline + routing
    /// run again; a staged original is re-staged).
    func setPhotoCopy(_ mode: PhotoCopy, for draftID: UUID, host: OpenCodeDomain.Host) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }),
              drafts[index].isPhoto, drafts[index].photoMode != mode else { return }
        drafts[index].photoMode = mode
        guard drafts[index].state != .uploading else { return } // never re-route mid-flight
        drafts[index].state = .preparing
        loadThenPrepare(draftID: draftID, host: host)
    }

    /// Answers the pending oversized/duplicate question: accepting routes
    /// the held bytes, declining removes the draft entirely.
    func answerConfirmation(_ accepted: Bool, host: OpenCodeDomain.Host) {
        guard let confirmation = pendingConfirmation else { return }
        pendingConfirmation = nil
        if accepted {
            route(confirmation.id, host: host)
        } else {
            remove(confirmation.id)
        }
    }

    // MARK: - Send integration

    /// True while anything is still preparing or uploading: Send waits
    /// for pending attachments rather than sending a partial draft.
    var hasPending: Bool {
        drafts.contains { if case .preparing = $0.state { return true }; if case .uploading = $0.state { return true }; return false }
    }

    /// The ready drafts as request DTOs, in tray order — the ONLY state
    /// that reaches a prompt; failed/missing references never ride along.
    func readyAttachments() -> [PromptFileAttachment] {
        drafts.compactMap { draft in
            guard case .ready(_, let uri) = draft.state else { return nil }
            return PromptFileAttachment(uri: uri, name: draft.name)
        }
    }

    /// Removes the drafts that were just admitted into a prompt — their
    /// content now lives in the conversation, not the tray.
    func consume(_ draftIDs: [UUID]) {
        drafts.removeAll { draftIDs.contains($0.id) }
    }

    // MARK: - Pipeline

    private func loadThenPrepare(draftID: UUID, host: OpenCodeDomain.Host) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        let source = drafts[index].source
        drafts[index].task = Task { [weak self] in
            do {
                let (bytes, sniffed) = try await Self.loadBytes(from: source)
                self?.start(draftID: draftID, host: host, bytes: bytes, mimeType: sniffed)
            } catch is CancellationError {
                // remove/cancel already decided the draft's fate.
            } catch {
                self?.fail(draftID, message: Self.readErrorMessage(for: error))
            }
        }
    }

    /// Runs the copy pipeline for photo drafts, then duplicate detection,
    /// the size warning, and the inline/stage routing decision.
    private func start(draftID: UUID, host: OpenCodeDomain.Host, bytes: Data, mimeType: String) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        var prepared = bytes
        var mime = mimeType
        if drafts[index].isPhoto {
            do {
                let result = try PhotoPreparation.prepare(
                    data: bytes, mode: drafts[index].photoMode, includeLocation: includeLocation
                )
                prepared = result.bytes
                mime = result.mimeType
            } catch {
                fail(draftID, message: "This photo could not be prepared.")
                return
            }
            if drafts[index].name == "Photo" {
                drafts[index].name = "Photo \(Self.timestampName()).\(mime == "image/png" ? "png" : "jpg")"
            }
        }
        drafts[index].mimeType = mime
        drafts[index].byteCount = prepared.count
        drafts[index].bytes = prepared

        // Duplicate detection: same name AND same size already in the tray.
        if drafts.contains(where: {
            $0.id != draftID && $0.name == drafts[index].name && $0.byteCount == prepared.count
        }) {
            pendingConfirmation = PendingConfirmation(
                id: draftID, name: drafts[index].name, kind: .duplicate
            )
            return
        }
        if prepared.count > warningThresholdBytes {
            pendingConfirmation = PendingConfirmation(
                id: draftID, name: drafts[index].name, kind: .oversized(byteCount: prepared.count)
            )
            return
        }
        route(draftID, host: host)
    }

    /// Applies the web rule: supported images/PDFs at or under the inline
    /// threshold become data URIs in the prompt; everything else is
    /// staged on the host under `paths.tmp` and referenced by file URI.
    private func route(_ draftID: UUID, host: OpenCodeDomain.Host) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }),
              let bytes = drafts[index].bytes else { return }
        let mime = drafts[index].mimeType
        if AttachmentRouter.shouldInline(mimeType: mime, byteCount: bytes.count) {
            drafts[index].state = .ready(
                staged: false, uri: AttachmentRouter.dataURI(mimeType: mime, bytes: bytes)
            )
            drafts[index].bytes = nil
            return
        }
        drafts[index].state = .uploading
        let token = UUID()
        drafts[index].routeToken = token
        drafts[index].task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let credential = credentialProvider?(host.id) else {
                    guard let live = drafts.firstIndex(where: { $0.id == draftID }),
                          drafts[live].routeToken == token else { return }
                    drafts[live].state = .failed("Re-pair this host to stage attachments.")
                    return
                }
                let tmp: String
                if let cached = cachedTmpDirectory {
                    tmp = cached
                } else {
                    tmp = try await stager.tmpDirectory(at: host.address, credential: credential)
                    cachedTmpDirectory = tmp
                }
                let uri = try await stager.stage(
                    at: host.address, credential: credential,
                    tmpDirectory: tmp, filename: drafts[index].name, bytes: bytes
                )
                guard let live = drafts.firstIndex(where: { $0.id == draftID }),
                      drafts[live].routeToken == token else { return } // cancelled/superseded
                drafts[live].state = .ready(staged: true, uri: uri)
                drafts[live].bytes = nil
            } catch is CancellationError {
                // cancel() already set the honest failed state.
            } catch {
                guard let live = drafts.firstIndex(where: { $0.id == draftID }),
                      drafts[live].routeToken == token else { return }
                drafts[live].state = .failed(Self.stageErrorMessage(for: error))
                // bytes are KEPT here — retry re-routes without re-reading.
            }
        }
    }

    private func fail(_ draftID: UUID, message: String) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[index].state = .failed(message)
    }

    // MARK: - Sources

    private static func loadBytes(from source: Draft.Source) async throws -> (Data, String) {
        switch source {
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            return (data, MimeType.sniff(data))
        case .photo(let item):
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "application/octet-stream"
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (data, MimeType.sniff(data))
        case .prepared(let data, let mimeType):
            return (data, mimeType)
        }
    }

    // MARK: - Messages

    /// "Unsupported" chips: honest labelling when the selected model
    /// cannot ingest the type natively — the host can still open a staged
    /// file through its tools; nothing here claims native ingestion.
    static func unsupportedReason(mimeType: String, inputCapabilities: Set<String>?) -> String? {
        guard let capabilities = inputCapabilities else { return nil }
        if mimeType.hasPrefix("image/"), !capabilities.contains("image") {
            return "The current model can’t read images directly — the host can still open it as a file."
        }
        if mimeType == "application/pdf", !capabilities.contains("pdf") {
            return "The current model can’t read PDFs directly — the host can still open it as a file."
        }
        return nil
    }

    private static func stageErrorMessage(for error: Error) -> String {
        switch error {
        case StagingError.noTmpDirectory:
            return "This host does not report a temp directory — attachments cannot be staged."
        case TransportError.http(let status, _):
            return "The host rejected the upload (HTTP \(status))."
        case TransportError.connectionFailed:
            return "Upload failed — the host may be unreachable."
        default:
            return "The upload failed."
        }
    }

    private static func readErrorMessage(for error: Error) -> String {
        switch error {
        case CocoaError.fileReadNoSuchFile, CocoaError.fileReadNoPermission:
            return "The file could not be read."
        case CocoaError.fileReadCorruptFile:
            return "This item could not be loaded."
        default:
            return "The file could not be read."
        }
    }

    private static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: Date())
    }
}
