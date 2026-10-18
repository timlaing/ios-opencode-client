import Foundation
import OpenCodeTransport

/// S12 editing state for ONE form (W10, docs/navigation-screens.md
/// S12, docs/api-contract.md W10): per-field inputs, active/inactive
/// visibility per the host's `when` rules, local validation where the
/// client can honestly do it, and answer assembly.
///
/// The rules this encodes, from the contract:
/// - A field is ACTIVE when it is not hidden and every `when` entry is
///   satisfied by the answers gathered so far (an AND over the list).
/// - Inactive fields are NOT rendered and their values are REMOVED
///   from the draft — `clearInactive()` resets them to their seeded
///   state after every edit, so nothing is ever submitted stale AND
///   nothing rides back in when a condition flips off and on again.
/// - `eq` over a multiselect answer means INCLUSION; a condition whose
///   referenced field has no answer yet is unsatisfied.
/// - External fields open the system browser and are never answered;
///   unknown field kinds render as unsupported and are never guessed.
/// - Local validation covers only what the client can evaluate
///   honestly: required, lengths, a compilable `pattern`, numeric
///   bounds, and selection bounds/membership. Everything else stays
///   with the host — its 400 is surfaced, never masked.
struct FormDraft: Equatable {
    /// Tri-state so an untouched REQUIRED boolean stays unanswered —
    /// the host rejects a required key with no value — while an
    /// optional toggle reads (and submits) as its visible OFF.
    enum Toggle: Equatable, Hashable { case unset, off, on }

    /// One field's validation result, kept beside the field (S12).
    struct FieldError: Equatable {
        var message: String
    }

    private(set) var fields: [FormField]
    private var fieldByKey: [String: FormField]
    /// Host render order per key — a `when` may only reference an
    /// EARLIER field (docs/api-contract.md W10). The forward pass in
    /// `activeFlags()` relies on this: a self- or forward-referencing
    /// condition finds no settled flag for the referenced field and is
    /// unsatisfied (the agent authors forms, so a malformed schema
    /// reaches the sheet).
    private var indexByKey: [String: Int] = [:]

    /// string fields: raw text (also the buffer for typed values).
    var texts: [String: String] = [:]
    /// numeric fields: the editing buffer; parsed to a TYPED number at
    /// submit (S12: numeric fields preserve typed values).
    var numbers: [String: String] = [:]
    /// boolean fields: tri-state per `Toggle`.
    var bools: [String: Toggle] = [:]
    /// multiselect fields: the selected option VALUES (independent).
    var picks: [String: [String]] = [:]

    init(fields: [FormField]) {
        self.fields = fields
        self.fieldByKey = [:]
        for (index, field) in fields.enumerated() {
            fieldByKey[field.key] = field
            indexByKey[field.key] = index
            seed(field)
        }
    }

    /// Seeds one field's buffer to its HOST state: the declared
    /// default where given, else the empty/unset state (a required
    /// boolean starts `.unset` — the host rejects a required key with
    /// no value — while an optional toggle starts at its visible OFF).
    /// `init` and `clearInactive()` share this, so a cleared field
    /// returns to EXACTLY its initial state.
    private mutating func seed(_ field: FormField) {
        switch field {
        case .string(let f):
            texts[f.key] = f.default ?? ""
        case .number(let f):
            // A host may name a non-finite default the client can
            // DECODE but no person can enter: seeding the literal
            // "nan" would fail parseNumber on an untouched field
            // and block submission. Such a default seeds an empty
            // buffer — unanswered and honestly validated.
            numbers[f.key] = f.default.flatMap {
                $0.isNaN ? nil : Self.editingText($0)
            } ?? ""
        case .integer(let f):
            numbers[f.key] = f.default.flatMap {
                $0.isNaN ? nil : Self.editingText($0)
            } ?? ""
        case .boolean(let f):
            // A host default seeds the value; a required boolean
            // without one must be CHOSEN explicitly; an optional
            // toggle starts at (and answers as) its visible OFF —
            // the screen and the submitted value never disagree.
            if let value = f.default {
                bools[f.key] = value ? .on : .off
            } else if f.required == true {
                bools[f.key] = .unset
            } else {
                bools[f.key] = .off
            }
        case .multiselect(let f):
            picks[f.key] = f.default ?? []
        case .external, .unknown:
            break
        }
    }

    // MARK: - Visibility

    /// Whether `field` should render and take an answer: not hidden,
    /// and every `when` entry satisfied (an AND) by the CURRENT draft.
    /// External fields render (as a link) but are never answerable.
    func isActive(_ field: FormField) -> Bool {
        activeFlags()[field.key] ?? false
    }

    /// The active flag for EVERY field, computed in ONE forward pass
    /// over the host's render order. A `when` may only reference an
    /// EARLIER field, so by the time field i is evaluated every flag
    /// and answer it can reference is settled — the whole form costs
    /// one pass (fields × conditions), and `answer()`/`validate()`
    /// share a single pass instead of re-walking per field. Per-field
    /// recursion instead re-walks each referenced field's own
    /// conditions on every visit — Fibonacci-many steps for the
    /// every-field-cites-the-two-before shape a form authoring agent
    /// can produce (~10^8 at 40 fields, on every render and
    /// keystroke). A condition referencing a missing, SELF, or LATER
    /// field is unsatisfied — outside the contract's earlier-fields
    /// rule, and what the index comparison enforces.
    private func activeFlags() -> [String: Bool] {
        var flags: [String: Bool] = [:]
        for (index, field) in fields.enumerated() {
            guard !field.isHidden else {
                flags[field.key] = false
                continue
            }
            flags[field.key] = field.conditions.allSatisfy { when in
                guard let refIndex = indexByKey[when.key], refIndex < index,
                      flags[when.key] == true,
                      let current = currentValue(forKey: when.key, activeFields: flags)
                else { return false }
                return Self.holds(when, against: current)
            }
        }
        return flags
    }

    /// A `when` entry evaluated against a current answer. A condition
    /// referencing a field with no answer is unsatisfied (even `neq`);
    /// over a multiselect answer `eq` means inclusion.
    private static func holds(_ when: FormWhen, against current: FormValue) -> Bool {
        let equal: Bool
        if case .strings(let selected) = current {
            guard case .string(let token) = when.value else { return false }
            equal = selected.contains(token)
        } else {
            equal = current == when.value
        }
        return when.isEqual ? equal : !equal
    }

    /// The draft's current typed answer for `key` under a KNOWN flag
    /// map, or nil when the field is inactive or holds no answer yet
    /// (empty text, unset required boolean, empty selection).
    private func currentValue(forKey key: String, activeFields flags: [String: Bool]) -> FormValue? {
        guard flags[key] == true, let field = fieldByKey[key] else { return nil }
        switch field {
        case .string(let f):
            let text = texts[f.key] ?? ""
            return text.isEmpty ? nil : .string(text)
        case .number, .integer:
            guard let value = Self.parseNumber(numbers[key] ?? "") else { return nil }
            return .number(value)
        case .boolean:
            switch bools[key] ?? .unset {
            case .unset: return nil
            case .on: return .boolean(true)
            case .off: return .boolean(false)
            }
        case .multiselect:
            let selected = picks[key] ?? []
            return selected.isEmpty ? nil : .strings(selected)
        case .external, .unknown:
            return nil
        }
    }

    /// The draft's current typed answer for `key`, or nil when the
    /// field is inactive or holds no answer yet.
    func currentValue(for key: String) -> FormValue? {
        currentValue(forKey: key, activeFields: activeFlags())
    }

    /// Inactive fields are REMOVED from the draft, not merely omitted
    /// from `answer()`: a value typed while the field was visible must
    /// never ride back in when a condition flips off and on again (a
    /// stale safety confirmation would otherwise submit as affirmed
    /// without the person re-choosing it). Each inactive field resets
    /// to exactly its seeded state — `init` and this share `seed(_:)`.
    /// Every edit action below calls this; one forward pass suffices
    /// because conditions only read ACTIVE fields' values, so
    /// clearing inactive buffers cannot change any flag.
    mutating func clearInactive() {
        let flags = activeFlags()
        guard flags.values.contains(false) else { return }
        for field in fields where flags[field.key] != true {
            seed(field)
        }
    }

    // MARK: - Answer assembly

    /// The reply's answer: ONLY active fields with a present value,
    /// typed per the contract (numbers as numbers, booleans as
    /// booleans, selections as string arrays). Inactive fields are
    /// omitted — never sent with stale values (docs/api-contract.md
    /// W10) — and `clearInactive()` additionally wipes their buffers,
    /// so nothing rides back in on a later flip.
    func answer() -> [String: FormValue] {
        let flags = activeFlags()
        var answer: [String: FormValue] = [:]
        for field in fields where flags[field.key] == true {
            if let value = currentValue(forKey: field.key, activeFields: flags) {
                answer[field.key] = value
            }
        }
        return answer
    }

    // MARK: - Validation

    /// Local validation for the ACTIVE fields — required presence,
    /// lengths, a compilable `pattern`, typed parsing, numeric bounds,
    /// and selection bounds/membership. Anything the client cannot
    /// evaluate honestly (a pattern Foundation cannot compile, a
    /// server-side format rule) is left to the host: its 400 is
    /// surfaced beside the field, never masked by a false local pass
    /// or a false local block (S12).
    func validate() -> [String: FieldError] {
        let flags = activeFlags()
        var errors: [String: FieldError] = [:]
        for field in fields where flags[field.key] == true {
            switch field {
            case .string(let f):
                let text = texts[f.key] ?? ""
                if text.isEmpty {
                    if f.required == true { errors[f.key] = FieldError(message: "This field is required.") }
                    continue
                }
                if let min = f.minLength, text.count < min {
                    errors[f.key] = FieldError(message: "Use at least \(min) characters.")
                } else if let max = f.maxLength, text.count > max {
                    errors[f.key] = FieldError(message: "Use at most \(max) characters.")
                } else if let pattern = f.pattern, let regex = try? NSRegularExpression(pattern: pattern) {
                    // An uncompilable pattern is left to the host —
                    // never claimed as locally validated.
                    let range = NSRange(text.startIndex..., in: text)
                    if regex.firstMatch(in: text, range: range) == nil {
                        errors[f.key] = FieldError(message: "Use a value matching the required format.")
                    }
                } else if let options = f.options, f.custom != true,
                          !options.contains(where: { $0.value == text }) {
                    errors[f.key] = FieldError(message: "Choose one of the provided options.")
                }
            case .number(let f):
                validateNumber(key: f.key, isInteger: false, required: f.required == true,
                               minimum: f.minimum, maximum: f.maximum, into: &errors)
            case .integer(let f):
                validateNumber(key: f.key, isInteger: true, required: f.required == true,
                               minimum: f.minimum, maximum: f.maximum, into: &errors)
            case .boolean(let f):
                if f.required == true, bools[f.key] ?? .unset == .unset {
                    errors[f.key] = FieldError(message: "Choose yes or no.")
                }
            case .multiselect(let f):
                let selected = picks[f.key] ?? []
                if selected.isEmpty {
                    if f.required == true {
                        errors[f.key] = FieldError(message: "Select at least one option.")
                    }
                    continue
                }
                if let min = f.minItems, selected.count < min {
                    errors[f.key] = FieldError(message: "Select at least \(min) options.")
                } else if let max = f.maxItems, selected.count > max {
                    errors[f.key] = FieldError(message: "Select at most \(max) options.")
                } else if f.custom != true,
                          !selected.allSatisfy({ value in f.options.contains { $0.value == value } }) {
                    errors[f.key] = FieldError(message: "Choose only from the provided options.")
                }
            case .external, .unknown:
                continue
            }
        }
        return errors
    }

    private func validateNumber(
        key: String, isInteger: Bool, required: Bool,
        minimum: Double?, maximum: Double?,
        into errors: inout [String: FieldError]
    ) {
        let raw = numbers[key] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if required { errors[key] = FieldError(message: "This field is required.") }
            return
        }
        guard let value = Self.parseNumber(trimmed) else {
            errors[key] = FieldError(message: "Enter a valid number.")
            return
        }
        if isInteger, !value.isFinite || value != value.rounded(.towardZero) {
            errors[key] = FieldError(message: "Enter a whole number.")
            return
        }
        if let minimum, value < minimum {
            errors[key] = FieldError(message: "Use at least \(Self.editingText(minimum)).")
        } else if let maximum, value > maximum {
            errors[key] = FieldError(message: "Use at most \(Self.editingText(maximum)).")
        }
    }

    // MARK: - Parsing

    /// Parses numeric input: trims, then accepts BOTH the region's
    /// decimal separator (the decimal pad shows `,` in de/fr/es/nl —
    /// `Double("3,5")` alone would reject every fractional value
    /// there) and the wire's `.`, which is what the host's defaults
    /// always use. Empty and NaN stay invalid; ±infinity parses — the
    /// wire's named non-finite bounds are real values the host
    /// enforces.
    static func parseNumber(
        _ raw: String,
        decimalSeparator: String = Locale.current.decimalSeparator ?? "."
    ) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if decimalSeparator != "." {
            text = text.replacingOccurrences(of: decimalSeparator, with: ".")
        }
        guard let value = Double(text), !value.isNaN else { return nil }
        return value
    }

    // MARK: - Editing actions

    /// Every buffer write in the sheet goes through these mutating
    /// actions — never a direct dictionary write — and each one ends
    /// in `clearInactive()`, so the "inactive fields hold no value"
    /// contract cannot be bypassed by a call site. Only ACTIVE fields
    /// render inputs, so the edited field is never the one cleared.

    /// Replaces a string field's buffer (typed text, or the value of
    /// a chosen option).
    mutating func setText(_ key: String, _ value: String) {
        texts[key] = value
        clearInactive()
    }

    /// Replaces a numeric field's editing buffer (raw text — parsed
    /// at answer/validation time).
    mutating func setNumber(_ key: String, _ raw: String) {
        numbers[key] = raw
        clearInactive()
    }

    /// Replaces a boolean field's tri-state.
    mutating func setBoolean(_ key: String, _ value: Toggle) {
        bools[key] = value
        clearInactive()
    }

    /// Selects/deselects a multiselect option — unique by
    /// construction, order preserved as chosen.
    mutating func toggle(_ key: String, _ value: String) {
        var selected = picks[key] ?? []
        if let index = selected.firstIndex(of: value) {
            selected.remove(at: index)
        } else {
            selected.append(value)
        }
        picks[key] = selected
        clearInactive()
    }

    /// Adds a typed value to a `custom` multiselect (blank is a no-op,
    /// duplicates never multiply — the host rejects both).
    mutating func addCustom(_ key: String, _ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var selected = picks[key] ?? []
        guard !selected.contains(value) else { return }
        selected.append(value)
        picks[key] = selected
        clearInactive()
    }

    // MARK: - Presentation helpers

    func title(for key: String) -> String {
        fieldByKey[key]?.title ?? key
    }

    /// Schema-derived constraints shown beside the field (S12: the
    /// validation rules are visible) — only what the schema states,
    /// never a claim about checks the client does not perform.
    static func constraints(for field: FormField) -> String? {
        var parts: [String] = []
        if field.isRequired { parts.append("Required") }
        switch field {
        case .string(let f):
            switch (f.minLength, f.maxLength) {
            case (let min?, let max?): parts.append("\(min)–\(max) characters")
            case (let min?, nil): parts.append("At least \(min) characters")
            case (nil, let max?): parts.append("At most \(max) characters")
            case (nil, nil): break
            }
            if let options = f.options, !options.isEmpty, f.custom != true {
                parts.append("One of the options below")
            }
        case .number(let f):
            parts += boundsText(minimum: f.minimum, maximum: f.maximum)
        case .integer(let f):
            parts.append("Whole number")
            parts += boundsText(minimum: f.minimum, maximum: f.maximum)
        case .multiselect(let f):
            if let min = f.minItems, let max = f.maxItems {
                parts.append("Choose \(min)–\(max)")
            } else if let min = f.minItems {
                parts.append("Choose at least \(min)")
            } else if let max = f.maxItems {
                parts.append("Choose up to \(max)")
            }
            if f.custom == true { parts.append("Custom values allowed") }
        case .boolean, .external, .unknown:
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func boundsText(minimum: Double?, maximum: Double?) -> [String] {
        switch (minimum, maximum) {
        case (let min?, let max?) where min == max:
            return ["Must be \(displayNumber(min))"]
        case (let min?, let max?):
            return ["Between \(displayNumber(min)) and \(displayNumber(max))"]
        case (let min?, nil):
            return ["At least \(displayNumber(min))"]
        case (nil, let max?):
            return ["At most \(displayNumber(max))"]
        case (nil, nil):
            return []
        }
    }

    /// A bound as SHOWN to the user: the wire's named non-finite
    /// bounds print as the mathematical symbol, never a raw `inf`
    /// (the editing buffer keeps `editingText`'s parseable form).
    private static func displayNumber(_ value: Double) -> String {
        if value == .infinity { return "∞" }
        if value == -.infinity { return "-∞" }
        return editingText(value)
    }

    /// The editing buffer for a typed default, and the text shown for
    /// a bound — whole numbers print without a trailing ".0".
    static func editingText(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(.towardZero),
           let whole = Int64(exactly: value) {
            return String(whole)
        }
        return String(value)
    }
}
