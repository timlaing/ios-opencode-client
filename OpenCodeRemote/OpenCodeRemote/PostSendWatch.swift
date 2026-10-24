/// The post-send watch cadence shared by the admission (form) and answer
/// (approval) send paths: a bounded ~2-minute window per send, polling
/// session status as a best-effort supplement until the live event stream
/// (W16) replaces it. Both libraries keep their own watch state; the
/// cadence lives here so the two copies cannot drift apart.
enum PostSendWatch {
    nonisolated static let attempts = 30
    nonisolated static let intervalNanoseconds: UInt64 = 4_000_000_000
}
