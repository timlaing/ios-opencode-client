import XCTest
import OpenCodeDomain
import OpenCodeTransport
@testable import OpenCodeRemote

/// W14 integrations state (S16, docs/api-contract.md W14): the effective
/// inventory combines the RUNTIME plugins with the DECLARED directives,
/// and a toggle is a PLAN over the raw JSONC bytes — read, edit,
/// compare-latest-read, write, `location.reload`, authoritative
/// readback. A failed or invalidated plan claims nothing.
@MainActor
final class IntegrationsLibraryTests: XCTestCase {
    /// Non-isolated fixtures: transport handlers run off the main actor.
    private enum Fixtures {
        static func response(_ body: String, status: Int = 200) -> APIResponse {
            APIResponse(statusCode: status, payload: .json(Data(body.utf8)))
        }

        static func file(_ text: String) -> APIResponse {
            APIResponse(statusCode: 200, payload: .bytes(Data(text.utf8)))
        }

        static let noContent = APIResponse(statusCode: 204, payload: .empty)

        /// Runtime inventory with the audit package active plus a
        /// built-in (protected by host policy).
        static let pluginList = #"{"location":{"directory":"/srv/demo"},"data":[{"id":"demo.audit","source":{"type":"package","target":"demo.audit","version":"1.0.0"},"features":{"server":true},"state":{"status":"active"}},{"source":{"type":"builtin"},"features":{},"state":{"status":"active"}}]}"#

        /// The mock's own semantics: a negatively-declared plugin is
        /// filtered OUT of the runtime inventory.
        static let emptyPluginList = #"{"location":{"directory":"/srv/demo"},"data":[]}"#

        /// config.get answers with a BARE array; the document declares
        /// one positive and one negative directive.
        static let configWithDirectives = #"[{"type":"document","path":"/srv/demo/opencode.jsonc","info":{"plugins":["demo.audit","-old.pkg"]}},{"type":"directory","path":"/srv/demo/.opencode"}]"#

        /// After the negative is removed the readback config no longer
        /// declares the target at all.
        static let configAfterEnable = #"[{"type":"document","path":"/srv/demo/opencode.jsonc","info":{"plugins":[]}}]"#

        /// The project document's raw JSONC bytes.
        static let documentBytes = #"{"plugins": ["-demo.audit", "keep.pkg"]}"#

        /// The plan's resulting text: only the negative directive and
        /// its comma are gone — every other byte survives.
        static let documentAfterEnable = #"{"plugins": [ "keep.pkg"]}"#

        /// Runtime inventory whose package id DIFFERS from its source
        /// target — the schema guarantees no relationship between
        /// them, so the row join must not assume one.
        static let pluginListIDDiffers = #"{"location":{"directory":"/srv/demo"},"data":[{"id":"pkg-123","source":{"type":"package","target":"demo.audit","version":"1.0.0"},"features":{"server":true},"state":{"status":"active"}}]}"#

        /// The host answers under a DIFFERENT location than the one
        /// the session asked for.
        static let pluginListOtherLocation = #"{"location":{"directory":"/srv/other"},"data":[]}"#

        /// The session's own document declares nothing; a LATER,
        /// higher-precedence document under the same directory holds
        /// the negative — a toggle can only ever write the FIRST
        /// document under the directory (the editable one).
        static let configNegativeElsewhere = #"[{"type":"document","path":"/srv/demo/opencode.jsonc","info":{"plugins":[]}},{"type":"document","path":"/srv/demo/.opencode/workspace.jsonc","info":{"plugins":["-demo.audit"]}}]"#

        /// Two id-less plugins of the SAME constant-keyed kind: their
        /// synthetic runtime keys must not collide, or the second
        /// overwrites the first row and the inspector hides a
        /// host-provided plugin.
        static let pluginListTwoBuiltins = #"{"location":{"directory":"/srv/demo"},"data":[{"source":{"type":"builtin"},"features":{"server":true},"state":{"status":"active"}},{"source":{"type":"builtin"},"features":{"tui":true},"state":{"status":"active"}}]}"#

        /// The host normalises the location it answers for (a trailing
        /// slash): the SAME directory — accepted, never a mismatch.
        static let pluginListTrailingSlash = #"{"location":{"directory":"/srv/demo/"},"data":[{"id":"demo.audit","source":{"type":"package","target":"demo.audit","version":"1.0.0"},"features":{"server":true},"state":{"status":"active"}}]}"#

        /// A NEW project's document (W02 writes `{}`) carries NO
        /// plugins array, while a document ELSEWHERE declares the
        /// target positive — Disable would be offered for a directive
        /// it could never write. (config.get is a bare array.)
        static let configSessionDocEmpty = #"[{"type":"document","path":"/srv/demo/opencode.jsonc","info":{}},{"type":"document","path":"/srv/shared/plugins.jsonc","info":{"plugins":["demo.audit"]}}]"#

        /// The standard W15 MCP inventory: one connected server and
        /// one requiring host-side sign-in (the mock's vocabulary).
        static let mcpList = #"{"location":{"directory":"/srv/demo"},"data":[{"name":"demo-docs","status":{"status":"connected"}},{"name":"demo-auth","status":{"status":"needs_auth","error":"Synthetic sign-in required"}}]}"#

        /// The same inventory before a connect took effect:
        /// demo-docs is runtime-disabled, so its row offers Connect.
        static let mcpListDisabled = #"{"location":{"directory":"/srv/demo"},"data":[{"name":"demo-docs","status":{"status":"disabled"}}]}"#

        /// The inventory after a connect took effect.
        static let mcpListConnected = #"{"location":{"directory":"/srv/demo"},"data":[{"name":"demo-docs","status":{"status":"connected"}}]}"#

        /// The MCP inventory answered under a DIFFERENT location than
        /// the session asked for — refused fail-closed like plugins.
        static let mcpListOtherLocation = #"{"location":{"directory":"/srv/other"},"data":[]}"#

        /// config.get's document declares demo-docs DISABLED through
        /// the baseline `mcp.servers.<name>` shape (Config.InfoEncoded
        /// allows no other nesting) — the configured-intent line
        /// joins it with the runtime status, kept separate.
        static let configWithMcpServer = #"[{"type":"document","path":"/srv/demo/opencode.jsonc","info":{"mcp":{"servers":{"demo-docs":{"type":"local","command":["docs"],"disabled":true}}}}}]"#
    }

    /// Captured-var mutation is not allowed in `@Sendable` handlers.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [APIRequest] = []
        func record(_ request: APIRequest) {
            lock.lock(); recorded.append(request); lock.unlock()
        }
        var requests: [APIRequest] {
            lock.lock(); defer { lock.unlock() }; return recorded
        }
    }

    /// A one-shot flip for handlers that must behave differently across
    /// awaited calls.
    private final class Flip: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool {
            lock.lock(); defer { lock.unlock() }
            let wasFirst = !done
            done = true
            return wasFirst
        }
    }

    /// A credential that can vanish between plan and apply — the
    /// keychain item deleted mid-flow, which is the only way
    /// `applyToggle` (already holding a plan) can meet a missing
    /// credential.
    private final class CredentialGate: @unchecked Sendable {
        private let lock = NSLock()
        private var present = true
        func setPresent(_ value: Bool) {
            lock.lock(); present = value; lock.unlock()
        }
        var isPresent: Bool {
            lock.lock(); defer { lock.unlock() }; return present
        }
    }

    /// A call counter (0-based) for readback-phase stubs.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            defer { value += 1 }
            return value
        }
    }

    private struct StubTransport: OpenCodeTransport {
        var recorder: Recorder
        var handler: @Sendable (APIRequest) async throws -> APIResponse

        func perform(_ request: APIRequest) async throws -> APIResponse {
            recorder.record(request)
            return try await handler(request)
        }

        func events() -> AsyncThrowingStream<OpenCodeEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func host(_ id: String, name: String) -> OpenCodeDomain.Host {
        OpenCodeDomain.Host(
            id: HostID(rawValue: id),
            displayName: name,
            address: URL(string: "http://\(id).local:4097")!,
            createdAt: Date(timeIntervalSince1970: 0),
            lastVersion: nil
        )
    }

    private func library(
        recorder: Recorder,
        handler: @escaping @Sendable (APIRequest) async throws -> APIResponse,
        credentials: [String: BasicCredential?] = ["host_one": BasicCredential(secret: "t")]
    ) -> IntegrationsLibrary {
        library(recorder: recorder, handler: handler) { id in credentials[id.rawValue] ?? nil }
    }

    private func library(
        recorder: Recorder,
        handler: @escaping @Sendable (APIRequest) async throws -> APIResponse,
        provider: @escaping @MainActor (HostID) -> BasicCredential?
    ) -> IntegrationsLibrary {
        // W15: `mcp.list` joins every inventory read. The wrapper
        // delegates FIRST: a test that stubs `mcp.list` itself wins,
        // and only the shared "unstubbed" convention gets the standard
        // two-server fixture — a DELIBERATE mcp.list failure (any
        // other error) still propagates to the test.
        let wrapped: @Sendable (APIRequest) async throws -> APIResponse = { request in
            do {
                return try await handler(request)
            } catch TransportError.connectionFailed(let reason)
                where reason.hasPrefix("unstubbed") && request.operationID == "mcp.list" {
                return Fixtures.response(Fixtures.mcpList)
            }
        }
        let stub: @Sendable () -> StubTransport = { StubTransport(recorder: recorder, handler: wrapped) }
        return IntegrationsLibrary(
            service: IntegrationsService(makeTransport: { _ in stub() }),
            projectService: ProjectService(makeTransport: { _ in stub() }),
            credentialProvider: provider
        )
    }

    private let one = OpenCodeDomain.Host(
        id: HostID(rawValue: "host_one"),
        displayName: "One",
        address: URL(string: "http://host_one.local:4097")!,
        createdAt: Date(timeIntervalSince1970: 0),
        lastVersion: nil
    )

    // MARK: - Load

    func testLoadBuildsEffectiveRowsFromRuntimeAndDeclarations() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load(host: one, sessionDirectory: "/srv/demo")

        XCTAssertNil(library.loadError)
        XCTAssertEqual(
            library.editableDocument?.path, "/srv/demo/opencode.jsonc",
            "the session's own document is the editable one"
        )
        XCTAssertEqual(library.editableDocument?.relativePath, "opencode.jsonc")
        XCTAssertEqual(
            Set(recorder.requests.map(\.operationID)),
            ["plugin.list", "config.get", "mcp.list"]
        )
        // The runtime inventory is requested FOR THE SESSION'S
        // LOCATION — combining another scope's runtime with these
        // directives would render half-truth rows.
        let pluginRequest = recorder.requests.first { $0.operationID == "plugin.list" }
        XCTAssertEqual(
            pluginRequest?.query.first { $0.key == "location[directory]" }?.value, "/srv/demo"
        )
        // …AND SO ARE THE CONFIG DOCUMENTS: unscoped, the host answers
        // its default location's documents, which may not live under
        // the session's directory (the inventory would then be paired
        // with another scope's directives).
        let configRequest = recorder.requests.first { $0.operationID == "config.get" }
        XCTAssertEqual(
            configRequest?.query.first { $0.key == "location[directory]" }?.value, "/srv/demo"
        )
        // …AND SO IS THE MCP INVENTORY: same scope, same location
        // equality rule (W15 — all three routes declare the query).
        let mcpRequest = recorder.requests.first { $0.operationID == "mcp.list" }
        XCTAssertEqual(
            mcpRequest?.query.first { $0.key == "location[directory]" }?.value, "/srv/demo"
        )

        // Declared positive + running: active with its declared scope.
        let audit = library.rows.first { $0.id == "demo.audit" }
        XCTAssertEqual(audit?.target, "demo.audit")
        XCTAssertEqual(audit?.statusText, "Active")
        XCTAssertEqual(audit?.declaredInPaths, ["/srv/demo/opencode.jsonc"])
        XCTAssertEqual(audit?.canDisable, true)
        XCTAssertNotNil(audit?.runtime, "the runtime facts join the declared ones")

        // Declared negative + absent from runtime: disabled in config,
        // never merely "missing".
        let old = library.rows.first { $0.id == "old.pkg" }
        XCTAssertEqual(old?.statusText, "Disabled in config")
        XCTAssertEqual(old?.canEnable, true, "the negative directive is what enable removes")

        // Built-in: protected, never offers a disable.
        let builtin = library.rows.first { $0.id == "built-in" }
        XCTAssertEqual(builtin?.isProtected, true)
        XCTAssertEqual(builtin?.canDisable, false)
        XCTAssertTrue(builtin?.statusText.contains("(protected)") ?? false)
    }

    func testLoadWithoutCredentialReportsRePairAndSendsNoRequest() async {
        let recorder = Recorder()
        let library = library(recorder: recorder, handler: { _ in
            XCTFail("no request may be sent without a credential")
            return Fixtures.noContent
        }, credentials: [:])

        await library.load(host: one, sessionDirectory: "/srv/demo")

        XCTAssertEqual(library.loadError, "Re-pair this host to read its integrations.")
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testLoadWithoutSessionDirectoryOffersNoToggle() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load(host: one, sessionDirectory: nil)

        XCTAssertNil(library.editableDocument)
        // No document exists that planToggle could write, so NEITHER
        // toggle may be offered: an action that could only fail is
        // never shown (the Disable side of the canEnable rule).
        let audit = library.rows.first { $0.id == "demo.audit" }
        XCTAssertEqual(audit?.canDisable, false, "nothing could be written to")
        XCTAssertEqual(audit?.canEnable, false)
        await library.planToggle(host: one, target: "demo.audit", enable: false)
        XCTAssertEqual(
            library.toggleError,
            "This location reports no editable configuration document."
        )
        XCTAssertFalse(recorder.requests.contains { $0.operationID == "fs.read" })
    }

    /// Disable requires the editable document to CARRY a plugins
    /// array: W02 writes new projects' opencode.jsonc as `{}` and the
    /// splice never CREATES the key, so an offered Disable could only
    /// fail with "…or declares no plugins directives."
    func testDisableIsNotOfferedWhenTheEditableDocumentHasNoPluginsArray() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configSessionDocEmpty)
            case "fs.read": return Fixtures.file("{}")
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load(host: one, sessionDirectory: "/srv/demo")

        // Declared positive by the SHARED document and running — but
        // the session's own document is `{}`: nothing Disable could
        // ever write.
        let audit = library.rows.first { $0.id == "demo.audit" }
        XCTAssertEqual(audit?.statusText, "Active")
        XCTAssertEqual(
            audit?.canDisable, false,
            "the editable document has no plugins array to edit"
        )
        XCTAssertEqual(audit?.canEnable, false)

        await library.planToggle(host: one, target: "demo.audit", enable: false)
        XCTAssertEqual(
            library.toggleError,
            "The document already disables \"demo.audit\" or declares no plugins directives."
        )
    }

    // MARK: - Plan

    func testPlanToggleReadsTheDocumentAndPlansTheExactEdit() async throws {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        await library.planToggle(host: one, target: "demo.audit", enable: true)

        XCTAssertNil(library.toggleError)
        let plan = try XCTUnwrap(library.pendingPlan)
        XCTAssertEqual(plan.enable, true)
        XCTAssertEqual(plan.resultingText, Fixtures.documentAfterEnable)
        XCTAssertEqual(
            plan.description, "Remove \"-demo.audit\" from the plugins directives."
        )
        // The document is read location-relative: directory in the
        // query, the relative path in the URL itself (`fs.read` builds
        // /api/fs/read/<path>, never a `path` query key).
        let read = recorder.requests.first { $0.operationID == "fs.read" }
        XCTAssertEqual(read?.query.first { $0.key == "location[directory]" }?.value, "/srv/demo")
        XCTAssertEqual(read?.path, "/api/fs/read/opencode.jsonc")
    }

    func testPlanToggleReportsHonestlyWhenThereIsNothingToChange() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        // Nothing negative exists to remove.
        await library.planToggle(host: one, target: "keep.pkg", enable: true)
        XCTAssertEqual(
            library.toggleError,
            "No \"-keep.pkg\" directive exists to remove."
        )
        XCTAssertNil(library.pendingPlan)
    }

    // MARK: - Apply

    func testApplyToggleComparesWritesReloadsAndReadsBack() async throws {
        let recorder = Recorder()
        let runtimeCalls = Counter()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list":
                // First load: filtered out (negative directive);
                // readback: the host now runs it.
                return Fixtures.response(
                    runtimeCalls.next() == 0 ? Fixtures.emptyPluginList : Fixtures.pluginList
                )
            case "config.get":
                return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read":
                return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write":
                return Fixtures.noContent
            case "location.reload":
                return Fixtures.noContent
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)

        await library.applyToggle(host: one, plan: plan)

        XCTAssertNil(library.pendingPlan)
        XCTAssertNil(library.toggleError)
        XCTAssertEqual(
            library.notice, "Saved — the host reloaded the location.",
            "the readback runtime shows the plugin running — the change is in effect"
        )
        XCTAssertTrue(library.unreflected.isEmpty)

        let ids = recorder.requests.map(\.operationID)
        XCTAssertEqual(ids.filter { $0 == "fs.read" }.count, 2, "plan read + compare-latest-read")
        let writeIndex = try XCTUnwrap(ids.firstIndex(of: "experimental.fs.write"))
        let reloadIndex = try XCTUnwrap(ids.firstIndex(of: "location.reload"))
        XCTAssertLessThan(writeIndex, reloadIndex, "the location reloads AFTER the bytes land")
        let write = recorder.requests[writeIndex]
        XCTAssertEqual(write.body, Data(Fixtures.documentAfterEnable.utf8))
        XCTAssertEqual(
            write.query.first { $0.key == "path" }?.value, "/srv/demo/opencode.jsonc",
            "fs.write takes the ABSOLUTE document path"
        )
        XCTAssertEqual(
            Set(ids.suffix(3)), ["plugin.list", "config.get", "mcp.list"],
            "the authoritative readback follows the reload"
        )
    }

    func testApplyToggleAbortsWhenTheDocumentChangedUnderThePlan() async throws {
        let recorder = Recorder()
        let flip = Flip()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read":
                // The plan is computed against the first read; the
                // compare-latest read answers differently.
                return Fixtures.file(
                    flip.first() ? Fixtures.documentBytes : #"{"plugins": ["other"]}"#
                )
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)

        await library.applyToggle(host: one, plan: plan)

        XCTAssertNil(library.pendingPlan, "an invalidated plan is discarded")
        XCTAssertEqual(
            library.notice,
            "The document changed on the host — review the current plugins directives and retry."
        )
        let ids = recorder.requests.map(\.operationID)
        XCTAssertFalse(ids.contains("experimental.fs.write"), "nothing is written on a mismatch")
        XCTAssertFalse(ids.contains("location.reload"), "no reload follows an aborted plan")
    }

    func testApplyToggleExposesAnIneffectiveOverride() async throws {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list":
                // The readback still does NOT run the plugin — the
                // saved directive is not (yet) in effect.
                return Fixtures.response(Fixtures.emptyPluginList)
            case "config.get":
                return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write", "location.reload":
                return Fixtures.noContent
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)

        await library.applyToggle(host: one, plan: plan)

        XCTAssertNil(library.toggleError, "the save itself succeeded")
        XCTAssertEqual(library.unreflected, ["demo.audit"])
        XCTAssertEqual(
            library.notice,
            "Saved, but the host's runtime inventory has not applied it yet."
        )
    }

    func testApplyToggleRejectsWhenTheCredentialDisappearsAfterPlanning() async throws {
        let recorder = Recorder()
        let gate = CredentialGate()
        let library = library(
            recorder: recorder,
            handler: { request in
                switch request.operationID {
                case "plugin.list": return Fixtures.response(Fixtures.pluginList)
                case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
                case "fs.read": return Fixtures.file(Fixtures.documentBytes)
                default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
                }
            },
            provider: { _ in gate.isPresent ? BasicCredential(secret: "t") : nil }
        )
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        XCTAssertNotNil(library.pendingPlan, "the plan exists while the credential does")
        let plan = try XCTUnwrap(library.pendingPlan)

        gate.setPresent(false) // the keychain item is deleted mid-flow
        await library.applyToggle(host: one, plan: plan)

        XCTAssertEqual(library.toggleError, "Re-pair this host to change plugins.")
        XCTAssertEqual(
            library.pendingPlan?.target, "demo.audit",
            "nothing was written — the plan survives for a retry after re-pairing"
        )
        let ids = recorder.requests.map(\.operationID)
        XCTAssertFalse(ids.contains("experimental.fs.write"))
        XCTAssertFalse(ids.contains("location.reload"))
    }

    // MARK: - Review-round fixes

    /// The confirmation dialog clears `pendingPlan` through its
    /// isPresented setter the moment it dismisses — BEFORE the Apply
    /// button's Task runs (the alert hazard documented in
    /// ConversationView). The plan therefore travels into applyToggle
    /// BY VALUE, and a cleared state must not stop the write.
    func testApplyToggleUsesTheCapturedPlanAfterDismissalClearsTheState() async throws {
        let recorder = Recorder()
        let runtimeCalls = Counter()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list":
                return Fixtures.response(
                    runtimeCalls.next() == 0 ? Fixtures.emptyPluginList : Fixtures.pluginList
                )
            case "config.get":
                return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write", "location.reload":
                return Fixtures.noContent
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)

        // The dismissal write lands before the Task — exactly what the
        // dialog's setter does.
        library.cancelPendingPlan()
        XCTAssertNil(library.pendingPlan)

        await library.applyToggle(host: one, plan: plan)

        XCTAssertNil(library.toggleError)
        XCTAssertEqual(library.notice, "Saved — the host reloaded the location.")
        XCTAssertTrue(
            recorder.requests.contains { $0.operationID == "experimental.fs.write" },
            "the captured plan still writes the document"
        )
        XCTAssertNil(library.pendingPlan)
    }

    /// id and source.target are independent schema fields: when they
    /// differ, the runtime plugin must still join its DECLARED row by
    /// the package target — one truth must not become two half-truths
    /// (declared-not-running beside active-without-toggle), and the
    /// raw runtime id must never stand alone as a row.
    func testRuntimeJoinsDeclaredRowsByPackageTargetWhenIDDiffers() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginListIDDiffers)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load(host: one, sessionDirectory: "/srv/demo")

        XCTAssertEqual(library.rows.count, 2, "declared pair only — the runtime id adds no row")
        let audit = library.rows.first { $0.id == "demo.audit" }
        XCTAssertNotNil(
            audit?.runtime,
            "the package runtime joins the row declared under its source target"
        )
        XCTAssertEqual(audit?.statusText, "Active")
        XCTAssertEqual(audit?.canDisable, true)
        XCTAssertNil(library.rows.first { $0.id == "pkg-123" })
    }

    /// The host answers the inventory under a DIFFERENT location than
    /// the session's: combining those runtime facts with the session's
    /// directives would render half-truth rows, so the load refuses.
    func testLoadRefusesARuntimeInventoryFromAnotherLocation() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginListOtherLocation)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load(host: one, sessionDirectory: "/srv/demo")

        XCTAssertEqual(
            library.loadError,
            "The host reports its plugins for a different location than this session's directory."
        )
        XCTAssertTrue(library.rows.isEmpty, "no rows are built from mismatched scopes")
    }

    /// The write LANDED when the reload fails: the notice must never
    /// report the save as failed — the change is on disk, merely
    /// unapplied, and stays visible as such.
    func testApplyToggleReloadFailureReportsSavedNotApplied() async throws {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write": return Fixtures.noContent
            case "location.reload": throw TransportError.http(status: 500, envelope: nil)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)

        await library.applyToggle(host: one, plan: plan)

        XCTAssertNil(library.toggleError, "the save itself succeeded")
        XCTAssertEqual(library.notice, "Saved, but the host could not reload the location.")
        XCTAssertEqual(library.unreflected, ["demo.audit"], "an unapplied change stays visible")
        XCTAssertNil(library.pendingPlan, "the plan is spent — the bytes are on the host")
        XCTAssertTrue(recorder.requests.contains { $0.operationID == "experimental.fs.write" })
    }

    /// Write and reload succeed, but the readback READ fails: the
    /// outcome is UNKNOWN — never "not saved", and "not applied" is
    /// equally over-claimed.
    func testApplyToggleReadbackFailureReportsSavedUnverified() async throws {
        let recorder = Recorder()
        let runtimeCalls = Counter()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list":
                // Load: inventory answers. Readback: the read fails.
                if runtimeCalls.next() == 0 {
                    return Fixtures.response(Fixtures.pluginList)
                }
                throw TransportError.http(status: 500, envelope: nil)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write", "location.reload":
                return Fixtures.noContent
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)

        await library.applyToggle(host: one, plan: plan)

        XCTAssertNil(library.toggleError, "the save itself succeeded")
        XCTAssertEqual(
            library.notice, "Saved, but the host's runtime inventory could not be read."
        )
        XCTAssertFalse(
            library.unreflected.contains("demo.audit"),
            "unknown is not \"not applied\" — the marker claims a fact we do not have"
        )
    }

    /// The negative directive lives ONLY in a document the toggle
    /// cannot edit — the row keeps its "disabled by directive" facts
    /// but never offers an Enable that could only fail.
    func testEnableIsOfferedOnlyWhenTheEditableDocumentHoldsTheNegative() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.emptyPluginList)
            case "config.get": return Fixtures.response(Fixtures.configNegativeElsewhere)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load(host: one, sessionDirectory: "/srv/demo")

        let row = library.rows.first { $0.id == "demo.audit" }
        XCTAssertEqual(row?.disabledInPaths, ["/srv/demo/.opencode/workspace.jsonc"])
        XCTAssertEqual(row?.statusText, "Disabled in config", "the directive facts stay visible")
        XCTAssertEqual(
            row?.canEnable, false,
            "planToggle writes only /srv/demo/opencode.jsonc — it could never remove this directive"
        )
    }

    // MARK: - Load generation vs the authoritative readback

    /// A refresh held open across the write must not overwrite the
    /// readback: the readback supersedes in-flight loads, so the
    /// stale pre-write inventory lands nowhere (the user would
    /// otherwise see "Declared, not running" rows beside a
    /// "Saved — the host reloaded the location." notice).
    func testReadbackSupersedesAnInFlightLoad() async throws {
        let recorder = Recorder()
        let runtimeCalls = Counter()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list":
                let call = runtimeCalls.next() // 0-based
                if call == 1 {
                    // The in-flight refresh: held open across the write
                    // and the readback, then answering with its
                    // PRE-write snapshot.
                    enteredContinuation.yield()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    return Fixtures.response(Fixtures.emptyPluginList)
                }
                // Call 0 (the completed first load) is pre-write; every
                // later call — the readback among them — is post-write.
                return Fixtures.response(
                    call == 0 ? Fixtures.emptyPluginList : Fixtures.pluginList
                )
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write", "location.reload":
                return Fixtures.noContent
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        // The refresh starts and is held at its inventory read.
        let stale = Task { await library.load(host: one, sessionDirectory: "/srv/demo") }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)
        await library.applyToggle(host: one, plan: plan)

        // The superseded refresh finishes LAST, carrying pre-write rows.
        await stale.value

        let row = library.rows.first { $0.id == "demo.audit" }
        XCTAssertNotNil(
            row?.runtime,
            "the superseded refresh's pre-write inventory must not overwrite the readback"
        )
        XCTAssertEqual(row?.statusText, "Active")
        XCTAssertEqual(library.notice, "Saved — the host reloaded the location.")
    }

    // MARK: - Synthetic runtime keys

    /// Id-less plugins of the same constant kind share ONE runtimeKey:
    /// without per-occurrence keys the second built-in overwrites the
    /// first row and the inspector (S16: show the effective inventory)
    /// hides a host-provided plugin.
    func testTwoIdlessBuiltinsAreTwoRows() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginListTwoBuiltins)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load(host: one, sessionDirectory: "/srv/demo")

        XCTAssertEqual(
            library.rows.count, 4,
            "declared demo.audit + old.pkg, plus one row per id-less built-in"
        )
        let synthetic = library.rows.filter { $0.id.hasPrefix("built-in") }
        XCTAssertEqual(
            synthetic.map(\.id), ["built-in", "built-in#2"],
            "the first occurrence keeps the base key (declared joins); later ones uniquify"
        )
        XCTAssertEqual(synthetic.first?.runtime?.features.server, true)
        XCTAssertEqual(
            synthetic.last?.runtime?.features.tui, true,
            "each row carries ITS plugin's runtime facts"
        )
    }

    // MARK: - Location equality (api-contract W14)

    /// A host that answers the SAME directory written with a trailing
    /// slash is normalised, not refused — only genuinely different
    /// (or enclosing/nested) locations show the scope mismatch.
    func testANormalisedTrailingSlashAnswerIsTheSameLocation() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginListTrailingSlash)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }

        await library.load(host: one, sessionDirectory: "/srv/demo")

        XCTAssertNil(library.loadError, "normalisation must not read as a scope mismatch")
        XCTAssertEqual(library.rows.first { $0.id == "demo.audit" }?.statusText, "Active")
    }

    // MARK: - Unknown write outcome (api-contract W14)

    /// A connection failure DURING the write has an UNKNOWN outcome —
    /// the bytes may already be on the host. Claiming "not saved"
    /// would send the user re-planning against a document that may
    /// already carry the change, so the app reports the unknown and
    /// drops the plan (it may already describe the change).
    func testAConnectionFailureDuringTheWriteReportsUnknownOutcome() async throws {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write":
                throw TransportError.connectionFailed("dropped mid-save")
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)

        await library.applyToggle(host: one, plan: plan)

        XCTAssertEqual(
            library.toggleError,
            "The connection dropped during the save — pull to refresh to see whether the change landed."
        )
        XCTAssertNil(
            library.pendingPlan,
            "the plan may already describe the change — the next attempt must re-read and re-plan"
        )
        XCTAssertNil(
            library.notice,
            "nothing is known to be saved when the write outcome is unknown"
        )
    }

    /// A write whose RESPONSE cannot be used (malformed body) is
    /// response-less for the caller: the bytes may have landed, so it
    /// reports the unknown outcome and drops the plan — never "could
    /// not be saved".
    func testAnUnusableWriteResponseReportsUnknownOutcomeAndDropsThePlan() async throws {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write":
                throw TransportError.decodingFailed("write response was not decodable")
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)

        await library.applyToggle(host: one, plan: plan)

        XCTAssertEqual(
            library.toggleError,
            "The connection dropped during the save — pull to refresh to see whether the change landed."
        )
        XCTAssertNil(
            library.pendingPlan,
            "an unknown outcome must not leave a plan that may already be applied"
        )
    }

    /// A cancelled write claims NOTHING (silent by convention) but
    /// still drops the plan: its outcome is unknown like every other
    /// response-less write failure.
    func testACancelledWriteDropsThePlanWithoutClaimingAnything() async throws {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write":
                throw TransportError.cancelled
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)

        await library.applyToggle(host: one, plan: plan)

        XCTAssertNil(library.toggleError, "a cancellation claims nothing")
        XCTAssertNil(
            library.pendingPlan,
            "…but the plan must not survive an unknown outcome"
        )
    }

    // MARK: - Banner ownership across applies

    /// A new apply owns BOTH banners: the view renders notice and
    /// toggleError independently, so an earlier "Saved" beside an
    /// unknown write outcome would contradict the W14 rule (a stale
    /// error beside a later "Saved, but…" would too).
    func testANewApplyClearsStaleBanners() async throws {
        let recorder = Recorder()
        let writeCalls = Counter()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "location.reload": return Fixtures.noContent
            case "experimental.fs.write":
                if writeCalls.next() == 0 { return Fixtures.noContent }
                throw TransportError.connectionFailed("dropped mid-save")
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        // First apply: full success — the banner carries "Saved".
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let firstPlan = try XCTUnwrap(library.pendingPlan)
        await library.applyToggle(host: one, plan: firstPlan)
        XCTAssertEqual(library.notice, "Saved — the host reloaded the location.")
        XCTAssertNil(library.toggleError)

        // Second apply: the write drops — the stale "Saved" must not
        // sit beside the unknown outcome. (The stub filesystem keeps
        // answering the ORIGINAL bytes, so `keep.pkg` is still
        // declared positive and disable plans cleanly.)
        await library.planToggle(host: one, target: "keep.pkg", enable: false)
        let secondPlan = try XCTUnwrap(library.pendingPlan)
        await library.applyToggle(host: one, plan: secondPlan)
        XCTAssertNil(library.notice, "the earlier outcome must not contradict this one")
        XCTAssertEqual(
            library.toggleError,
            "The connection dropped during the save — pull to refresh to see whether the change landed."
        )
        XCTAssertNil(library.pendingPlan)
    }

    // MARK: - W15 MCP runtime controls

    /// Row controls appear only for statuses a runtime control can
    /// move: a definite Connect/Disconnect target, never while the
    /// host is mid-work, never for a server needing sign-in, never
    /// for a status this baseline cannot label.
    func testMcpRowControlsAppearOnlyForMovableStatuses() {
        func row(_ status: McpStatus) -> IntegrationsLibrary.McpRow {
            IntegrationsLibrary.McpRow(name: "x", status: status, configuredDisabled: nil)
        }
        XCTAssertTrue(row(McpStatus(rawKind: "disabled")).canConnect)
        XCTAssertTrue(row(McpStatus(rawKind: "failed", error: "boom")).canConnect)
        XCTAssertFalse(row(McpStatus(rawKind: "pending")).canConnect)
        XCTAssertFalse(row(McpStatus(rawKind: "connected")).canConnect)
        XCTAssertFalse(row(McpStatus(rawKind: "needs_auth")).canConnect)
        XCTAssertFalse(
            row(McpStatus(rawKind: "teleported")).canConnect,
            "an unknown status gets no control — it could only misfire"
        )
        XCTAssertTrue(row(McpStatus(rawKind: "connected")).canDisconnect)
        XCTAssertFalse(row(McpStatus(rawKind: "pending")).canDisconnect)
        XCTAssertFalse(row(McpStatus(rawKind: "teleported")).canDisconnect)
    }

    /// Load joins the runtime MCP inventory with the configured
    /// intent, kept as SEPARATE facts — a connected server declared
    /// disabled in config shows both truths; a `needs_auth` server
    /// offers no toggle (sign-in runs on the host) and names its
    /// status detail.
    func testLoadBuildsMcpRowsSeparatingIntentFromRuntimeStatus() async throws {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithMcpServer)
            case "mcp.list": return Fixtures.response(Fixtures.mcpList)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        XCTAssertNil(library.loadError)
        XCTAssertEqual(library.mcpRows.map(\.id), ["demo-docs", "demo-auth"])

        let connected = try XCTUnwrap(library.mcpRows.first { $0.id == "demo-docs" })
        XCTAssertEqual(connected.statusText, "Connected")
        XCTAssertEqual(
            connected.intentText, "Declared DISABLED in this location's configuration.",
            "the configured intent never merges into the runtime status"
        )
        XCTAssertTrue(connected.canDisconnect)
        XCTAssertFalse(connected.canConnect, "a connected server offers Disconnect, never Connect")

        let auth = try XCTUnwrap(library.mcpRows.first { $0.id == "demo-auth" })
        XCTAssertEqual(auth.statusText, "Needs authentication: Synthetic sign-in required")
        XCTAssertNil(auth.configuredDisabled, "nothing here declares it")
        XCTAssertEqual(
            auth.intentText, "Not declared in this location's configuration.",
            "absence of a declaration is never presented as 'declared disabled'"
        )
        XCTAssertFalse(auth.canConnect, "needs_auth gets NO success toggle")
        XCTAssertFalse(auth.canDisconnect)
    }

    /// Connect is a RUNTIME control: the 204 is admission only and
    /// the row shows the REFETCHED status; both routes carry the
    /// session's location query (W15 scope).
    func testMcpConnectShowsOnlyTheRefetchedStatus() async {
        let recorder = Recorder()
        let mcpCalls = Counter()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list":
                return Fixtures.response(
                    mcpCalls.next() == 0 ? Fixtures.mcpListDisabled : Fixtures.mcpListConnected
                )
            case "experimental.mcp.connect": return Fixtures.noContent
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        XCTAssertEqual(library.mcpRows.first?.status.kind, .disabled)
        XCTAssertEqual(library.mcpRows.first?.canConnect, true, "disabled rows offer Connect")

        await library.mcpAction(
            host: one, server: "demo-docs", connect: true, sessionDirectory: "/srv/demo"
        )

        XCTAssertEqual(library.notice, "The host now reports \"demo-docs\" as connected.")
        XCTAssertNil(library.toggleError)
        XCTAssertEqual(
            library.mcpRows.first?.status.kind, .connected,
            "the row shows the REFETCHED status, never the 204"
        )
        XCTAssertNil(library.mcpActionServer, "the pending marker is spent when the action ends")
        XCTAssertFalse(library.isToggling)

        let connect = recorder.requests.first { $0.operationID == "experimental.mcp.connect" }
        XCTAssertEqual(
            connect?.query.first { $0.key == "location[directory]" }?.value, "/srv/demo",
            "the control is scoped to the session's location like every W15 route"
        )
    }

    /// The host ADMITS the connect (204) but its refetched inventory
    /// still reports the old status — the outcome is "accepted, not
    /// applied", never success (docs/api-contract.md W15 admission
    /// rule).
    func testMcpConnectAdmittedButNotAppliedNeverClaimsSuccess() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list": return Fixtures.response(Fixtures.mcpListDisabled)
            case "experimental.mcp.connect": return Fixtures.noContent
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        await library.mcpAction(
            host: one, server: "demo-docs", connect: true, sessionDirectory: "/srv/demo"
        )

        XCTAssertEqual(
            library.notice,
            "The host accepted the change, but still reports \"demo-docs\" as Disabled."
        )
        XCTAssertNil(library.toggleError, "the admission itself did not fail")
        XCTAssertEqual(library.mcpRows.first?.status.kind, .disabled)
    }

    /// The disconnect counterpart: runtime control, location-scoped,
    /// and the row shows the refetched (now disabled) status.
    func testMcpDisconnectRunsTheRuntimeControlWithItsLocation() async {
        let recorder = Recorder()
        let mcpCalls = Counter()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list":
                return Fixtures.response(
                    mcpCalls.next() == 0 ? Fixtures.mcpList : Fixtures.mcpListDisabled
                )
            case "experimental.mcp.disconnect": return Fixtures.noContent
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        await library.mcpAction(
            host: one, server: "demo-docs", connect: false, sessionDirectory: "/srv/demo"
        )

        XCTAssertEqual(library.notice, "The host now reports \"demo-docs\" as disabled.")
        XCTAssertEqual(library.mcpRows.first?.status.kind, .disabled)
        let disconnect = recorder.requests.first { $0.operationID == "experimental.mcp.disconnect" }
        XCTAssertEqual(
            disconnect?.query.first { $0.key == "location[directory]" }?.value, "/srv/demo"
        )
    }

    /// A response-less connect failure is UNKNOWN — but the refresh
    /// that follows answers it: the refetched inventory shows the
    /// change landed, so the banner reports that truth instead of
    /// claiming either way from the lost response.
    func testMcpConnectResponseLessFailureIsAnsweredByTheRefresh() async {
        let recorder = Recorder()
        let mcpCalls = Counter()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list":
                return Fixtures.response(
                    mcpCalls.next() == 0 ? Fixtures.mcpListDisabled : Fixtures.mcpListConnected
                )
            case "experimental.mcp.connect":
                throw TransportError.connectionFailed("dropped after the request body")
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        await library.mcpAction(
            host: one, server: "demo-docs", connect: true, sessionDirectory: "/srv/demo"
        )

        XCTAssertEqual(
            library.notice, "The host now reports \"demo-docs\" as connected.",
            "fresh evidence replaces the unknown outcome with what the host reports"
        )
        XCTAssertNil(library.toggleError)
        XCTAssertEqual(library.mcpRows.first?.status.kind, .connected)
    }

    /// …and when the refresh shows the change did NOT take effect,
    /// the banner says exactly that — the refreshed inventory's
    /// evidence, not a guess.
    func testMcpConnectResponseLessFailureWithUnchangedHostSaysWhatIsKnown() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list": return Fixtures.response(Fixtures.mcpListDisabled)
            case "experimental.mcp.connect":
                throw TransportError.connectionFailed("dropped after the request body")
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        await library.mcpAction(
            host: one, server: "demo-docs", connect: true, sessionDirectory: "/srv/demo"
        )

        XCTAssertEqual(
            library.toggleError,
            "The connection dropped during the MCP change — the host does not report \"demo-docs\" as connected; it shows Disabled."
        )
        XCTAssertNil(library.notice)
        XCTAssertEqual(library.mcpRows.first?.status.kind, .disabled)
    }

    /// The server vanished between render and tap (404): the failed
    /// action REFRESHES the list and the message says so — the stale
    /// row is replaced by whatever the host reports now.
    func testMcpConnectToAServerTheHostNoLongerReportsRefreshesTheList() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list": return Fixtures.response(Fixtures.mcpList)
            case "experimental.mcp.connect":
                throw TransportError.http(status: 404, envelope: nil)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        await library.mcpAction(
            host: one, server: "ghost", connect: true, sessionDirectory: "/srv/demo"
        )

        XCTAssertEqual(
            library.toggleError,
            "The host does not report an MCP server named \"ghost\" — the list was refreshed."
        )
        XCTAssertNil(library.notice)
        XCTAssertEqual(
            library.mcpRows.map(\.id), ["demo-docs", "demo-auth"],
            "the refreshed inventory is what the list shows"
        )
    }

    /// A definite HTTP rejection means the host answered "no": the
    /// message names the status, the rows stand (nothing changed — no
    /// refetch needed), and the banners belong to THIS attempt (an
    /// earlier plugin "Saved" notice must not survive beside it).
    func testMcpActionOwnsTheBannersAndNamesADefiniteRejection() async throws {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list": return Fixtures.response(Fixtures.mcpListDisabled)
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write", "location.reload":
                return Fixtures.noContent
            case "experimental.mcp.connect":
                throw TransportError.http(status: 400, envelope: nil)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)
        await library.applyToggle(host: one, plan: plan)
        XCTAssertEqual(library.notice, "Saved — the host reloaded the location.")
        let mcpReadsBeforeAction = recorder.requests.filter { $0.operationID == "mcp.list" }.count

        await library.mcpAction(
            host: one, server: "demo-docs", connect: true, sessionDirectory: "/srv/demo"
        )

        XCTAssertEqual(
            library.toggleError, "The host rejected the MCP runtime change (HTTP 400)."
        )
        XCTAssertNil(library.notice, "a new attempt owns the banners — no stale 'Saved'")
        XCTAssertEqual(
            library.mcpRows.first?.status.kind, .disabled,
            "a rejected control changed nothing — the rows stand without a refetch"
        )
        XCTAssertEqual(
            recorder.requests.filter { $0.operationID == "mcp.list" }.count,
            mcpReadsBeforeAction,
            "a definite rejection needs no refetch — the host already answered"
        )
    }

    /// The MCP inventory answered for ANOTHER location: refused
    /// fail-closed — statuses from one scope are never shown under
    /// this session — but only the MCP segment is cleared and
    /// labelled; the plugin rows (answered for the right scope) stay
    /// fully usable (W15 review round 1).
    func testLoadRefusesAnMcpInventoryAnsweredForAnotherLocation() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list": return Fixtures.response(Fixtures.mcpListOtherLocation)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        XCTAssertNil(library.loadError, "the plugin inventory answered for the right scope")
        XCTAssertEqual(
            library.rows.first?.id, "demo.audit",
            "the plugin segment stays fully usable"
        )
        XCTAssertTrue(library.mcpRows.isEmpty, "statuses from another scope are never shown")
        XCTAssertEqual(
            library.mcpError,
            "The host reports its MCP inventory for a different location than this session's directory."
        )
    }

    /// An mcp.list transport failure degrades ONLY the MCP segment:
    /// the plugin rows load, the failure is named inside its own
    /// section, and the global load error stays clear — one section's
    /// trouble never hides the other (W15 review round 1).
    func testAnMcpReadFailureKeepsThePluginRows() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list":
                throw TransportError.connectionFailed("mcp inventory unavailable")
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        XCTAssertNil(library.loadError)
        XCTAssertEqual(library.rows.first?.id, "demo.audit", "the plugin rows stand")
        XCTAssertTrue(library.mcpRows.isEmpty)
        XCTAssertEqual(
            library.mcpError,
            "The host is unreachable right now. Pull to refresh to try again.",
            "the MCP segment names its failure with its actual cause"
        )
    }

    /// A plugin write lands and the readback verdict completes even
    /// when the MCP read fails in the SAME refresh: the verdict
    /// reports plugin facts only — never "the runtime inventory could
    /// not be read" when the plugin inventory did answer (the exact
    /// falsehood W15 review round 1 caught).
    func testPluginReadbackCompletesWhenTheMcpReadFails() async throws {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list":
                throw TransportError.connectionFailed("mcp inventory unavailable")
            case "fs.read": return Fixtures.file(Fixtures.documentBytes)
            case "experimental.fs.write", "location.reload":
                return Fixtures.noContent
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")
        XCTAssertEqual(
            library.mcpError, "The host is unreachable right now. Pull to refresh to try again.",
            "the MCP segment already carries its own label after load"
        )

        await library.planToggle(host: one, target: "demo.audit", enable: true)
        let plan = try XCTUnwrap(library.pendingPlan)
        await library.applyToggle(host: one, plan: plan)

        XCTAssertNil(library.toggleError)
        XCTAssertEqual(
            library.notice, "Saved — the host reloaded the location.",
            "the plugin verdict is the plugin inventory's truth — the MCP read changes nothing about it"
        )
        XCTAssertEqual(library.rows.first?.id, "demo.audit")
        XCTAssertEqual(
            library.mcpError, "The host is unreachable right now. Pull to refresh to try again.",
            "the readback keeps the MCP segment labelled through its adopt"
        )
    }

    /// A 404 whose refreshed list still SHOWS the server: "does not
    /// report it" would be a lie printed under the row itself — the
    /// banner names the 404 and the status the refresh actually
    /// reports (W15 review round 1).
    func testMcpConnect404WithServerStillListedNamesTheStatus() async {
        let recorder = Recorder()
        let library = library(recorder: recorder) { request in
            switch request.operationID {
            case "plugin.list": return Fixtures.response(Fixtures.pluginList)
            case "config.get": return Fixtures.response(Fixtures.configWithDirectives)
            case "mcp.list": return Fixtures.response(Fixtures.mcpListDisabled)
            case "experimental.mcp.connect":
                throw TransportError.http(status: 404, envelope: nil)
            default: throw TransportError.connectionFailed("unstubbed \(request.operationID)")
            }
        }
        await library.load(host: one, sessionDirectory: "/srv/demo")

        await library.mcpAction(
            host: one, server: "demo-docs", connect: true, sessionDirectory: "/srv/demo"
        )

        XCTAssertEqual(
            library.toggleError,
            "The host answered HTTP 404 for \"demo-docs\"; the refreshed list shows it as Disabled."
        )
        XCTAssertNil(library.notice)
        XCTAssertEqual(
            library.mcpRows.first?.status.kind, .disabled,
            "the row itself proves the refreshed list still reports it"
        )
    }
}
