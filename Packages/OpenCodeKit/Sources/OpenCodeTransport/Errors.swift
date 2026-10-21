import Foundation

/// The baseline error envelope: `{_tag, message}` plus tag-specific fields.
/// Extra fields are preserved for forward compatibility.
public struct APIErrorEnvelope: Error, Equatable, Sendable, Decodable {
    public var tag: String
    public var message: String
    public var details: [String: JSONValue]

    public init(from decoder: Decoder) throws {
        let object = try decoder.singleValueContainer().decode([String: JSONValue].self)
        tag = object["_tag"]?.stringValue ?? ""
        message = object["message"]?.stringValue ?? ""
        details = object.filter { $0.key != "_tag" && $0.key != "message" }
    }

    public init(tag: String, message: String, details: [String: JSONValue] = [:]) {
        self.tag = tag
        self.message = message
        self.details = details
    }
}

/// Transport-level failures. HTTP failures carry the status plus, when the body
/// parses as the baseline envelope, the decoded error.
public enum TransportError: Error, Equatable, Sendable {
    case invalidURL
    case http(status: Int, envelope: APIErrorEnvelope?)
    case emptyBody
    case decodingFailed(String)
    case connectionFailed(String)
    case cancelled

    /// 401/403 map to "Re-pair Required" in the UI.
    public var isAuthenticationFailure: Bool {
        guard case .http(let status, _) = self else { return false }
        return status == 401 || status == 403
    }
}
