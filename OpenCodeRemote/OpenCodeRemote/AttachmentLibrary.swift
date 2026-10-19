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
            /// S13 Attach-to-Draft: a remote host path referenced by a
            /// `file:` URI. The bytes live on the host — never downloaded,
            /// staged, or re-uploaded here (docs/api-contract.md W11).
            case hostReference(uri: String)
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
        /// The oversized question for this draft has already been
        /// answered with "send anyway" — the pre-read size check must
        /// not ask it a second time once the bytes are finally loaded.
        var oversizedAccepted = false
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
        /// Asked BEFORE any bytes were read (a picked FILE's size comes
        /// from metadata): accepting must start the read, not route
        /// bytes that do not exist yet.
        var preLoad = false
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

    /// Confirmations wait their turn: a multi-select can queue several
    /// oversized/duplicate questions and each must be answered — a
    /// second one may never overwrite the first (its draft would strand
    /// in preparing and gate Send forever). The head is what the UI
    /// presents; answering pops it and the next surfaces on its own.
    private var confirmationQueue: [PendingConfirmation] = []
    var pendingConfirmation: PendingConfirmation? { confirmationQueue.first }

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

    /// S13 Attach-to-Draft: adds a draft that is immediately `.ready` with a
    /// remote `file:` reference. No bytes are read, staged, or uploaded — the
    /// host resolves the path itself when the prompt is admitted. It never
    /// sends; the caller returns to the existing draft (docs/api-contract.md
    /// W11, navigation-screens.md S13).
    func addHostReference(hostAbsolutePath: String, name: String) {
        let uri = AttachmentRouter.fileURI(hostAbsolutePath: hostAbsolutePath)
        let draft = Draft(
            name: name,
            mimeType: "application/octet-stream", // the host resolves the real type
            byteCount: 0,
            state: .ready(staged: false, uri: uri),
            source: .hostReference(uri: uri),
            isPhoto: false
        )
        drafts.append(draft)
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
        // JPEG becomes the source the copy modes re-prepare from. The
        // encode runs off the main actor like the rest of the pipeline —
        // a full-resolution capture is hundreds of milliseconds of CPU.
        Task { [weak self] in
            guard let data = await Self.cameraJPEG(image) else { return }
            guard let self else { return }
            let draft = Draft(
                name: "Photo \(Self.timestampName()).jpg",
                mimeType: "image/jpeg",
                byteCount: data.count,
                source: .prepared(data: data, mimeType: "image/jpeg"),
                isPhoto: true,
                photoMode: photoCopy
            )
            drafts.append(draft)
            loadThenPrepare(draftID: draft.id, host: host)
        }
    }

    // MARK: - Tray operations

    func remove(_ draftID: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[index].task?.cancel()
        drafts[index].routeToken = nil
        drafts.remove(at: index)
        confirmationQueue.removeAll { $0.id == draftID }
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
        // Supersede the preparation in flight: loadThenPrepare REPLACES
        // the task reference, so without this both tasks run — each
        // reaches start(...) and route(...) and prepares the same photo
        // twice; for a staged photo that is also TWO uploads, and the
        // routeToken check discards only the first upload's result, not
        // its transfer.
        drafts[index].task?.cancel()
        drafts[index].routeToken = nil
        drafts[index].state = .preparing
        // A question asked about the PREVIOUS copy no longer applies —
        // and if the new mode needs no question, `start` routes directly
        // and the stale one would later re-route a ready draft (a second
        // staged upload) or Cancel would remove a good draft. `enqueue`
        // removes same-id entries itself, so the re-prepare can safely
        // re-ask if it still needs to.
        confirmationQueue.removeAll { $0.id == draftID }
        loadThenPrepare(draftID: draftID, host: host)
    }

    /// Answers the confirmation that is ON SCREEN: accepting routes the
    /// held bytes (or, for a pre-load oversized answer — a picked FILE's
    /// size was asked from metadata before any read — starts the read),
    /// declining removes THAT draft. `enqueue` orders by PICK, so a
    /// newly finished pick can insert ahead of a live alert and the
    /// queue head is not always what the sequencer presents: keying the
    /// answer to the presented entry means a superseded question
    /// (re-prepared or removed meanwhile) is never answered by silently
    /// consuming its neighbour's.
    func answerConfirmation(
        _ answered: PendingConfirmation, accepted: Bool, host: OpenCodeDomain.Host
    ) {
        guard let index = confirmationQueue.firstIndex(where: { $0.id == answered.id }) else { return }
        let confirmation = confirmationQueue.remove(at: index)
        if accepted, confirmation.preLoad {
            guard let draftIndex = drafts.firstIndex(where: { $0.id == confirmation.id }) else { return }
            drafts[draftIndex].oversizedAccepted = true
            loadThenPrepare(draftID: confirmation.id, host: host)
        } else if accepted {
            route(confirmation.id, host: host)
        } else {
            remove(confirmation.id)
        }
    }

    private func enqueue(_ confirmation: PendingConfirmation) {
        confirmationQueue.removeAll { $0.id == confirmation.id }
        // Pick order, not completion order: reads run off the main actor and
        // two picks can finish out of sequence — but the questions must
        // surface in the order the user chose the files (drafts preserves
        // pick order).
        let position = drafts.firstIndex { $0.id == confirmation.id } ?? Int.max
        let insertion = confirmationQueue.firstIndex { queued in
            (drafts.firstIndex { draft in draft.id == queued.id } ?? Int.max) > position
        } ?? confirmationQueue.endIndex
        confirmationQueue.insert(confirmation, at: insertion)
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
        // A picked FILE's size is known from metadata before any read:
        // the 50 MB warning is explicitly "not a hard limit", and loading
        // a multi-gigabyte pick just to ask about it can get the app
        // terminated for memory first. Photos keep their
        // post-preparation check — their size only exists once
        // re-encoded. An unreadable size falls through to the normal
        // read path and warns afterwards, exactly as before.
        if case .file(let url) = source, !drafts[index].oversizedAccepted,
           let size = Self.fileSize(of: url), size > warningThresholdBytes {
            drafts[index].byteCount = size
            enqueue(PendingConfirmation(
                id: draftID, name: drafts[index].name,
                kind: .oversized(byteCount: size), preLoad: true
            ))
            return
        }
        drafts[index].task = Task { [weak self] in
            do {
                let (bytes, sniffed) = try await Self.loadBytes(from: source)
                // A cancel can land while loading (remove, cancel, or a
                // setPhotoCopy superseding this draft) and loadBytes never
                // observes it itself — Data(contentsOf:) is synchronous and
                // loadTransferable does not contract for cancellation — so
                // without this check the cancelled task would still run the
                // whole pipeline and route (duplicating a staged upload).
                try Task.checkCancellation()
                if let self, let draft = self.drafts.first(where: { $0.id == draftID }),
                   draft.isPhoto {
                    // The copy pipeline is the same class of CPU-bound
                    // work as the read above, so it runs off the main
                    // actor too (ImageIO decode, 2048px thumbnail, the
                    // JPEG/PNG encode). A mode change cancels THIS task
                    // and re-prepares under the new mode.
                    let result = try await Self.preparePhoto(
                        bytes, mode: draft.photoMode, includeLocation: self.includeLocation
                    )
                    try Task.checkCancellation()
                    self.start(draftID: draftID, host: host, bytes: result.bytes, mimeType: result.mimeType)
                } else {
                    self?.start(draftID: draftID, host: host, bytes: bytes, mimeType: sniffed)
                }
            } catch is CancellationError {
                // remove/cancel/setPhotoCopy already decided the draft's fate.
            } catch is PhotoPreparation.PipelineError {
                self?.fail(draftID, message: "This photo could not be prepared.")
            } catch {
                self?.fail(draftID, message: Self.readErrorMessage(for: error))
            }
        }
    }

    /// Receives FINAL (already-prepared) bytes: duplicate detection, the
    /// size warning, and the inline/stage routing decision. Photo copies
    /// are prepared off the main actor in `loadThenPrepare` — only the
    /// picker-photo extension claim stays here (it needs MainActor state).
    private func start(draftID: UUID, host: OpenCodeDomain.Host, bytes: Data, mimeType: String) {
        guard let index = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        if drafts[index].isPhoto, drafts[index].name == "Photo" {
            // Extension follows the REAL prepared bytes: balanced mode
            // always re-encodes to png/jpeg, but original mode returns the
            // picked bytes untouched and MimeType.sniff has no HEIC case —
            // falling back to jpg would name HEIC bytes .jpg.
            let ext: String
            switch mimeType {
            case "image/png": ext = "png"
            case "image/jpeg": ext = "jpg"
            default:
                if case .photo(let item) = drafts[index].source,
                   let picked = item.supportedContentTypes.first?.preferredFilenameExtension {
                    ext = picked
                } else {
                    ext = "bin"
                }
            }
            drafts[index].name = "Photo \(Self.timestampName()).\(ext)"
        }
        drafts[index].mimeType = mimeType
        drafts[index].byteCount = bytes.count
        drafts[index].bytes = bytes

        // Duplicate detection: same name AND same size already in the tray.
        if drafts.contains(where: {
            $0.id != draftID && $0.name == drafts[index].name && $0.byteCount == bytes.count
        }) {
            enqueue(PendingConfirmation(
                id: draftID, name: drafts[index].name, kind: .duplicate
            ))
            return
        }
        // Pre-read oversized questions already cleared this draft; only
        // sources whose size was never asked about (photos, prepared
        // data, unstattable files) get the question here — after the
        // bytes exist, which `answerConfirmation` can then route.
        if bytes.count > warningThresholdBytes, !drafts[index].oversizedAccepted {
            enqueue(PendingConfirmation(
                id: draftID, name: drafts[index].name, kind: .oversized(byteCount: bytes.count)
            ))
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
        // Captured BEFORE the task starts: the tray can shrink (remove/
        // consume) during any await, so an index read after suspension
        // could name another draft or run out of bounds.
        let filename = drafts[index].name
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
                    tmpDirectory: tmp, filename: filename, bytes: bytes
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

    /// Off the main actor, like `loadBytes`: the copy pipeline decodes
    /// the full image, builds the 2048-pixel thumbnail and JPEG/PNG
    /// encodes it — hundreds of milliseconds per pick that would freeze
    /// the UI on the caller's actor. The result returns to the caller's
    /// isolation at the `await`.
    nonisolated private static func preparePhoto(
        _ data: Data, mode: PhotoCopy, includeLocation: Bool
    ) async throws -> (bytes: Data, mimeType: String) {
        try PhotoPreparation.prepare(data: data, mode: mode, includeLocation: includeLocation)
    }

    /// Off the main actor for the same reason: encoding a
    /// full-resolution camera capture to JPEG is CPU-bound.
    nonisolated private static func cameraJPEG(_ image: UIImage) async -> Data? {
        image.jpegData(compressionQuality: 1.0)
    }

    /// The picked FILE's size straight from metadata — no bytes read.
    /// nil when the URL cannot be stat'd (the caller then falls back to
    /// the full read and warns afterwards, exactly as before).
    nonisolated private static func fileSize(of url: URL) -> Int? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Off the main actor: a picked file can be far larger than the 50 MB
    /// warning (which is explicitly "not a hard limit"), and this
    /// synchronous read would otherwise block the UI for its whole
    /// duration. The result returns to the caller's isolation at the
    /// `await`.
    nonisolated private static func loadBytes(from source: Draft.Source) async throws -> (Data, String) {
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
        case .hostReference:
            // A remote reference is never read here — the host resolves the
            // path when the prompt is admitted. Reaching this path would be a
            // routing bug, so fail honestly rather than invent bytes.
            throw CocoaError(.fileWriteInvalidFileName)
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
