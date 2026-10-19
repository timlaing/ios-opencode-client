import XCTest
@testable import OpenCodeTransport

/// W14 request shapes (docs/api-contract.md W14/W15): builder routes,
/// the plugin inventory's union decodes (every unknown value stays
/// visible), and the config document's lossless entry decode — the app
/// reads plugin directives from RAW document bytes, never from the
/// parsed `info` re-serialisation.
final class W14RequestsTests: XCTestCase {
    func testBuilderRoutesAndMethods() {
        for (request, operationID, method, path) in [
            (W14Requests.pluginList(), "plugin.list", HTTPMethod.get, "/api/plugin"),
            (W14Requests.configList(), "config.get", HTTPMethod.get, "/api/config"),
            (W14Requests.locationReload(), "location.reload", HTTPMethod.post, "/api/location/reload"),
        ] {
            XCTAssertEqual(request.operationID, operationID)
            XCTAssertEqual(request.method, method)
            XCTAssertEqual(request.path, path)
            XCTAssertTrue(request.query.isEmpty, "no location asked for, no query sent")
        }
    }

    func testPluginListScopesTheInventoryToALocation() {
        // Asked for a directory, plugin.list carries the deep-object
        // location like every location-scoped route (the baseline's
        // `location` parameter is optional — without it, no query).
        let scoped = W14Requests.pluginList(directory: "/srv/demo")
        XCTAssertEqual(
            scoped.query, [QueryPair(key: "location[directory]", value: "/srv/demo")]
        )
        XCTAssertTrue(W14Requests.pluginList().query.isEmpty)
    }

    private func decodePlugin(_ json: String) throws -> PluginInfo {
        try JSONDecoder().decode(PluginInfo.self, from: Data(json.utf8))
    }

    func testPluginSourceVariantsDecode() throws {
        let builtin = try decodePlugin(
            #"{"source":{"type":"builtin"},"features":{"server":true},"state":{"status":"active"}}"#
        )
        XCTAssertEqual(builtin.source, .builtin)
        XCTAssertEqual(builtin.features.server, true)
        XCTAssertFalse(builtin.features.tui, "absent enum-true features decode as false, never invented")
        XCTAssertEqual(builtin.state, .active)

        let package = try decodePlugin(
            #"{"id":"demo.audit","source":{"type":"package","target":"demo.audit","version":"1.0.0","outdated":true},"features":{},"state":{"status":"failed","error":"boom","ref":"msg_1"}}"#
        )
        XCTAssertEqual(package.id, "demo.audit")
        XCTAssertEqual(package.source, .package(target: "demo.audit", version: "1.0.0", outdated: true, updating: false))
        XCTAssertEqual(package.state, .failed(error: "boom", ref: "msg_1"))

        let local = try decodePlugin(
            #"{"source":{"type":"local","path":"/srv/x/plugin.ts"},"features":{"rpc":true},"state":{"status":"active"}}"#
        )
        XCTAssertEqual(local.source, .local(path: "/srv/x/plugin.ts"))
        XCTAssertEqual(local.features.rpc, true)
    }

    func testUnknownPluginValuesStayVisible() throws {
        // A host outside this baseline's enum must keep its row —
        // never dropped, never mapped onto a known kind (house rule).
        let plugin = try decodePlugin(
            #"{"id":"x","source":{"type":"quantum"},"features":{"server":true},"state":{"status":"melting"}}"#
        )
        XCTAssertEqual(plugin.source, .unknown(type: "quantum"))
        XCTAssertEqual(plugin.state, .unknown(status: "melting"))

        // …and survive an encode round-trip.
        let encoded = try JSONEncoder().encode(plugin)
        XCTAssertEqual(try JSONDecoder().decode(PluginInfo.self, from: encoded), plugin)
    }

    func testConfigEntriesDecodeLosslesslyIncludingPluginDirectives() throws {
        // config.get answers with a BARE array (no {data} envelope).
        let entries = try JSONDecoder().decode(
            [ConfigEntry].self,
            from: Data(#"[{"type":"document","path":"/srv/demo/opencode.jsonc","info":{"$schema":"x","plugins":["demo.audit","-old.pkg"],"share":"manual"}},{"type":"directory","path":"/srv/demo/.opencode"}]"#.utf8)
        )
        guard case .document(let path, let info) = entries[0] else {
            return XCTFail("expected the document entry")
        }
        XCTAssertEqual(path, "/srv/demo/opencode.jsonc")
        // `info` is kept LOSSLESS — the app reads directives from the
        // raw document bytes instead of this parse.
        guard case .object(let fields) = info else { return XCTFail("expected object info") }
        guard case .array(let plugins)? = fields["plugins"] else {
            return XCTFail("expected the plugins array")
        }
        XCTAssertEqual(plugins, [.string("demo.audit"), .string("-old.pkg")])
        guard case .string("manual")? = fields["share"] else {
            return XCTFail("unrelated keys survive the lossless decode")
        }
        XCTAssertEqual(entries[1], .directory(path: "/srv/demo/.opencode"))
    }

    func testUnknownConfigEntryStaysVisible() throws {
        let entries = try JSONDecoder().decode(
            [ConfigEntry].self,
            from: Data(#"[{"type":"wormhole","path":"/srv/demo"}]"#.utf8)
        )
        guard case .unknown = entries[0] else {
            return XCTFail("an unknown entry type is kept, never dropped")
        }
    }
}
