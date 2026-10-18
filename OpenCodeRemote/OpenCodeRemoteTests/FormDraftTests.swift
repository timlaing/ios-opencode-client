import XCTest
@testable import OpenCodeRemote
@testable import OpenCodeDomain
@testable import OpenCodeTransport

/// S12 draft logic (W10): default seeding and tri-state booleans,
/// condition-driven visibility (AND, inclusion for selections,
/// missing-answers-unsatisfied), answer assembly with typed values and
/// inactive fields omitted, and the local validation the host also
/// enforces — honest about what it does NOT check (docs/api-contract.md
/// W10, docs/navigation-screens.md S12).
final class FormDraftTests: XCTestCase {
    /// The committed fixture's field set, constructed directly.
    private let fixtureFields: [FormField] = [
        .string(FormStringField(key: "environment", title: "Environment", required: true, options: [
            FormOption(value: "staging", label: "Staging"),
            FormOption(value: "production", label: "Production"),
        ])),
        .multiselect(FormMultiselectField(key: "checks", options: [
            FormOption(value: "unit", label: "Unit tests"),
            FormOption(value: "device", label: "Device tests"),
        ], minItems: 1)),
        .boolean(FormBooleanField(key: "confirm", required: true, when: [
            FormWhen(key: "environment", op: "eq", value: .string("production")),
        ])),
        .string(FormStringField(key: "notes", maxLength: 200)),
        .integer(FormIntegerField(key: "replicas", minimum: 1, maximum: 5, default: 1)),
        .external(FormExternalField(key: "reference", url: "https://example.com/deploy")),
    ]

    // MARK: - Seeding

    func testDraftSeedsDefaultsAndTriStatesPerKind() {
        let draft = FormDraft(fields: fixtureFields)
        XCTAssertEqual(draft.texts["environment"], "", "an untouched required picker starts empty")
        XCTAssertEqual(draft.bools["confirm"], .unset,
                       "a required boolean with no default must be explicitly chosen")
        XCTAssertEqual(draft.numbers["replicas"], "1",
                       "the typed default seeds the editing buffer without a trailing .0")
        XCTAssertEqual(draft.picks["checks"] ?? [], [])
        XCTAssertNil(draft.texts["reference"], "external fields take no input")
    }

    func testOptionalBooleanDefaultsToOffAndAnswersFalse() {
        let fields: [FormField] = [.boolean(FormBooleanField(key: "notify"))]
        let draft = FormDraft(fields: fields)
        XCTAssertEqual(draft.bools["notify"], .off,
                       "an untouched toggle reads as its visible OFF — never an absent key")
        XCTAssertEqual(draft.answer(), ["notify": .boolean(false)])
    }

    // MARK: - Visibility

    func testConditionsGateVisibilityAcrossTheDraft() {
        var draft = FormDraft(fields: fixtureFields)
        draft.texts["environment"] = "staging"
        XCTAssertFalse(draft.isActive(fixtureFields[2]), "confirm is active only for production")

        draft.texts["environment"] = "production"
        XCTAssertTrue(draft.isActive(fixtureFields[2]))
    }

    func testConditionOnAMissingAnswerIsUnsatisfiedEvenForNeq() {
        let fields: [FormField] = [
            .string(FormStringField(key: "mode")),
            .string(FormStringField(key: "detail", when: [
                FormWhen(key: "mode", op: "neq", value: .string("simple")),
            ])),
        ]
        let draft = FormDraft(fields: fields)
        XCTAssertFalse(draft.isActive(fields[1]),
                       "no answer for the referenced field satisfies nothing — even neq")
    }

    func testMultiselectConditionsMatchByInclusion() {
        let fields: [FormField] = [
            .multiselect(FormMultiselectField(key: "tags", options: [
                FormOption(value: "a", label: "A"),
                FormOption(value: "b", label: "B"),
            ])),
            .string(FormStringField(key: "note", when: [
                FormWhen(key: "tags", op: "eq", value: .string("a")),
            ])),
        ]
        var draft = FormDraft(fields: fields)
        XCTAssertFalse(draft.isActive(fields[1]))
        draft.toggle("tags", "a")
        XCTAssertTrue(draft.isActive(fields[1]), "eq over a selection means inclusion")
        draft.toggle("tags", "a")
        XCTAssertFalse(draft.isActive(fields[1]))
    }

    func testHiddenFieldsNeverRenderOrAnswer() {
        let fields: [FormField] = [.string(FormStringField(key: "secret", required: true, hidden: true))]
        let draft = FormDraft(fields: fields)
        XCTAssertFalse(draft.isActive(fields[0]))
        XCTAssertTrue(draft.validate().isEmpty, "a hidden field demands nothing")
        XCTAssertTrue(draft.answer().isEmpty)
    }

    func testExternalAndUnknownFieldsNeverAnswer() {
        let fields: [FormField] = [
            .external(FormExternalField(key: "guide", url: "https://example.com")),
            .unknown(type: "vector-map", raw: ["key": .string("tiling")]),
        ]
        let draft = FormDraft(fields: fields)
        XCTAssertTrue(draft.isActive(fields[0]), "the external link still renders")
        XCTAssertTrue(draft.isActive(fields[1]), "an unknown field renders as unsupported")
        XCTAssertTrue(draft.answer().isEmpty, "neither can be answered")
        XCTAssertTrue(draft.validate().isEmpty)
    }

    // MARK: - Answer assembly

    func testAnswerAssemblesTypedValuesAndOmitsInactiveFields() {
        var draft = FormDraft(fields: fixtureFields)
        draft.texts["environment"] = "production"
        draft.picks["checks"] = ["unit", "device"]
        // Filled earlier, then switched off by the condition's input:
        // the value must not ride along as a stale answer.
        draft.bools["confirm"] = .on
        draft.texts["notes"] = "ship it"
        draft.numbers["replicas"] = "3"

        let answer = draft.answer()
        XCTAssertEqual(answer.count, 5, "the external link takes no answer")
        XCTAssertEqual(answer["environment"], .string("production"))
        XCTAssertEqual(answer["checks"], .strings(["unit", "device"]))
        XCTAssertEqual(answer["confirm"], .boolean(true))
        XCTAssertEqual(answer["replicas"], .number(3), "numbers stay numbers — never the string \"3\"")
    }

    func testInactiveFieldsAreOmittedFromTheAnswerNeverStale() {
        var draft = FormDraft(fields: fixtureFields)
        draft.texts["environment"] = "staging"
        draft.bools["confirm"] = .on   // leftover from before the condition flipped
        draft.texts["notes"] = "ship it"

        let answer = draft.answer()
        XCTAssertNil(answer["confirm"], "an inactive field is omitted, never submitted stale")
        XCTAssertEqual(answer["environment"], .string("staging"))
        XCTAssertEqual(answer["notes"], .string("ship it"))
        XCTAssertEqual(answer["replicas"], .number(1), "the typed default rides as a number")
    }

    // MARK: - Validation

    func testValidationCoversPresenceLengthsAndBounds() {
        var draft = FormDraft(fields: fixtureFields)
        draft.texts["environment"] = ""
        draft.texts["notes"] = String(repeating: "x", count: 201)
        draft.numbers["replicas"] = "9"

        let errors = draft.validate()
        XCTAssertEqual(errors["environment"]?.message, "This field is required.")
        XCTAssertEqual(errors["notes"]?.message, "Use at most 200 characters.")
        XCTAssertEqual(errors["replicas"]?.message, "Use at most 5.")
        XCTAssertNil(errors["checks"],
                     "an unselected optional multiselect is simply omitted — the host's "
                     + "minItems applies to a present answer, and blocking here would make "
                     + "an otherwise-valid submission impossible")
    }

    func testValidationRejectsGarbageAndNonIntegralNumbers() {
        let fields: [FormField] = [
            .number(FormNumberField(key: "ratio")),
            .integer(FormIntegerField(key: "count")),
        ]
        var draft = FormDraft(fields: fields)
        draft.numbers["ratio"] = "abc"
        draft.numbers["count"] = "3.5"
        let errors = draft.validate()
        XCTAssertEqual(errors["ratio"]?.message, "Enter a valid number.")
        XCTAssertEqual(errors["count"]?.message, "Enter a whole number.")
    }

    func testValidationChecksSelectionBoundsAndSkipsMembershipForCustom() {
        let fields: [FormField] = [
            .multiselect(FormMultiselectField(key: "tags", options: [
                FormOption(value: "a", label: "A"),
            ], minItems: 1, maxItems: 2)),
            .multiselect(FormMultiselectField(key: "free", options: [
                FormOption(value: "a", label: "A"),
            ], custom: true)),
        ]
        var draft = FormDraft(fields: fields)
        draft.picks["tags"] = ["a", "x", "y"]
        draft.addCustom("free", "zz")

        let errors = draft.validate()
        XCTAssertEqual(errors["tags"]?.message, "Select at most 2 options.")
        XCTAssertNil(errors["free"], "custom selections are never membership-checked")
    }

    func testRequiredSelectionAndBooleanDemandAnswers() {
        let fields: [FormField] = [
            .multiselect(FormMultiselectField(key: "picks", required: true, options: [
                FormOption(value: "a", label: "A"),
            ])),
            .boolean(FormBooleanField(key: "ok", required: true)),
        ]
        let errors = FormDraft(fields: fields).validate()
        XCTAssertEqual(errors["picks"]?.message, "Select at least one option.")
        XCTAssertEqual(errors["ok"]?.message, "Choose yes or no.")
    }

    func testCompilablePatternValidatesAndUncompilableIsLeftToTheHost() {
        let fields: [FormField] = [
            .string(FormStringField(key: "code", pattern: "^v\\d+$")),
            .string(FormStringField(key: "weird", pattern: "([unclosed")),
        ]
        var draft = FormDraft(fields: fields)
        draft.texts["code"] = "abc"
        draft.texts["weird"] = "anything"
        XCTAssertEqual(draft.validate()["code"]?.message, "Use a value matching the required format.")
        XCTAssertNil(draft.validate()["weird"],
                     "a pattern Foundation cannot compile is never a local block or a false claim")

        draft.texts["code"] = "v42"
        XCTAssertNil(draft.validate()["code"])
    }

    func testCustomMultiselectAddsTypedValuesWithoutDuplicates() {
        let fields: [FormField] = [.multiselect(FormMultiselectField(key: "free", options: [
            FormOption(value: "a", label: "A"),
        ], custom: true))]
        var draft = FormDraft(fields: fields)
        draft.addCustom("free", "  zz  ")
        draft.addCustom("free", "zz")
        draft.addCustom("free", "   ")
        XCTAssertEqual(draft.picks["free"], ["zz"], "blank is a no-op and duplicates never multiply")
    }

    // MARK: - Presentation

    func testConstraintsRenderTheDeclaredSchemaRules() {
        XCTAssertEqual(FormDraft.constraints(for: fixtureFields[0]), "Required · One of the options below")
        XCTAssertEqual(FormDraft.constraints(for: fixtureFields[1]), "Choose at least 1")
        XCTAssertEqual(FormDraft.constraints(for: fixtureFields[2]), "Required")
        XCTAssertEqual(FormDraft.constraints(for: fixtureFields[3]), "At most 200 characters")
        XCTAssertEqual(FormDraft.constraints(for: fixtureFields[4]), "Whole number · Between 1 and 5")
        XCTAssertNil(FormDraft.constraints(for: fixtureFields[5]), "an external link has no answer rules")
    }
}
