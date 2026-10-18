import Foundation

/// `Form.Option` (S12): a selectable choice — `value` is the token that
/// goes into an answer, `label` is what the user sees; `description`
/// adds context beside it.
public struct FormOption: Codable, Equatable, Sendable {
    public var value: String
    public var label: String
    public var description: String?

    public init(value: String, label: String, description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }
}

/// `Form.Value` — a typed answer value: string, number, boolean, or a
/// multiselect's string array. The wire's named non-finite numbers
/// ("Infinity"/"-Infinity"/"NaN") decode to `.number` so numerics stay
/// TYPED (S12: numeric fields preserve typed values, never numeric
/// strings) and round-trip back to the identical named string; a
/// free-text answer of exactly one of those three names is the wire's
/// one accepted ambiguity, with an identical encoding either way.
public enum FormValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case strings([String])
}

extension FormValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters only for the named non-finite strings: numbers
        // and booleans never arrive as strings in this union, so the
        // typed cases can be tried first and the names last.
        if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode([String].self) { self = .strings(value); return }
        switch try container.decode(String.self) {
        case "Infinity": self = .number(.infinity)
        case "-Infinity": self = .number(-.infinity)
        case "NaN": self = .number(.nan)
        case let value: self = .string(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .strings(let value):
            try container.encode(value)
        case .number(let value):
            if value.isNaN {
                try container.encode("NaN")
            } else if value == .infinity {
                try container.encode("Infinity")
            } else if value == -.infinity {
                try container.encode("-Infinity")
            } else {
                try container.encode(value)
            }
        }
    }
}

/// `Form.When` — a visibility condition over an EARLIER field. A
/// field's `when` list is an AND over its entries (docs/api-contract.md
/// W10); `op` is a known-state string with helpers (the baseline
/// defines eq/neq only); for a multiselect answer `eq` means the value
/// is INCLUDED, and a condition whose referenced field has no answer is
/// unsatisfied.
public struct FormWhen: Codable, Equatable, Sendable {
    public var key: String
    public var op: String
    public var value: FormValue

    public init(key: String, op: String, value: FormValue) {
        self.key = key
        self.op = op
        self.value = value
    }

    /// The only operations this baseline defines.
    public var isEqual: Bool { op == "eq" }
    public var isNotEqual: Bool { op == "neq" }
}

/// `Form.StringField` — free text, or a single choice when `options`
/// are present (without `custom`, answers are constrained to the
/// option values). `format`/`pattern`/bounds are enforced by the host
/// too; the client applies only what it can evaluate honestly (S12).
public struct FormStringField: Codable, Equatable, Sendable {
    public var key: String
    public var title: String?
    public var description: String?
    public var required: Bool?
    public var hidden: Bool?
    public var when: [FormWhen]?
    public var format: String?
    public var minLength: Int?
    public var maxLength: Int?
    public var pattern: String?
    public var placeholder: String?
    public var `default`: String?
    public var options: [FormOption]?
    public var custom: Bool?

    public init(
        key: String, title: String? = nil, description: String? = nil,
        required: Bool? = nil, hidden: Bool? = nil, when: [FormWhen]? = nil,
        format: String? = nil, minLength: Int? = nil, maxLength: Int? = nil,
        pattern: String? = nil, placeholder: String? = nil,
        `default`: String? = nil, options: [FormOption]? = nil, custom: Bool? = nil
    ) {
        self.key = key
        self.title = title
        self.description = description
        self.required = required
        self.hidden = hidden
        self.when = when
        self.format = format
        self.minLength = minLength
        self.maxLength = maxLength
        self.pattern = pattern
        self.placeholder = placeholder
        self.default = `default`
        self.options = options
        self.custom = custom
    }
}

/// `Form.NumberField` — a real number; `minimum`/`maximum`/`default`
/// may also be the wire's named non-finite values, decoded to typed
/// `Double` bounds (so ±Infinity stays usable in validation).
public struct FormNumberField: Codable, Equatable, Sendable {
    public var key: String
    public var title: String?
    public var description: String?
    public var required: Bool?
    public var hidden: Bool?
    public var when: [FormWhen]?
    public var minimum: Double?
    public var maximum: Double?
    public var `default`: Double?

    public init(
        key: String, title: String? = nil, description: String? = nil,
        required: Bool? = nil, hidden: Bool? = nil, when: [FormWhen]? = nil,
        minimum: Double? = nil, maximum: Double? = nil, `default`: Double? = nil
    ) {
        self.key = key
        self.title = title
        self.description = description
        self.required = required
        self.hidden = hidden
        self.when = when
        self.minimum = minimum
        self.maximum = maximum
        self.default = `default`
    }
}

/// `Form.IntegerField` — a whole number with the same typed bounds.
public struct FormIntegerField: Codable, Equatable, Sendable {
    public var key: String
    public var title: String?
    public var description: String?
    public var required: Bool?
    public var hidden: Bool?
    public var when: [FormWhen]?
    public var minimum: Double?
    public var maximum: Double?
    public var `default`: Double?

    public init(
        key: String, title: String? = nil, description: String? = nil,
        required: Bool? = nil, hidden: Bool? = nil, when: [FormWhen]? = nil,
        minimum: Double? = nil, maximum: Double? = nil, `default`: Double? = nil
    ) {
        self.key = key
        self.title = title
        self.description = description
        self.required = required
        self.hidden = hidden
        self.when = when
        self.minimum = minimum
        self.maximum = maximum
        self.default = `default`
    }
}

/// `Form.BooleanField` — a toggle. When `required` and no `default`
/// exists, the user must choose explicitly (an untouched required
/// boolean has no answer and the host rejects it).
public struct FormBooleanField: Codable, Equatable, Sendable {
    public var key: String
    public var title: String?
    public var description: String?
    public var required: Bool?
    public var hidden: Bool?
    public var when: [FormWhen]?
    public var `default`: Bool?

    public init(
        key: String, title: String? = nil, description: String? = nil,
        required: Bool? = nil, hidden: Bool? = nil, when: [FormWhen]? = nil,
        `default`: Bool? = nil
    ) {
        self.key = key
        self.title = title
        self.description = description
        self.required = required
        self.hidden = hidden
        self.when = when
        self.default = `default`
    }
}

/// `Form.MultiselectField` — independently selectable option values
/// (`options` required by the schema), bounded by `minItems`/`maxItems`
/// with unique values; `custom` additionally allows typed values.
public struct FormMultiselectField: Codable, Equatable, Sendable {
    public var key: String
    public var title: String?
    public var description: String?
    public var required: Bool?
    public var hidden: Bool?
    public var when: [FormWhen]?
    public var options: [FormOption]
    public var minItems: Int?
    public var maxItems: Int?
    public var custom: Bool?
    public var `default`: [String]?

    public init(
        key: String, title: String? = nil, description: String? = nil,
        required: Bool? = nil, hidden: Bool? = nil, when: [FormWhen]? = nil,
        options: [FormOption], minItems: Int? = nil, maxItems: Int? = nil,
        custom: Bool? = nil, `default`: [String]? = nil
    ) {
        self.key = key
        self.title = title
        self.description = description
        self.required = required
        self.hidden = hidden
        self.when = when
        self.options = options
        self.minItems = minItems
        self.maxItems = maxItems
        self.custom = custom
        self.default = `default`
    }
}

/// `Form.ExternalField` — a link opened in the SYSTEM browser. It has
/// no answer: external fields never take part in validation (their
/// answer is the browser itself) and are omitted from every reply.
public struct FormExternalField: Codable, Equatable, Sendable {
    public var key: String
    public var title: String?
    public var description: String?
    public var url: String

    public init(key: String, title: String? = nil, description: String? = nil, url: String) {
        self.key = key
        self.title = title
        self.description = description
        self.url = url
    }
}

/// `Form.Field` — the discriminated union, switched on `type`. A field
/// type this baseline does not define keeps its full raw payload and
/// renders as unsupported rather than being dropped or guessed
/// (docs/api-contract.md W10).
public enum FormField: Equatable, Sendable {
    case string(FormStringField)
    case number(FormNumberField)
    case integer(FormIntegerField)
    case boolean(FormBooleanField)
    case multiselect(FormMultiselectField)
    case external(FormExternalField)
    case unknown(type: String, raw: [String: JSONValue])
}

extension FormField: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "string": self = .string(try FormStringField(from: decoder))
        case "number": self = .number(try FormNumberField(from: decoder))
        case "integer": self = .integer(try FormIntegerField(from: decoder))
        case "boolean": self = .boolean(try FormBooleanField(from: decoder))
        case "multiselect": self = .multiselect(try FormMultiselectField(from: decoder))
        case "external": self = .external(try FormExternalField(from: decoder))
        default: self = .unknown(type: type, raw: try [String: JSONValue](from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let field): try field.encode(to: encoder)
        case .number(let field): try field.encode(to: encoder)
        case .integer(let field): try field.encode(to: encoder)
        case .boolean(let field): try field.encode(to: encoder)
        case .multiselect(let field): try field.encode(to: encoder)
        case .external(let field): try field.encode(to: encoder)
        case .unknown(_, let raw): try raw.encode(to: encoder)
        }
    }

    /// Field identity — every kind carries its wire `key` (an unknown
    /// kind reads it from the raw payload when present).
    public var key: String {
        switch self {
        case .string(let f): return f.key
        case .number(let f): return f.key
        case .integer(let f): return f.key
        case .boolean(let f): return f.key
        case .multiselect(let f): return f.key
        case .external(let f): return f.key
        case .unknown(_, let raw):
            if case .string(let value)? = raw["key"] { return value }
            return ""
        }
    }

    /// Display title — falls back to the key when the host omits one
    /// (an unknown kind reads its own raw payload for both).
    public var title: String? {
        switch self {
        case .string(let f): return f.title ?? f.key
        case .number(let f): return f.title ?? f.key
        case .integer(let f): return f.title ?? f.key
        case .boolean(let f): return f.title ?? f.key
        case .multiselect(let f): return f.title ?? f.key
        case .external(let f): return f.title ?? f.key
        case .unknown(_, let raw):
            if case .string(let value)? = raw["title"] { return value }
            if case .string(let value)? = raw["key"] { return value }
            return nil
        }
    }

    /// Field help text (wire `description`) — carried through for an
    /// unknown kind too, so the renderer can still explain the row.
    public var fieldDescription: String? {
        switch self {
        case .string(let f): return f.description
        case .number(let f): return f.description
        case .integer(let f): return f.description
        case .boolean(let f): return f.description
        case .multiselect(let f): return f.description
        case .external(let f): return f.description
        case .unknown(_, let raw):
            if case .string(let value)? = raw["description"] { return value }
            return nil
        }
    }

    /// A required field demands an answer while ACTIVE (docs W10).
    /// External and unknown kinds are never answer fields.
    public var isRequired: Bool {
        switch self {
        case .string(let f): return f.required == true
        case .number(let f): return f.required == true
        case .integer(let f): return f.required == true
        case .boolean(let f): return f.required == true
        case .multiselect(let f): return f.required == true
        case .external, .unknown: return false
        }
    }

    /// Hidden fields take no answer and are not rendered (wire rule).
    public var isHidden: Bool {
        switch self {
        case .string(let f): return f.hidden == true
        case .number(let f): return f.hidden == true
        case .integer(let f): return f.hidden == true
        case .boolean(let f): return f.hidden == true
        case .multiselect(let f): return f.hidden == true
        case .external, .unknown: return false
        }
    }

    /// Visibility conditions (AND) — external kinds have none.
    public var conditions: [FormWhen] {
        switch self {
        case .string(let f): return f.when ?? []
        case .number(let f): return f.when ?? []
        case .integer(let f): return f.when ?? []
        case .boolean(let f): return f.when ?? []
        case .multiselect(let f): return f.when ?? []
        case .external, .unknown: return []
        }
    }

    /// The renderer's shortcut for the system-browser link row.
    public var isExternal: Bool {
        if case .external = self { return true }
        return false
    }
}

/// `Form.Info` (S12): a pending form — identity, ordered field
/// definitions, and free-form metadata. `sessionID` is a PLAIN string:
/// the schema permits a non-session MCP-owner sentinel, so no `ses`
/// prefix is enforced anywhere (docs/api-contract.md W10).
public struct FormInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var title: String
    public var metadata: [String: JSONValue]?
    public var fields: [FormField]

    public init(
        id: String, sessionID: String, title: String,
        metadata: [String: JSONValue]? = nil, fields: [FormField]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.metadata = metadata
        self.fields = fields
    }
}

/// `Form.State` — the detail's lifecycle: `pending`; `answered` (with
/// the submitted answer); `cancelled` (optional message). An unknown
/// status keeps its raw payload and is never claimed as pending.
public enum FormState: Equatable, Sendable {
    case pending
    case answered(answer: [String: FormValue])
    case cancelled(message: String?)
    case unknown(status: String, raw: [String: JSONValue])

    /// Settled forms are never editable again (S12): anything but a
    /// pending state shows its authoritative result.
    public var isSettled: Bool {
        if case .pending = self { return false }
        return true
    }
}

extension FormState: Codable {
    private enum CodingKeys: String, CodingKey {
        case status, answer, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "pending":
            self = .pending
        case "answered":
            self = .answered(answer: try container.decode([String: FormValue].self, forKey: .answer))
        case "cancelled":
            self = .cancelled(message: try container.decodeIfPresent(String.self, forKey: .message))
        case let unknown:
            self = .unknown(status: unknown, raw: try [String: JSONValue](from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending:
            try container.encode("pending", forKey: .status)
        case .answered(let answer):
            try container.encode("answered", forKey: .status)
            try container.encode(answer, forKey: .answer)
        case .cancelled(let message):
            try container.encode("cancelled", forKey: .status)
            try container.encodeIfPresent(message, forKey: .message)
        case .unknown(let status, let raw):
            // Unknown statuses ride their raw payload through untouched.
            var nested = raw
            nested["status"] = .string(status)
            try nested.encode(to: encoder)
        }
    }
}

/// `Form.Detail` — the single-form read: identity + fields + `state`.
/// S12 renders from this and re-reads it after a 409 to show the
/// authoritative settled state.
public struct FormDetail: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String
    public var title: String
    public var metadata: [String: JSONValue]?
    public var fields: [FormField]
    public var state: FormState

    public init(
        id: String, sessionID: String, title: String,
        metadata: [String: JSONValue]? = nil, fields: [FormField], state: FormState
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.metadata = metadata
        self.fields = fields
        self.state = state
    }
}

/// `{data:[Form.Info]}` — BOTH list routes' payload: the session-scoped
/// list wraps it plainly and the location-wide route adds `location`
/// beside `data`; a decoder of `data` alone reads both honestly (the
/// W09 list pattern).
public struct FormListResponse: Decodable, Equatable, Sendable {
    public var data: [FormInfo]

    public init(data: [FormInfo]) {
        self.data = data
    }
}

/// `{data:Form.Detail}` — the single-form read.
public struct FormDetailResponse: Decodable, Equatable, Sendable {
    public var data: FormDetail

    public init(data: FormDetail) {
        self.data = data
    }
}

/// The reply body `{answer:{<field-key>:<typed-value>}}`. INACTIVE
/// fields are omitted from the map entirely — never sent with stale
/// values (docs/api-contract.md W10).
public struct FormReplyBody: Encodable, Equatable, Sendable {
    public var answer: [String: FormValue]

    public init(answer: [String: FormValue]) {
        self.answer = answer
    }
}

/// W10 form request builders (docs/api-contract.md W10, S12).
/// `session.form.create` exists on the baseline but is OUTSIDE the
/// mobile scope — this client only lists, reads, replies, and cancels.
public enum W10Requests {
    /// `GET /api/session/{sessionID}/form` → `{data:[…]}` — this
    /// session's own pending forms.
    public static func list(sessionID: String, credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "session.form.list",
            method: .get,
            path: "/api/session/\(sessionID)/form",
            credential: credential
        )
    }

    /// `GET /api/form` → `{location:{directory},data:[…]}`: every
    /// pending form in the location, used to find child-session forms
    /// for linked attribution.
    public static func listAll(credential: BasicCredential? = nil) -> APIRequest {
        APIRequest(
            operationID: "form.list",
            method: .get,
            path: "/api/form",
            credential: credential
        )
    }

    /// `GET /api/session/{sessionID}/form/{formID}` → `{data:{…}}` —
    /// the detail (with `state`) the sheet renders; a stale 404 means
    /// the form no longer exists on the host.
    public static func get(
        sessionID: String,
        formID: String,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "session.form.get",
            method: .get,
            path: "/api/session/\(sessionID)/form/\(formID)",
            credential: credential
        )
    }

    /// `POST /api/session/{sessionID}/form/{formID}/reply` with
    /// `{answer}` → 204. FormService maps the distinct failures: 400
    /// FormInvalidAnswerError, 404 FormNotFoundError, 409
    /// FormAlreadySettledError.
    public static func reply(
        sessionID: String,
        formID: String,
        answer: [String: FormValue],
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        try APIRequest.jsonBody(
            operationID: "session.form.reply",
            method: .post,
            path: "/api/session/\(sessionID)/form/\(formID)/reply",
            value: FormReplyBody(answer: answer),
            credential: credential
        )
    }

    /// `DELETE /api/session/{sessionID}/form/{formID}?message=…` —
    /// explicit cancellation only (the message rides the query when
    /// given, and is absent entirely when nil).
    public static func cancel(
        sessionID: String,
        formID: String,
        message: String? = nil,
        credential: BasicCredential? = nil
    ) -> APIRequest {
        APIRequest(
            operationID: "session.form.cancel",
            method: .delete,
            path: "/api/session/\(sessionID)/form/\(formID)",
            query: message.map { [QueryPair(key: "message", value: $0)] } ?? [],
            credential: credential
        )
    }
}
