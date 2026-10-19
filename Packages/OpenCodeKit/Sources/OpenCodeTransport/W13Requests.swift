import Foundation

/// W13 request shapes (docs/api-contract.md W13, S14): manual compaction
/// is `POST /api/session/{sessionID}/compact` with a REQUIRED JSON body
/// whose properties are all optional. The response is a durable
/// `Session.Inbox.Compaction` ADMISSION — the compaction itself runs at
/// the next step boundary and is observed through transcript compaction
/// events plus a context/history refresh (docs/api-contract.md W13:
/// admission is not completion).
public enum W13Requests {
    /// `{id?, delivery?}` — both absent is a valid `{}`: the host picks
    /// the record ID and its documented default delivery. `id` follows
    /// the `msg_` pattern when supplied.
    public struct CompactBody: Codable, Equatable, Sendable {
        public var id: String?
        public var delivery: InboxDelivery?

        public init(id: String? = nil, delivery: InboxDelivery? = nil) {
            self.id = id
            self.delivery = delivery
        }
    }

    /// `POST /api/session/{sessionID}/compact` →
    /// `{data: Session.Inbox.Compaction}`. That wire shape IS an inbox
    /// item (type `compaction`), so the response decodes through the
    /// existing `InboxEnvelope` — no duplicate DTO.
    public static func compact(
        sessionID: String,
        id: String? = nil,
        delivery: InboxDelivery? = nil,
        credential: BasicCredential? = nil
    ) throws -> APIRequest {
        try APIRequest.jsonBody(
            operationID: "session.compact",
            method: .post,
            path: "/api/session/\(sessionID)/compact",
            value: CompactBody(id: id, delivery: delivery),
            credential: credential
        )
    }
}
