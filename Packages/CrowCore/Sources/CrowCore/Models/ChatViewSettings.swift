import Foundation

/// The experimental web Chat view (`docs/web-chat-view.md`). Off by default:
/// while off, the session header shows no Terminal | Chat toggle and the
/// browser never polls a transcript. Set with `crow ui set --chat-view`.
public struct ChatViewSettings: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    /// Tolerant like `SidebarSettings`: a present-but-partial block must not
    /// fail the whole config decode (CROW-814).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    enum CodingKeys: String, CodingKey { case enabled }
}
