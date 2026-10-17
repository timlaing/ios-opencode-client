import Foundation

/// Transport boundary between the app/extension and an OpenCode host
/// (docs/api-contract.md). The URLSession-backed implementation and the
/// mock-backed implementation used for previews/tests both conform.
public protocol OpenCodeTransport: Sendable {
    func perform(_ request: APIRequest) async throws -> APIResponse
    func events() -> AsyncThrowingStream<OpenCodeEvent, Error>
}
