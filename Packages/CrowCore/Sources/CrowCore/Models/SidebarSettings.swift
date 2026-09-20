import Foundation

/// Sidebar display preferences.
public struct SidebarSettings: Codable, Sendable, Equatable {
    public var hideSessionDetails: Bool

    public init(hideSessionDetails: Bool = false) {
        self.hideSessionDetails = hideSessionDetails
    }

    /// Per-key defaults, matching `ConfigDefaults` and `TerminalSettings`.
    /// `AppConfig`'s `decodeIfPresent` only tolerates a wholly *absent* block —
    /// a present-but-partial one (`{"sidebar": {}}`) would throw `keyNotFound`
    /// and fail the entire config decode (CROW-814).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideSessionDetails = try c.decodeIfPresent(Bool.self, forKey: .hideSessionDetails) ?? false
    }

    enum CodingKeys: String, CodingKey { case hideSessionDetails }
}
