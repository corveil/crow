import Foundation

/// Terminal wheel-scroll tuning (CROW-835). The web terminal routes the wheel by
/// surface under ADR-0013's per-surface hybrid model, and the two paths have
/// different natural units, so each gets its own knob. Device normalization
/// (`deltaMode` + sub-notch accumulation) is a fixed client-side concern and is
/// deliberately not configurable — these only scale the resulting notch count.
public struct TerminalSettings: Codable, Sendable, Equatable {
    /// Plain-shell surfaces: local xterm scrollback **lines per physical wheel
    /// notch** (default 3 — the historical hardcoded value).
    public var wheelScrollLines: Int
    /// Agent-TUI surfaces (Claude Code / Cursor / Manager): number of wheel
    /// reports **forwarded to the app per physical notch** (default 1 — one notch
    /// in, one notch out; the app owns its own lines-per-notch). Raise it if agent
    /// scrolling feels too slow.
    public var agentWheelNotches: Int

    public init(wheelScrollLines: Int = 3, agentWheelNotches: Int = 1) {
        self.wheelScrollLines = wheelScrollLines
        self.agentWheelNotches = agentWheelNotches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wheelScrollLines = try c.decodeIfPresent(Int.self, forKey: .wheelScrollLines) ?? 3
        agentWheelNotches = try c.decodeIfPresent(Int.self, forKey: .agentWheelNotches) ?? 1
    }

    enum CodingKeys: String, CodingKey { case wheelScrollLines, agentWheelNotches }
}
