import Foundation

/// A server event frame from `/api/event`. `server.connected` carries
/// `{id, type: "server.connected", data: {}}`; other native events normally
/// carry id, created, type, and data. Unknown event types must decode into the
/// generic form and never crash (docs/api-contract.md).
public struct OpenCodeEvent: Codable, Equatable, Sendable {
    public var id: String?
    public var created: Int64?
    public var type: String?
    public var data: JSONValue?
    public var location: JSONValue?
    public var metadata: JSONValue?
    public var durable: JSONValue?

    public init(
        id: String? = nil,
        created: Int64? = nil,
        type: String? = nil,
        data: JSONValue? = nil,
        location: JSONValue? = nil,
        metadata: JSONValue? = nil,
        durable: JSONValue? = nil
    ) {
        self.id = id
        self.created = created
        self.type = type
        self.data = data
        self.location = location
        self.metadata = metadata
        self.durable = durable
    }

    /// Decodes an SSE `data:` payload into an event. Returns nil for payloads
    /// that are not event objects (e.g. stray frames).
    public static func parse(dataPayload: String) -> OpenCodeEvent? {
        guard let payloadData = dataPayload.data(using: .utf8) else { return nil }
        return try? OpenCodeAPI.decoder.decode(OpenCodeEvent.self, from: payloadData)
    }
}
