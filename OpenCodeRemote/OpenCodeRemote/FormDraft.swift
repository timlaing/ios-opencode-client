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
///   from the draft — never submitted with stale values.
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
        for field in fields {
            fieldByKey[field.key] = field
            switch field {
            case .string(let f):
                texts[f.key] = f.default ?? ""
            case .number(let f):
                numbers[f.key] = f.default.map(Self.editingText) ?? ""
            case .integer(let f):
                numbers[f.key] = f.default.map(Self.editingText) ?? ""
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
                continue
            }
        }
    }

    // MARK: - Visibility

    /// Whether `field` should render and take an answer: not hidden,
    /// and every `when` entry satisfied (an AND) by the CURRENT draft.
    /// External fields render (as a link) but are never answerable.
    func isActive(_ field: FormField) -> Bool {
        if field.isHidden { return false }
        return field.conditions.allSatisfy { conditionHolds($0) }
    }

    /// A `when` entry evaluated against the CURRENT draft. A condition
    /// referencing a field with no answer is unsatisfied (even `neq`);
    /// over a multiselect answer `eq` means inclusion.
    private func conditionHolds(_ when: FormWhen) -> Bool {
        guard let current = currentValue(for: when.key) else { return false }
        let equal: Bool
        if case .strings(let selected) = current {
            guard case .string(let token) = when.value else { return false }
            equal = selected.contains(token)
        } else {
            equal = current == when.value
        }
        return when.isEqual ? equal : !equal
    }

    /// The draft's current typed answer for `key`, or nil when the
    /// field holds no answer yet (empty text, unset required boolean,
    /// empty selection). Conditions and answer assembly both read this
    /// — inactive fields answer nothing.
    func currentValue(for key: String) -> FormValue? {
        guard let field = fieldByKey[key], isActive(field) else { return nil }
        switch field {
        case .string(let f):
            let text = texts[f.key] ?? ""
            return text.isEmpty ? nil : .string(text)
        case .number, .integer:
            let raw = numbers[key] ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let value = Double(trimmed), !value.isNaN else { return nil }
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

    // MARK: - Answer assembly

    /// The reply's answer: ONLY active fields with a present value,
    /// typed per the contract (numbers as numbers, booleans as
    /// booleans, selections as string arrays). Inactive fields are
    /// omitted — never sent with stale values (docs/api-contract.md
    /// W10).
    func answer() -> [String: FormValue] {
        var answer: [String: FormValue] = [:]
        for field in fields where isActive(field) {
            if let value = currentValue(for: field.key) {
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
        var errors: [String: FieldError] = [:]
        for field in fields where isActive(field) {
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
        guard let value = Double(trimmed), !value.isNaN else {
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

    // MARK: - Editing actions

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
            return ["Must be \(editingText(min))"]
        case (let min?, let max?):
            return ["Between \(editingText(min)) and \(editingText(max))"]
        case (let min?, nil):
            return ["At least \(editingText(min))"]
        case (nil, let max?):
            return ["At most \(editingText(max))"]
        case (nil, nil):
            return []
        }
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
