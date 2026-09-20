import Foundation

/// Auto-cleanup settings for completed and archived sessions.
public struct CleanupConfig: Codable, Sendable, Equatable {
    /// Whether auto-cleanup is enabled. Disabled by default.
    public var enabled: Bool
    /// Hours to retain completed/archived sessions before deletion.
    public var retentionHours: Int

    public init(enabled: Bool = false, retentionHours: Int = 24) {
        self.enabled = enabled
        self.retentionHours = retentionHours
    }

    /// Per-key defaults — see `SidebarSettings.init(from:)` (CROW-814).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        retentionHours = try c.decodeIfPresent(Int.self, forKey: .retentionHours) ?? 24
    }

    enum CodingKeys: String, CodingKey { case enabled, retentionHours }
}
