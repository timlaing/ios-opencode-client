import XCTest
@testable import OpenCodeTransport

/// W10 request-shape tests: builder routes/operation IDs/the exact reply
/// and cancel shapes, the field union (all baseline kinds + honest
/// unknown), typed values including the wire's named non-finite
/// numbers, the state lifecycle, and the plain-string sessionID rule
/// (docs/api-contract.md W10, S12).
final class W10RequestsTests: XCTestCase {
    // MARK: - Builders

    func testSessionListBuilderCarriesRouteAndCredential() {
        let request = W10Requests.list(sessionID: "ses_demo_003", credential: BasicCredential(secret: "t"))
        XCTAssertEqual(request.operationID, "session.form.list")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.path, "/api/session/ses_demo_003/form")
        XCTAssertEqual(request.credential, BasicCredential(secret: "t"))
    }

    func testLocationWideListBuilder() {
        let request = W10Requests.listAll()
        XCTAssertEqual(request.operationID, "form.list")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.path, "/api/form")
        XCTAssertNil(request.credential, "callers attach their own credential")
    }

    func testGetBuilderTargetsOneForm() {
        let request = W10Requests.get(sessionID: "ses_a", formID: "frm_b")
        XCTAssertEqual(request.operationID, "session.form.get")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.path, "/api/session/ses_a/form/frm_b")
    }

    func testReplyBuilderPostsTypedAnswer() throws {
        let request = try W10Requests.reply(
            sessionID: "ses_demo_003", formID: "frm_demo",
            answer: [
                "environment": .string("production"),
                "replicas": .number(3),
                "confirm": .boolean(true),
            ],
            credential: BasicCredential(secret: "t")
        )
        XCTAssertEqual(request.operationID, "session.form.reply")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.path, "/api/session/ses_demo_003/form/frm_demo/reply")
        XCTAssertEqual(request.credential, BasicCredential(secret: "t"))
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertEqual(
            body,
            #"{"answer":{"confirm":true,"environment":"production","replicas":3}}"#,
            "typed values stay typed — 3 is the number 3, never the string \"3\""
        )
    }

    func testReplyTargetsTheOwnerSessionOfALinkedForm() throws {
        let request = try W10Requests.reply(
            sessionID: "ses_child", formID: "frm_c", answer: ["a": .string("b")]
        )
        XCTAssertEqual(request.path, "/api/session/ses_child/form/frm_c/reply",
                       "linked forms reply under their OWN owner session, never the viewer's")
    }

    func testCancelCarriesTheMessageAsQueryWithNoBody() {
        let request = W10Requests.cancel(sessionID: "ses_a", formID: "frm_b", message: "not now")
        XCTAssertEqual(request.operationID, "session.form.cancel")
        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.path, "/api/session/ses_a/form/frm_b")
        XCTAssertEqual(request.query, [QueryPair(key: "message", value: "not now")])
        XCTAssertNil(request.body, "cancellation carries no payload — only the optional message")
    }

    func testCancelWithoutMessageCarriesNoQuery() {
        let request = W10Requests.cancel(sessionID: "ses_a", formID: "frm_b")
        XCTAssertTrue(request.query.isEmpty, "an absent message is absent, never an empty parameter")
    }

    // MARK: - Field union

    /// The committed fixture's form: every field kind the baseline
    /// defines, in the host's render order.
    private let fixtureForm = """
    {"id":"frm_demo","sessionID":"ses_demo_003","title":"Choose deployment options","fields":[
      {"key":"environment","type":"string","title":"Environment","required":true,
       "options":[{"value":"staging","label":"Staging"},{"value":"production","label":"Production"}]},
      {"key":"checks","type":"multiselect","title":"Checks","minItems":1,
       "options":[{"value":"unit","label":"Unit tests"},{"value":"device","label":"Device tests"}]},
      {"key":"confirm","type":"boolean","required":true,
       "when":[{"key":"environment","op":"eq","value":"production"}]},
      {"key":"notes","type":"string","maxLength":200},
      {"key":"replicas","type":"integer","minimum":1,"maximum":5,"default":1},
      {"key":"reference","type":"external","title":"Deployment guide","url":"https://example.com/deploy"}
    ]}
    """

    func testFixtureFormDecodesEveryBaselineFieldKind() throws {
        let info = try OpenCodeAPI.decoder.decode(FormInfo.self, from: Data(fixtureForm.utf8))
        XCTAssertEqual(info.id, "frm_demo")
        XCTAssertEqual(info.title, "Choose deployment options")
        XCTAssertNil(info.metadata, "metadata is optional and absent here")
        XCTAssertEqual(
            info.fields.map(\.key),
            ["environment", "checks", "confirm", "notes", "replicas", "reference"],
            "field order is the host's render order"
        )

        guard case .string(let environment) = info.fields[0] else {
            return XCTFail("environment decodes as a string field")
        }
        XCTAssertEqual(environment.required, true)
        XCTAssertEqual(environment.options?.map(\.value), ["staging", "production"])
        XCTAssertNil(environment.custom, "without custom, answers are constrained to the options")

        guard case .multiselect(let checks) = info.fields[1] else {
            return XCTFail("checks decodes as a multiselect field")
        }
        XCTAssertEqual(checks.minItems, 1)
        XCTAssertNil(checks.maxItems, "an unbounded max decodes as absent, never as infinity")

        guard case .boolean(let confirm) = info.fields[2] else {
            return XCTFail("confirm decodes as a boolean field")
        }
        XCTAssertEqual(confirm.when?.count, 1, "a field's conditions ride on the field")
        XCTAssertEqual(confirm.when?.first?.key, "environment")
        XCTAssertEqual(confirm.when?.first?.op, "eq")
        XCTAssertEqual(confirm.when?.first?.value, .string("production"))
        XCTAssertEqual(confirm.when?.first?.isEqual, true)

        guard case .string(let notes) = info.fields[3] else {
            return XCTFail("notes decodes as a string field")
        }
        XCTAssertEqual(notes.maxLength, 200)
        XCTAssertNil(notes.required, "an absent optional flag decodes as absent, not as false")
        XCTAssertEqual(info.fields[3].title, "notes", "an untitled field falls back to its key")
        XCTAssertEqual(info.fields[3].fieldDescription, nil)

        guard case .integer(let replicas) = info.fields[4] else {
            return XCTFail("replicas decodes as an integer field")
        }
        XCTAssertEqual(replicas.minimum, 1)
        XCTAssertEqual(replicas.maximum, 5)
        XCTAssertEqual(replicas.default, 1, "the wire key \"default\" decodes into `.default`")

        guard case .external(let reference) = info.fields[5] else {
            return XCTFail("reference decodes as an external field")
        }
        XCTAssertEqual(reference.url, "https://example.com/deploy")
        XCTAssertTrue(info.fields[5].isExternal)
        XCTAssertFalse(info.fields[5].isRequired, "external fields never demand an answer")
        XCTAssertFalse(info.fields[5].isHidden)
    }

    func testUnknownFieldTypeKeepsRawPayload() throws {
        let json = #"{"key":"tiling","type":"vector-map","title":"Tiling","size":4}"#
        let field = try OpenCodeAPI.decoder.decode(FormField.self, from: Data(json.utf8))
        guard case .unknown(let type, let raw) = field else {
            return XCTFail("an unknown field type is never claimed as a known one")
        }
        XCTAssertEqual(type, "vector-map")
        XCTAssertEqual(raw["size"], .number(4))
        XCTAssertEqual(raw["type"], .string("vector-map"))
        XCTAssertEqual(field.key, "tiling", "identity still reads from the raw payload")
        XCTAssertEqual(field.title, "Tiling")
        XCTAssertFalse(field.isRequired, "an unknown kind never claims validation it cannot do")
        XCTAssertTrue(field.conditions.isEmpty)
        XCTAssertFalse(field.isExternal)
    }

    func testWhenConditionsCarryKnownOperationsAsAnAndList() throws {
        let json = #"{"key":"k","type":"string","when":[{"key":"mode","op":"eq","value":"a"},{"key":"mode","op":"neq","value":"b"}]}"#
        let field = try OpenCodeAPI.decoder.decode(FormField.self, from: Data(json.utf8))
        let conditions = field.conditions
        XCTAssertEqual(conditions.count, 2, "a field's conditions are an AND list, not alternatives")
        XCTAssertEqual(conditions[0].isEqual, true)
        XCTAssertEqual(conditions[0].isNotEqual, false)
        XCTAssertEqual(conditions[1].isEqual, false)
        XCTAssertEqual(conditions[1].isNotEqual, true)
        XCTAssertEqual(conditions[1].value, .string("b"))
    }

    // MARK: - Typed values

    func testFormValueDecodesTypedCasesAndNamedNonFiniteNumbers() throws {
        XCTAssertEqual(try decodeValue(#""staging""#), .string("staging"))
        XCTAssertEqual(try decodeValue("3"), .number(3))
        XCTAssertEqual(try decodeValue("0.5"), .number(0.5))
        XCTAssertEqual(try decodeValue("true"), .boolean(true))
        XCTAssertEqual(try decodeValue(#"["unit","device"]"#), .strings(["unit", "device"]))
        XCTAssertEqual(try decodeValue(#""Infinity""#), .number(.infinity),
                       "the wire's named non-finite number stays a TYPED number")
        XCTAssertEqual(try decodeValue(#""-Infinity""#), .number(-.infinity))

        // NaN is never equal to itself — assert the case, not equality.
        guard case .number(let nan) = try decodeValue(#""NaN""#) else {
            return XCTFail("the wire's NaN decodes as a typed number")
        }
        XCTAssertTrue(nan.isNaN)
    }

    func testFormValueEncodesNonFiniteNumbersAsTheNamedStrings() throws {
        XCTAssertEqual(
            try OpenCodeAPI.encoder.encode(FormValue.number(.infinity)),
            Data(#""Infinity""#.utf8)
        )
        XCTAssertEqual(
            try OpenCodeAPI.encoder.encode(FormValue.number(-.infinity)),
            Data(#""-Infinity""#.utf8)
        )
        XCTAssertEqual(
            try OpenCodeAPI.encoder.encode(FormValue.number(.nan)),
            Data(#""NaN""#.utf8)
        )
        XCTAssertEqual(try OpenCodeAPI.encoder.encode(FormValue.number(4.5)), Data("4.5".utf8))
    }

    private func decodeValue(_ json: String) throws -> FormValue {
        try OpenCodeAPI.decoder.decode(FormValue.self, from: Data(json.utf8))
    }

    // MARK: - State lifecycle

    func testFormStateDecodesTheLifecycleAndSettledFlags() throws {
        let pending = try decodeState(#"{"status":"pending"}"#)
        XCTAssertEqual(pending, .pending)
        XCTAssertFalse(pending.isSettled, "only pending forms are editable (S12)")

        let answered = try decodeState(#"{"status":"answered","answer":{"replicas":3}}"#)
        XCTAssertEqual(answered, .answered(answer: ["replicas": .number(3)]))
        XCTAssertTrue(answered.isSettled)

        let cancelled = try decodeState(#"{"status":"cancelled","message":"changed my mind"}"#)
        XCTAssertEqual(cancelled, .cancelled(message: "changed my mind"))
        XCTAssertTrue(cancelled.isSettled)

        let unknown = try decodeState(#"{"status":"reviewing","step":2}"#)
        guard case .unknown(let status, let raw) = unknown else {
            return XCTFail("an unknown status must never be claimed pending")
        }
        XCTAssertEqual(status, "reviewing")
        XCTAssertEqual(raw["step"], .number(2))
        XCTAssertTrue(unknown.isSettled, "anything not explicitly pending is settled")
    }

    private func decodeState(_ json: String) throws -> FormState {
        try OpenCodeAPI.decoder.decode(FormState.self, from: Data(json.utf8))
    }

    // MARK: - Envelopes

    func testListResponseReadsSessionAndLocatedEnvelopes() throws {
        let session = try OpenCodeAPI.decoder.decode(
            FormListResponse.self, from: Data("{\"data\":[\(fixtureForm)]}".utf8)
        )
        XCTAssertEqual(session.data.map(\.id), ["frm_demo"])

        let located = try OpenCodeAPI.decoder.decode(
            FormListResponse.self,
            from: Data("{\"location\":{\"directory\":\"/srv/demo/harbour\"},\"data\":[\(fixtureForm)]}".utf8)
        )
        XCTAssertEqual(located.data.map(\.id), ["frm_demo"],
                       "the location wrapper rides alongside data, not inside it")
    }

    /// The wire has no JSON literal for ±infinity/NaN, so such a bound
    /// arrives as its exact name ("Infinity"/"-Infinity"/"NaN"). One
    /// field carrying a named non-finite bound must never fail the
    /// decode of its ENTIRE list payload — every pending question
    /// shares that list (docs/api-contract.md W10 non-finite bounds).
    func testNamedNonFiniteBoundsNeverFailTheWholeListDecode() throws {
        let form = """
        {"id":"frm_open","sessionID":"ses_demo_003","title":"Any number","fields":[
          {"key":"ratio","type":"number","minimum":"-Infinity","maximum":"Infinity"},
          {"key":"seed","type":"integer","default":"NaN"}
        ]}
        """
        let response = try OpenCodeAPI.decoder.decode(
            FormListResponse.self, from: Data("{\"data\":[\(form)]}".utf8)
        )
        XCTAssertEqual(response.data.map(\.id), ["frm_open"])

        guard case .number(let ratio) = response.data[0].fields[0] else {
            return XCTFail("the open-ended number decodes as a number field")
        }
        XCTAssertEqual(try XCTUnwrap(ratio.minimum), -Double.infinity)
        XCTAssertEqual(try XCTUnwrap(ratio.maximum), Double.infinity)

        guard case .integer(let seed) = response.data[0].fields[1] else {
            return XCTFail("the seeded integer decodes as an integer field")
        }
        let defaultValue = try XCTUnwrap(seed.default, "the named NaN default stays present")
        XCTAssertTrue(defaultValue.isNaN, "the wire's named NaN stays a typed NaN value")
    }

    func testWholeListDecodesWhenOneFieldCarriesNamedNonFiniteBounds() throws {
        // JSON has no ±infinity/NaN literals, so a host that states an
        // open bound names it — ONE such field must not fail the decode
        // of the ENTIRE list, where every pending form rides a single
        // payload (docs/api-contract.md W10 non-finite bounds).
        let wide = """
        {"id":"frm_wide","sessionID":"ses_demo_003","title":"Wide","fields":[
          {"key":"ratio","type":"number","minimum":"-Infinity","maximum":"Infinity","default":"NaN"},
          {"key":"count","type":"integer","maximum":"Infinity"}
        ]}
        """
        let response = try OpenCodeAPI.decoder.decode(
            FormListResponse.self, from: Data("{\"data\":[\(fixtureForm),\(wide)]}".utf8)
        )
        XCTAssertEqual(response.data.map(\.id), ["frm_demo", "frm_wide"])

        guard case .number(let ratio) = response.data[1].fields[0] else {
            return XCTFail("the open-ended field decodes as a number field")
        }
        XCTAssertEqual(try XCTUnwrap(ratio.minimum), -Double.infinity)
        XCTAssertEqual(try XCTUnwrap(ratio.maximum), Double.infinity)
        // NaN never equals itself — assert the case, not equality.
        let seed = try XCTUnwrap(ratio.default)
        XCTAssertTrue(seed.isNaN, "the wire's named NaN default stays a typed number")

        guard case .integer(let count) = response.data[1].fields[1] else {
            return XCTFail("the integer field decodes")
        }
        XCTAssertEqual(try XCTUnwrap(count.maximum), Double.infinity)
    }

    func testOnlyTheThreeNamedStringsConvertAsNonFiniteBounds() throws {
        // The strategy is name-gated: anything else offered where a
        // number belongs is still rejected — never silently coerced.
        let junk = """
        {"data":[{"id":"frm_junk","sessionID":"ses_demo_003","title":"Junk","fields":[
          {"key":"ratio","type":"number","minimum":"wide"}
        ]}]}
        """
        XCTAssertThrowsError(
            try OpenCodeAPI.decoder.decode(FormListResponse.self, from: Data(junk.utf8)),
            "a non-name string is never accepted as a bound"
        )
    }

    func testDetailResponseWrapsOneFormWithItsState() throws {
        let json = """
        {"data":{"id":"frm_demo","sessionID":"ses_demo_003","title":"Choose",
         "state":{"status":"answered","answer":{"confirm":true}},
         "fields":[{"key":"confirm","type":"boolean"}]}}
        """
        let response = try OpenCodeAPI.decoder.decode(FormDetailResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.data.id, "frm_demo")
        XCTAssertEqual(response.data.state, .answered(answer: ["confirm": .boolean(true)]))
    }

    // MARK: - Identity rules

    func testSessionIDIsAPlainStringWithNoPrefixEnforced() throws {
        // The schema permits a non-session MCP-owner sentinel (W10):
        // identity is compared literally, never by pattern — a `ses`
        // prefix check would reject a legitimate form owner.
        let json = #"{"id":"frm_global","sessionID":"mcp_server_tools","title":"Enable tools","fields":[{"key":"ok","type":"boolean"}]}"#
        let info = try OpenCodeAPI.decoder.decode(FormInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.sessionID, "mcp_server_tools")
        XCTAssertEqual(info.fields.map(\.key), ["ok"])
    }
}
