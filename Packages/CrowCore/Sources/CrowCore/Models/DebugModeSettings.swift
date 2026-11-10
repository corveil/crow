import Foundation

/// Debug mode: one switch for diagnostic features that are useful while
/// investigating but too noisy or costly to run for everyone (Settings →
/// About, or `crow ui set --debug-mode`). Off by default, including on
/// existing installs, whose config has no `debugMode` block.
///
/// Features gated by it today:
/// - **Sidebar recording indicator**: the per-session gateway and transcript
///   glyphs, and the Corveil request-log verification behind the gateway
///   glyph (a log read every log-sync tick, ~5 min).
///
/// A new debug feature reads `enabled` rather than adding its own top-level
/// toggle, so the About screen stays the one place to turn them on.
public struct DebugModeSettings: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    /// Tolerant like `ChatViewSettings`: a present-but-partial block must not
    /// fail the whole config decode (CROW-814).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    enum CodingKeys: String, CodingKey { case enabled }
}
