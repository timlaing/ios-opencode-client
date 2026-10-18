import PhotosUI
import UIKit
import XCTest
@testable import OpenCodeRemote
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// W08 attachment preparation tests: the inline rule at pick time,
/// host staging with honest failure/cancel/duplicate/warning states,
/// and the send-integration surface (ready attachments + consume).
@MainActor
final class AttachmentLibraryTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [APIRequest] = []
        func record(_ request: APIRequest) { lock.lock(); recorded.append(request); lock.unlock() }
        var requests: [APIRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    }

    private struct StubTransport: OpenCodeTransport {
        var recorder: Recorder
        var handler: @Sendable (APIRequest) throws -> APIResponse
        var hook: (@Sendable (APIRequest) async -> Void)?

        func perform(_ request: APIRequest) async throws -> APIResponse {
            recorder.record(request)
            await hook?(request)
            return try handler(request)
        }

        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Handler responses that tests can swap mid-flight (retry cases).
    private final class MutableResponses: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Result<APIResponse, TransportError>] = [:]

        func set(_ operation: String, _ result: Result<APIResponse, TransportError>) {
            lock.lock(); storage[operation] = result; lock.unlock()
        }

        func get(_ operation: String) -> Result<APIResponse, TransportError>? {
            lock.lock(); defer { lock.unlock() }
            return storage[operation]
        }
    }

    /// A one-shot async gate: `wait()` suspends until `signal()`, so a
    /// test can hold one request in flight and interleave other calls.
    private actor Latch {
        private var continuation: CheckedContinuation<Void, Never>?
        private var hasArrived = false
        private var hasResumed = false

        func wait() async {
            hasArrived = true
            if hasResumed { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func signal() {
            hasResumed = true
            continuation?.resume()
            continuation = nil
        }

        var isArrived: Bool { hasArrived }
    }

    private nonisolated static func json(_ body: String, status: Int = 200) -> APIResponse {
        APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
    }

    private let infoJSON = #"{"version":"2.0.25","pid":0,"urls":[],"paths":{"tmp":"/tmp/opencode-mock"}}"#
    private nonisolated static func writeJSON(path: String) -> String {
        #"{"location":{"directory":"/tmp/opencode-mock"},"data":{"path":"\#(path)"}}"#
    }

    private let host = OpenCodeDomain.Host(
        id: HostID(rawValue: "host_one"),
        displayName: "Mock A",
        address: URL(string: "http://host_one.local:4097")!,
        createdAt: Date(timeIntervalSince1970: 0),
        lastVersion: nil
    )

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryFiles = []
        super.tearDown()
    }

    private func writeTempFile(bytes: Data, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try bytes.write(to: url)
        temporaryFiles.append(url)
        return url
    }

    /// A tiny but real PNG header so magic-byte sniffing sees image/png.
    private var smallPNG: Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x01, count: 64)
    }

    private func makeLibrary(
        recorder: Recorder = Recorder(),
        responses: MutableResponses = MutableResponses(),
        credential: BasicCredential? = BasicCredential(secret: "t"),
        hook: (@Sendable (APIRequest) async -> Void)? = nil
    ) -> AttachmentLibrary {
        responses.set("server.info", .success(Self.json(infoJSON)))
        let transport = StubTransport(
            recorder: recorder,
            handler: { request in
                if request.operationID == "experimental.fs.write",
                   responses.get(request.operationID) == nil {
                    // The host echoes its RESOLVED path — like the
                    // reference mock, which writes nothing for real.
                    let path = request.query.first(where: { $0.key == "path" })?.value ?? "/tmp/unknown"
                    return Self.json(Self.writeJSON(path: path))
                }
                guard let result = responses.get(request.operationID) else {
                    throw TransportError.connectionFailed("unstubbed \(request.operationID)")
                }
                return try result.get()
            },
            hook: hook
        )
        let stager = AttachmentStager(makeTransport: { _ in transport })
        let provider: AttachmentLibrary.CredentialProvider?
        if let credential {
            provider = { _ in credential }
        } else {
            provider = nil
        }
        return AttachmentLibrary(stager: stager, credentialProvider: provider)
    }

    private func waitUntilReady(_ library: AttachmentLibrary, index: Int = 0) async throws {
        for _ in 0..<100 {
            if case .ready = library.drafts[index].state { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("draft never became ready: \(library.drafts[index].state)")
    }

    // MARK: - Routing

    func testSmallImageInlinesWithoutTouchingTheHost() async throws {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder)
        let url = try writeTempFile(bytes: smallPNG, name: "diagram.png")

        library.addFiles([url], host: host)
        try await waitUntilReady(library)

        guard case .ready(let staged, let uri) = library.drafts[0].state else {
            return XCTFail("expected ready")
        }
        XCTAssertFalse(staged, "a supported image under the threshold rides INLINE")
        XCTAssertTrue(uri.hasPrefix("data:image/png;base64,"), "sniffed from the real bytes")
        XCTAssertEqual(library.drafts[0].name, "diagram.png")
        XCTAssertTrue(
            recorder.requests.isEmpty,
            "inline attachments never contact the host — no info, no staging"
        )
    }

    func testOtherContentStagesOnTheHostAndGetsAFileURI() async throws {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder)
        let url = try writeTempFile(bytes: Data("hello staging".utf8), name: "notes.txt")

        library.addFiles([url], host: host)
        try await waitUntilReady(library)

        guard case .ready(let staged, let uri) = library.drafts[0].state else {
            return XCTFail("expected ready")
        }
        XCTAssertTrue(staged, "non-inline content is staged on the host")
        XCTAssertTrue(uri.hasPrefix("file:///tmp/opencode-mock/uploads/"), "a host file URI under paths.tmp")
        XCTAssertTrue(uri.hasSuffix("/notes.txt"), "named after the attachment")

        XCTAssertEqual(recorder.requests.map(\.operationID), ["server.info", "experimental.fs.write"])
        let write = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(
            write.query.first(where: { $0.key == "location[directory]" })?.value,
            "/tmp/opencode-mock", "staging writes under the host's paths.tmp"
        )
    }

    // MARK: - Failure, retry, credential

    func testStagingFailureKeepsDraftAndRetrySucceeds() async throws {
        let recorder = Recorder()
        let responses = MutableResponses()
        let library = makeLibrary(recorder: recorder, responses: responses)
        responses.set("experimental.fs.write", .failure(.http(status: 500, envelope: nil)))
        let url = try writeTempFile(bytes: Data("hello staging".utf8), name: "notes.txt")

        library.addFiles([url], host: host)
        for _ in 0..<100 {
            if case .failed = library.drafts[0].state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .failed(let message) = library.drafts[0].state else {
            return XCTFail("expected failed state")
        }
        XCTAssertEqual(message, "The host rejected the upload (HTTP 500).")
        XCTAssertNotNil(library.drafts[0].bytes, "failed staging keeps the bytes for retry")

        // The host recovers; retry re-routes WITHOUT re-reading the file.
        responses.set("experimental.fs.write", .success(Self.json(Self.writeJSON(path: "/tmp/opencode-mock/uploads/UUID-2/notes.txt"))))
        library.retry(library.drafts[0].id, host: host)
        try await waitUntilReady(library)
        guard case .ready(let staged, let uri) = library.drafts[0].state else {
            return XCTFail("expected ready after retry")
        }
        XCTAssertTrue(staged)
        XCTAssertEqual(uri, "file:///tmp/opencode-mock/uploads/UUID-2/notes.txt")
        XCTAssertEqual(
            recorder.requests.filter { $0.operationID == "server.info" }.count, 1,
            "the retry re-stages from held bytes — no new info lookup"
        )
    }

    func testMissingCredentialFailsHonestly() async throws {
        let library = makeLibrary(credential: nil)
        let url = try writeTempFile(bytes: Data("hello staging".utf8), name: "notes.txt")

        library.addFiles([url], host: host)
        for _ in 0..<100 {
            if case .failed = library.drafts[0].state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .failed(let message) = library.drafts[0].state else {
            return XCTFail("expected failed state")
        }
        XCTAssertEqual(message, "Re-pair this host to stage attachments.")
    }

    // MARK: - Cancel

    func testCancelDuringUploadLeavesFailedDraftAndIgnoresLateSuccess() async throws {
        let gate = Latch()
        let library = makeLibrary(hook: { request in
            if request.operationID == "experimental.fs.write" {
                await gate.wait()
            }
        })
        let url = try writeTempFile(bytes: Data("hello staging".utf8), name: "notes.txt")

        library.addFiles([url], host: host)
        for _ in 0..<100 {
            if case .uploading = library.drafts[0].state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            library.drafts.first.map { if case .uploading = $0.state { return true }; return false },
            true, "the draft is staging when it can be cancelled"
        )

        library.cancel(library.drafts[0].id)
        guard case .failed(let message) = library.drafts[0].state else {
            return XCTFail("cancelled upload must show an honest failed state")
        }
        XCTAssertEqual(message, "Cancelled")
        XCTAssertNotNil(library.drafts[0].bytes, "a cancelled draft stays retryable")

        // The host's answer arrives AFTER the cancel — it must land nowhere.
        await gate.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .failed(let stillMessage) = library.drafts[0].state else {
            return XCTFail("the late staging success must be discarded")
        }
        XCTAssertEqual(stillMessage, "Cancelled")
    }

    // MARK: - Confirmations

    func testOversizedFileAsksBeforeRouting() async throws {
        let library = makeLibrary()
        library.warningThresholdBytes = 10
        let url = try writeTempFile(bytes: Data("twenty bytes of file!!".utf8), name: "big.bin")

        library.addFiles([url], host: host)
        try await Task.sleep(nanoseconds: 100_000_000)

        let confirmation = try XCTUnwrap(library.pendingConfirmation)
        XCTAssertEqual(confirmation.kind, .oversized(byteCount: 22))
        XCTAssertEqual(library.drafts.count, 1, "the draft waits, un-routed")

        library.answerConfirmation(true, host: host)
        XCTAssertNil(library.pendingConfirmation)
        try await waitUntilReady(library)
        guard case .ready(let staged, _) = library.drafts[0].state else {
            return XCTFail("accepted warning routes the draft")
        }
        XCTAssertTrue(staged, "over the inline threshold, so staged")
    }

    func testDeclinedWarningRemovesTheDraft() async throws {
        let library = makeLibrary()
        library.warningThresholdBytes = 10
        let url = try writeTempFile(bytes: Data("twenty bytes of file!!".utf8), name: "big.bin")

        library.addFiles([url], host: host)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(library.pendingConfirmation != nil, true)

        library.answerConfirmation(false, host: host)
        XCTAssertTrue(library.drafts.isEmpty, "declining removes the draft entirely")
        XCTAssertNil(library.pendingConfirmation)
    }

    func testDuplicatePickAsksAndDeclineKeepsOne() async throws {
        let library = makeLibrary()
        let url = try writeTempFile(bytes: smallPNG, name: "diagram.png")

        library.addFiles([url], host: host)
        try await waitUntilReady(library)

        library.addFiles([url], host: host)
        try await Task.sleep(nanoseconds: 100_000_000)
        let confirmation = try XCTUnwrap(library.pendingConfirmation)
        XCTAssertEqual(confirmation.kind, .duplicate)

        library.answerConfirmation(false, host: host)
        XCTAssertEqual(library.drafts.count, 1, "declining keeps exactly the original")
        XCTAssertNil(library.pendingConfirmation)
    }

    func testConfirmationsQueueAndNeverStrandADraft() async throws {
        let library = makeLibrary()
        library.warningThresholdBytes = 10
        let first = try writeTempFile(bytes: Data("first oversized pick".utf8), name: "one.bin")
        let second = try writeTempFile(bytes: Data("second oversized pick".utf8), name: "two.bin")

        library.addFiles([first, second], host: host)
        try await Task.sleep(nanoseconds: 150_000_000)

        let head = try XCTUnwrap(library.pendingConfirmation)
        XCTAssertEqual(head.name, "one.bin", "the first question surfaces first")
        XCTAssertEqual(library.drafts.count, 2, "neither draft is lost while the queue waits")

        library.answerConfirmation(true, host: host)
        let next = try XCTUnwrap(library.pendingConfirmation)
        XCTAssertEqual(next.name, "two.bin",
                       "answering one surfaces the next — a second question never overwrites the first")

        library.answerConfirmation(true, host: host)
        XCTAssertNil(library.pendingConfirmation)
        for _ in 0..<100 {
            if !library.hasPending { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(library.hasPending, "every queued draft routed — none stranded in preparing")
        XCTAssertEqual(library.drafts.map(\.name), ["one.bin", "two.bin"])
    }

    func testTrayChangesMidUploadNeverRenameTheStagingDraft() async throws {
        let gate = Latch()
        let library = makeLibrary(hook: { request in
            if request.operationID == "experimental.fs.write" {
                await gate.wait()
            }
        })
        let image = try writeTempFile(bytes: smallPNG, name: "diagram.png")
        let document = try writeTempFile(bytes: Data("staged doc".utf8), name: "report.txt")

        library.addFiles([image, document], host: host)
        // The image inlines instantly (index 0); the document is staging
        // under an index that removing the first draft shifts.
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .ready = library.drafts[0].state else {
            return XCTFail("the inline draft settles first")
        }
        library.remove(library.drafts[0].id)
        XCTAssertEqual(library.drafts.map(\.name), ["report.txt"])

        await gate.signal()
        try await Task.sleep(nanoseconds: 100_000_000)

        guard case .ready(let staged, let uri) = library.drafts[0].state else {
            return XCTFail("the staged draft completes under its own identity")
        }
        XCTAssertTrue(staged)
        XCTAssertTrue(uri.hasSuffix("/report.txt"), "the upload kept ITS filename after the tray shrank")
    }

    // MARK: - Send integration

    func testReadyAttachmentsConsumeAndPendingGate() async throws {
        let library = makeLibrary()
        let image = try writeTempFile(bytes: smallPNG, name: "diagram.png")
        let document = try writeTempFile(bytes: Data("staged doc".utf8), name: "doc.txt")

        library.addFiles([image, document], host: host)
        XCTAssertTrue(library.hasPending, "preparing drafts gate Send")

        for _ in 0..<100 {
            if !library.hasPending { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(library.hasPending, "settled drafts release Send")

        let attachments = library.readyAttachments()
        XCTAssertEqual(attachments.map(\.name), ["diagram.png", "doc.txt"], "tray order is preserved")
        XCTAssertTrue(attachments[0].uri.hasPrefix("data:image/png;base64,"))
        XCTAssertTrue(attachments[1].uri.hasPrefix("file:///tmp/opencode-mock/uploads/"))
        XCTAssertTrue(attachments[1].uri.hasSuffix("/doc.txt"))

        library.consume([library.drafts[0].id])
        XCTAssertEqual(library.drafts.map(\.name), ["doc.txt"], "admitted content leaves the tray")
        XCTAssertEqual(library.readyAttachments().map(\.name), ["doc.txt"])
    }

    // MARK: - S13 Attach-to-Draft

    func testAddHostReferenceIsReadyAtOnceAndSendsNothing() {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder)

        library.addHostReference(hostAbsolutePath: "/srv/demo/src/main.swift", name: "main.swift")

        XCTAssertEqual(library.drafts.count, 1)
        XCTAssertEqual(library.drafts[0].name, "main.swift")
        XCTAssertEqual(library.drafts[0].byteCount, 0, "no bytes are read — the bytes live on the host")
        guard case .ready(let staged, let uri) = library.drafts[0].state else {
            return XCTFail("a host reference must be ready immediately: \(library.drafts[0].state)")
        }
        XCTAssertFalse(staged, "nothing was staged or uploaded")
        XCTAssertEqual(uri, "file:///srv/demo/src/main.swift", "host absolute path, percent-encoded")
        guard case .hostReference(let source) = library.drafts[0].source else {
            return XCTFail("source must record the host reference for re-routing honesty")
        }
        XCTAssertEqual(source, uri, "state and source carry the same reference")
        XCTAssertTrue(recorder.requests.isEmpty, "attach must perform no request — the host resolves on admission")
        XCTAssertFalse(library.hasPending, "an instantly-ready reference never gates Send")
    }

    // MARK: - S13 Attach-to-Draft

    func testHostReferenceIsReadyImmediatelyWithoutTouchingTheHost() {
        let recorder = Recorder()
        let library = makeLibrary(recorder: recorder)

        library.addHostReference(hostAbsolutePath: "/srv/demo/src/main.swift", name: "main.swift")

        XCTAssertEqual(library.drafts.count, 1)
        XCTAssertEqual(recorder.requests.isEmpty, true,
                       "a host reference never reads, stages, or uploads — the host resolves it at admission")

        let draft = library.drafts[0]
        XCTAssertEqual(draft.name, "main.swift")
        XCTAssertEqual(draft.byteCount, 0, "no bytes are read client-side")
        XCTAssertEqual(draft.state, .ready(staged: false, uri: "file:///srv/demo/src/main.swift"),
                       "immediately ready with a percent-escaped file: URI")
        guard case .hostReference(let uri) = draft.source else {
            return XCTFail("source must record the remote reference, not a local file")
        }
        XCTAssertEqual(uri, "file:///srv/demo/src/main.swift")
    }

    // MARK: - Capability labels

    func testUnsupportedReasonFollowsModelInputCapabilities() {
        XCTAssertEqual(
            AttachmentLibrary.unsupportedReason(mimeType: "image/png", inputCapabilities: ["text"]),
            "The current model can’t read images directly — the host can still open it as a file."
        )
        XCTAssertNil(AttachmentLibrary.unsupportedReason(mimeType: "image/png", inputCapabilities: ["text", "image"]))
        XCTAssertNil(AttachmentLibrary.unsupportedReason(mimeType: "image/png", inputCapabilities: nil),
                     "unknown capabilities never invent a limitation")
        XCTAssertNil(AttachmentLibrary.unsupportedReason(mimeType: "application/zip", inputCapabilities: ["text"]),
                     "non-native types are host-file territory, not model ingestion")
        XCTAssertNotNil(AttachmentLibrary.unsupportedReason(mimeType: "application/pdf", inputCapabilities: ["text"]))
    }
}

/// Photo pipeline tests (implementation defaults): Balanced downscales
/// without upscaling and re-encodes; Original is byte-for-byte.
final class PhotoPreparationTests: XCTestCase {
    private func renderedPNG(width: Int, height: Int) throws -> Data {
        // Opaque at scale 1, like a photograph — pixels are the points,
        // and the balanced copy should pick JPEG.
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }

    func testBalancedCopyDownscalesAndReencodes() throws {
        let original = try renderedPNG(width: 3000, height: 600)

        let result = try PhotoPreparation.prepare(data: original, mode: .balanced, includeLocation: false)

        XCTAssertEqual(result.mimeType, "image/jpeg", "opaque photographic images re-encode as JPEG")
        XCTAssertNotEqual(result.bytes, original, "the copy is re-encoded, not passed through")
        // The balanced copy must decode to at most 2048 on its longest edge.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.bytes as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(max(width, height), 2048, "longest edge fits 2048 without upscaling")
    }

    func testOriginalModeReturnsBytesUntouched() throws {
        let original = try renderedPNG(width: 300, height: 200)

        let result = try PhotoPreparation.prepare(data: original, mode: .original, includeLocation: false)

        XCTAssertEqual(result.bytes, original, "Original mode is byte-for-byte as picked")
        XCTAssertEqual(result.mimeType, "image/png", "sniffed from the real bytes")
    }

    func testCopiesBakeTheOrientationIntoThePixels() throws {
        // A landscape sensor buffer tagged .right — a portrait shot.
        let landscape = try renderedPNG(width: 400, height: 200)
        let source = try XCTUnwrap(UIImage(data: landscape))
        let portrait = UIImage(cgImage: try XCTUnwrap(source.cgImage), scale: 1, orientation: .right)

        let result = try PhotoPreparation.prepare(image: portrait, mode: .balanced, includeLocation: false)

        let copy = try XCTUnwrap(UIImage(data: result.bytes))
        XCTAssertEqual(copy.imageOrientation, .up, "the copy carries no orientation tag to misread")
        XCTAssertEqual(Int(copy.size.width), 200, "the .right orientation is baked into the pixels")
        XCTAssertEqual(Int(copy.size.height), 400)
    }

    func testMimeTypeSniffing() {
        XCTAssertEqual(MimeType.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(MimeType.sniff(Data([0x89, 0x50, 0x4E, 0x47])), "image/png")
        XCTAssertEqual(MimeType.sniff(Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(MimeType.sniff(Data("%PDF-1.7".utf8)), "application/pdf")
        XCTAssertEqual(MimeType.sniff(Data("RIFF____WEBPVP8".utf8)), "image/webp")
        XCTAssertEqual(MimeType.sniff(Data("plain text".utf8)), "application/octet-stream",
                       "unknown content never pretends to be a native type")
    }
}
