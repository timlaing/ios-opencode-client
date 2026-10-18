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

    func testUnknownConditionOperatorIsNeverGuessed() {
        // The baseline defines only eq/neq. A host (or cached model)
        // carrying another operator must not be silently evaluated as
        // a negation — the field stays unsatisfied.
        let fields: [FormField] = [
            .string(FormStringField(key: "mode")),
            .string(FormStringField(key: "detail", when: [
                FormWhen(key: "mode", op: "gt", value: .string("simple")),
            ])),
        ]
        var draft = FormDraft(fields: fields)
        XCTAssertFalse(draft.isActive(fields[1]),
                       "an operator outside the baseline satisfies nothing")
        draft.texts["mode"] = "zzz"
        XCTAssertFalse(draft.isActive(fields[1]),
                       "the unknown operator is never reinterpreted as neq")
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

    // MARK: - Named non-finite defaults

    func testNamedNaNDefaultSeedsAnEmptyBufferNotLiteralNan() {
        // The wire can NAME a NaN default the client can decode but no
        // person can enter: seeding the literal "nan" would fail
        // parseNumber on an untouched field and block submission. Such
        // a default seeds an EMPTY buffer — unanswered, and honestly
        // valid while the field is optional.
        let fields: [FormField] = [
            .number(FormNumberField(key: "seed", default: .nan)),
            .integer(FormIntegerField(key: "replicas", default: .nan)),
        ]
        let draft = FormDraft(fields: fields)
        XCTAssertEqual(draft.numbers["seed"], "",
                       "NaN is never shown as typed text the user must clear")
        XCTAssertEqual(draft.numbers["replicas"], "")
        XCTAssertTrue(draft.validate().isEmpty, "an untouched optional field stays valid")
        XCTAssertNil(draft.answer()["seed"], "a NaN default answers nothing")
        XCTAssertNil(draft.answer()["replicas"])
    }

    func testInfinityIntegerDefaultsSeedAnEmptyBufferNotInfinityText() {
        // Like NaN (above), an infinite default is something no one can
        // meaningfully submit for an INTEGER field: parseNumber accepts
        // "inf" back, but validate() rejects a non-finite whole number —
        // an untouched field would error. Such defaults seed empty.
        let fields: [FormField] = [
            .integer(FormIntegerField(key: "cap", default: .infinity)),
            .integer(FormIntegerField(key: "floor", default: -.infinity)),
        ]
        let draft = FormDraft(fields: fields)
        XCTAssertEqual(draft.numbers["cap"], "",
                       "an infinite default never seeds editing text an integer field rejects")
        XCTAssertEqual(draft.numbers["floor"], "")
        XCTAssertTrue(draft.validate().isEmpty, "an untouched optional field stays valid")
        XCTAssertNil(draft.answer()["cap"], "an infinite default answers nothing")
        XCTAssertNil(draft.answer()["floor"])
    }

    func testFiniteNonDefaultSeedsStillRoundTrip() {
        // Finite defaults keep their exact editing text — number
        // fields also round-trip an infinite default ("-inf" parses
        // back to the same value), but INTEGER fields seed empty for
        // any non-finite default (see the test above).
        let fields: [FormField] = [
            .number(FormNumberField(key: "ratio", default: 2.5)),
            .integer(FormIntegerField(key: "replicas", default: 3)),
            .number(FormNumberField(key: "open", default: -.infinity)),
        ]
        let draft = FormDraft(fields: fields)
        XCTAssertEqual(draft.numbers["ratio"], "2.5")
        XCTAssertEqual(draft.numbers["replicas"], "3")
        XCTAssertEqual(draft.numbers["open"], "-inf")
        XCTAssertEqual(draft.answer()["open"], .number(-.infinity),
                       "an infinite default parses back to the same typed value")
    }

    // MARK: - Condition order guard (a `when` names an EARLIER field)

    func testSelfReferencingConditionIsUnsatisfiedAndNeverRecurses() {
        let fields: [FormField] = [
            .string(FormStringField(key: "loop", when: [
                FormWhen(key: "loop", op: "eq", value: .string("x")),
            ])),
        ]
        var draft = FormDraft(fields: fields)
        // Even answered, a condition on its own key is outside the
        // earlier-fields rule — unsatisfied, and evaluation never
        // re-enters itself (the agent authors forms, so a malformed
        // schema reaches the sheet).
        draft.texts["loop"] = "x"
        XCTAssertFalse(draft.isActive(fields[0]))
        XCTAssertTrue(draft.answer().isEmpty)
    }

    func testForwardReferencingConditionIsUnsatisfied() {
        let fields: [FormField] = [
            .string(FormStringField(key: "detail", when: [
                FormWhen(key: "mode", op: "eq", value: .string("full")),
            ])),
            .string(FormStringField(key: "mode")),
        ]
        var draft = FormDraft(fields: fields)
        draft.texts["mode"] = "full"
        XCTAssertFalse(draft.isActive(fields[0]),
                       "a condition on a LATER field is unsatisfied — the host may not order it that way")
    }

    func testMutuallyReferencingConditionsBothTerminateAsUnsatisfied() {
        // a when b (forward → unsatisfied immediately), b when a
        // (earlier, but a's own value depends on the first condition) —
        // evaluation always steps to a strictly lower index, so the
        // pair terminates instead of recursing until the stack dies.
        let fields: [FormField] = [
            .string(FormStringField(key: "alpha", when: [
                FormWhen(key: "beta", op: "eq", value: .string("on")),
            ])),
            .string(FormStringField(key: "beta", when: [
                FormWhen(key: "alpha", op: "eq", value: .string("on")),
            ])),
        ]
        var draft = FormDraft(fields: fields)
        draft.texts["alpha"] = "on"
        draft.texts["beta"] = "on"
        XCTAssertFalse(draft.isActive(fields[0]))
        XCTAssertFalse(draft.isActive(fields[1]))
        XCTAssertTrue(draft.answer().isEmpty, "neither side of a cycle answers")
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

    // MARK: - Clearing and linear visibility (R3)

    func testInactiveValuesAreClearedNotResurrectedByAFlipBack() {
        // The safety case: a required confirmation checked while its
        // condition holds must NOT ride back in when the condition
        // flips off and on again — the person re-affirms for THIS
        // visit (docs/api-contract.md W10).
        var draft = FormDraft(fields: fixtureFields)
        draft.setText("environment", "production")
        draft.setBoolean("confirm", .on)
        XCTAssertEqual(draft.answer()["confirm"], .boolean(true))

        // The condition's input flips away: the confirmation is
        // inactive AND its value is removed, not parked.
        draft.setText("environment", "staging")
        XCTAssertFalse(draft.isActive(fixtureFields[2]))
        XCTAssertNotEqual(draft.bools["confirm"], .on,
                          "the stale affirmation is cleared, never parked")

        // Flipping back must NOT resurrect it: the person re-chooses.
        draft.setText("environment", "production")
        XCTAssertTrue(draft.isActive(fixtureFields[2]))
        XCTAssertNil(draft.answer()["confirm"], "a re-shown field starts unanswered")
        XCTAssertNotNil(draft.validate()["confirm"],
                        "the required confirmation blocks submission until re-affirmed")
    }

    func testChainedConditionsResolveInOneLinearForwardPass() {
        // The shape that made per-field recursive visibility
        // exponential: field i cites the two before it. Forty fields
        // cost ~10^8 recursive steps per answer() call under the old
        // evaluator — the sheet would freeze on every keystroke. The
        // forward pass is one left-to-right sweep, so this test
        // completing at all is the regression signal; the counts
        // below check correctness, not just speed.
        var fields: [FormField] = [
            .boolean(FormBooleanField(key: "f0", default: true)),
            .boolean(FormBooleanField(key: "f1", default: true)),
        ]
        for index in 2..<40 {
            fields.append(.boolean(FormBooleanField(key: "f\(index)", when: [
                FormWhen(key: "f\(index - 1)", op: "eq", value: .boolean(true)),
                FormWhen(key: "f\(index - 2)", op: "eq", value: .boolean(true)),
            ], default: true)))
        }
        var draft = FormDraft(fields: fields)
        XCTAssertEqual(draft.answer().count, 40, "every default-true field is active")

        // Break one link: everything behind it is inactive.
        draft.setBoolean("f10", .off)
        XCTAssertFalse(draft.isActive(fields[11]))
        XCTAssertFalse(draft.isActive(fields[39]))
        XCTAssertEqual(draft.answer().count, 11, "f0...f10 answer; the tail is inactive")

        // Restoring the link reactivates from SEEDED values — the
        // cleared tail never resurrects a stale typed answer.
        draft.setBoolean("f10", .on)
        XCTAssertEqual(draft.answer().count, 40, "the chain reactivates from the seeds")
    }

    // MARK: - Validation

    func testValidationCoversPresenceLengthsAndBounds() {
        var draft = FormDraft(fields: fixtureFields)
        draft.texts["environment"] = ""
        draft.texts["notes"] = String(repeating: "x", count: 201)
        draft.numbers["replicas"] = "9"

        let errors = draft.validate()
        XCTAssertEqual(errors["environment"]?.message, "This field is required.")
        XCTAssertEqual(errors["notes"]?.message, "Use at most 200 UTF-16 code units.")
        XCTAssertEqual(errors["replicas"]?.message, "Use at most 5.")
        XCTAssertNil(errors["checks"],
                     "an unselected optional multiselect is simply omitted — the host's "
                     + "minItems applies to a present answer, and blocking here would make "
                     + "an otherwise-valid submission impossible")
    }

    func testStringLengthsCountUTF16UnitsLikeTheHost() {
        // The host counts UTF-16 CODE UNITS (TypeScript String.length),
        // not grapheme clusters: "👍" is one Character but TWO units.
        // Counting Characters would let a 4-unit answer slip past a
        // maxLength of 3 (a guaranteed host 400) — and block a
        // host-valid answer on minLength.
        let fields: [FormField] = [
            .string(FormStringField(key: "caption", maxLength: 3)),
        ]
        var draft = FormDraft(fields: fields)
        draft.texts["caption"] = "👍👍"   // two Characters, FOUR units
        XCTAssertNotNil(draft.validate()["caption"],
                        "4 UTF-16 units exceed maxLength 3 — the host would 400 it")
        draft.texts["caption"] = "a👍"     // two Characters, THREE units
        XCTAssertNil(draft.validate()["caption"],
                     "3 UTF-16 units fit maxLength 3 — never a false local block")
        draft.texts["caption"] = "abc"     // three ASCII Characters, three units
        XCTAssertNil(draft.validate()["caption"])

        let minFields: [FormField] = [
            .string(FormStringField(key: "tagline", minLength: 3)),
        ]
        var minDraft = FormDraft(fields: minFields)
        minDraft.texts["tagline"] = "👍a"  // two Characters, THREE units
        XCTAssertNil(minDraft.validate()["tagline"],
                     "the host accepts 3 units for minLength 3 — no false local block")
    }

    func testBuffersExcludeSchemaValuesSoNaNFormsCompareStably() {
        // FormDraft's synthesised Equatable includes the SCHEMA, so a
        // NaN default makes draft == draft false — an onChange keyed on
        // the whole draft re-fires on every render and clears fresh
        // validation errors the moment submit sets them. The Buffers
        // projection carries only user-editable state: stable under a
        // NaN schema, and still reflecting every real edit.
        let fields: [FormField] = [
            .number(FormNumberField(key: "seed", default: .nan)),
            .string(FormStringField(key: "note")),
        ]
        let first = FormDraft(fields: fields)
        var second = FormDraft(fields: fields)
        XCTAssertNotEqual(first, second,
                          "the NaN default makes whole-draft equality unstable by construction")
        XCTAssertEqual(first.buffers, second.buffers,
                       "Buffers carry no schema values, so the observer sees no change")
        second.texts["note"] = "typed"
        XCTAssertNotEqual(first.buffers, second.buffers,
                          "a real edit still changes the observed value")
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

    // MARK: - Parsing (locale-aware numeric input)

    func testParseNumberAcceptsRegionalAndWireDecimalSeparators() {
        // The decimal pad shows `,` in de/fr/es/nl — fractional input
        // must parse there, while the wire's `.` (what host defaults
        // use) always parses regardless of region.
        XCTAssertEqual(FormDraft.parseNumber("3,5", decimalSeparator: ","), 3.5)
        XCTAssertEqual(FormDraft.parseNumber("3.5", decimalSeparator: ","), 3.5,
                       "the wire's dot parses even where the pad shows a comma")
        XCTAssertEqual(FormDraft.parseNumber(" 42 ", decimalSeparator: ","), 42,
                       "surrounding whitespace is trimmed, never parsed as part of the number")
        XCTAssertNil(FormDraft.parseNumber("", decimalSeparator: ","))
        XCTAssertNil(FormDraft.parseNumber("abc", decimalSeparator: ","))
        XCTAssertNil(FormDraft.parseNumber("NaN", decimalSeparator: ","),
                     "NaN is never a submittable value")
        XCTAssertEqual(FormDraft.parseNumber("-Infinity", decimalSeparator: ","),
                       -.infinity, "the wire's named non-finite bounds parse — the host enforces them")
    }

    // MARK: - Presentation

    func testConstraintsRenderTheDeclaredSchemaRules() {
        XCTAssertEqual(FormDraft.constraints(for: fixtureFields[0]), "Required · One of the options below")
        XCTAssertEqual(FormDraft.constraints(for: fixtureFields[1]), "Choose at least 1")
        XCTAssertEqual(FormDraft.constraints(for: fixtureFields[2]), "Required")
        XCTAssertEqual(FormDraft.constraints(for: fixtureFields[3]), "At most 200 UTF-16 code units")
        XCTAssertEqual(FormDraft.constraints(for: fixtureFields[4]), "Whole number · Between 1 and 5")
        XCTAssertNil(FormDraft.constraints(for: fixtureFields[5]), "an external link has no answer rules")
    }

    func testUnboundedNumericConstraintsShowInfinitySymbolsNotRawInf() {
        // The wire's named non-finite bounds are real (the host
        // enforces them) — shown as the mathematical symbol, never a
        // raw `inf` in a validation caption (S12: rules are visible).
        let open = FormField.number(FormNumberField(
            key: "ratio", minimum: -.infinity, maximum: .infinity
        ))
        XCTAssertEqual(FormDraft.constraints(for: open), "Between -∞ and ∞")

        let onlyLower = FormField.number(FormNumberField(key: "atLeast", minimum: -.infinity))
        XCTAssertEqual(FormDraft.constraints(for: onlyLower), "At least -∞")

        let onlyUpper = FormField.integer(FormIntegerField(key: "atMost", maximum: .infinity))
        XCTAssertEqual(FormDraft.constraints(for: onlyUpper), "Whole number · At most ∞")

        // A FINITE bound beside an infinite one still reads as the
        // Between form — both declared bounds are shown as declared.
        let floorWithOpenTop = FormField.number(FormNumberField(
            key: "atLeast", minimum: 0, maximum: .infinity
        ))
        XCTAssertEqual(FormDraft.constraints(for: floorWithOpenTop), "Between 0 and ∞")
    }

    // MARK: - Buffers (observer-stable equality)

    func testBuffersReflectOnlyTheEditableStateAcrossEveryFieldKind() {
        // `buffers` is what the sheet observes for "did the user edit
        // anything?" (validation-error clearing). It must (a) carry NO
        // schema `Double` values — so a NaN default/bound can never leak
        // into the comparison — and (b) be stable for a pristine draft
        // and sensitive to a real edit in every buffer kind.
        let fields: [FormField] = [
            .string(FormStringField(key: "note")),
            .number(FormNumberField(key: "ratio", default: .nan)),
            .boolean(FormBooleanField(key: "enabled")),
            .multiselect(FormMultiselectField(key: "checks", options: [
                FormOption(value: "a", label: "A"),
            ])),
        ]
        let pristine = FormDraft(fields: fields)
        // A pristine copy of the SAME draft compares equal to the
        // observer: no edit, no observed change (no phantom clearing).
        XCTAssertEqual(pristine.buffers,
                       FormDraft(fields: fields).buffers,
                       "an untouched draft looks untouched to the observer")
        // The schema's NaN default is excluded from the projection —
        // buffers hold only `Double`-free user-editable state.
        XCTAssertEqual(pristine.buffers.numbers["ratio"], "",
                       "a NaN default seeds an empty editing buffer, not a Double")
        XCTAssertNil(pristine.buffers.texts["ratio"],
                     "numbers never surface in the string-text buffer")

        // Every editable kind reports a real edit to the observer.
        var edited = pristine
        edited.texts["note"] = "x"
        XCTAssertNotEqual(pristine.buffers, edited.buffers, "text edit is observed")
        edited.numbers["ratio"] = "1.5"
        XCTAssertNotEqual(pristine.buffers, edited.buffers, "number edit is observed")
        edited.bools["enabled"] = .on
        XCTAssertNotEqual(pristine.buffers, edited.buffers, "boolean edit is observed")
        edited.picks["checks"] = ["a"]
        XCTAssertNotEqual(pristine.buffers, edited.buffers, "multiselect edit is observed")

        // Returning each buffer to its seeded value restores equality.
        edited.texts["note"] = pristine.buffers.texts["note"]
        edited.numbers["ratio"] = pristine.buffers.numbers["ratio"]
        edited.bools["enabled"] = pristine.buffers.bools["enabled"]
        edited.picks["checks"] = pristine.buffers.picks["checks"]
        XCTAssertEqual(pristine.buffers, edited.buffers,
                       "reverting to the seed compares equal again")
    }
}
