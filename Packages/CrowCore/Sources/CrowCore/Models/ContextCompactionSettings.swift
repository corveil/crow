import Foundation

/// Context size and pre-expiry compaction (CROW-1493).
///
/// Claude Code writes its prompt cache with a lifetime (an hour, as measured
/// on Crow sessions). A session resumed after that re-writes its whole context
/// at the cache-write price instead of reading it at the cache-read price, and
/// on a session carrying hundreds of thousands of tokens that one rebuild is
/// the expensive part of the next message.
///
/// With ``autoCompact`` on, Crow types `/compact` into a large, idle Claude
/// Code session shortly before its cache expires. The compaction call reads
/// the still-warm cache, so a later resume writes a small cache instead of a
/// large one. **Compaction loses detail**: the agent keeps a summary of the
/// conversation, not the conversation, so it can forget a file it read, a
/// decision's reasoning or an instruction given early on. That is why this is
/// off by default. See `docs/context-compaction.md`.
///
/// ``minContextTokens`` also marks a session's context as large in
/// `get-session` / `list-sessions` (`context.large`) and in the sidebar, with
/// auto-compaction on or off.
public struct ContextCompactionSettings: Codable, Sendable, Equatable {
    /// Send `/compact` to eligible sessions. Off by default.
    public var autoCompact: Bool
    /// Only sessions whose context is at least this many tokens are compacted
    /// (and marked large).
    public var minContextTokens: Int
    /// Compact once a session has been idle this many minutes since its last
    /// model call, and only while its cache is still warm (idle shorter than
    /// the cache lifetime the transcript records). With Claude Code's 1-hour
    /// cache the default leaves ten minutes of margin.
    public var idleMinutes: Int

    public static let defaultMinContextTokens = 200_000
    public static let defaultIdleMinutes = 50
    /// Accepted ranges, enforced by `crow automation set` and clamped when
    /// read (a hand-edited or web-saved config can hold anything).
    public static let minContextTokensRange = 10_000...10_000_000
    public static let idleMinutesRange = 1...1_440

    public init(
        autoCompact: Bool = false,
        minContextTokens: Int = ContextCompactionSettings.defaultMinContextTokens,
        idleMinutes: Int = ContextCompactionSettings.defaultIdleMinutes
    ) {
        self.autoCompact = autoCompact
        self.minContextTokens = minContextTokens
        self.idleMinutes = idleMinutes
    }

    /// Tolerant like `SidebarSettings`: a present-but-partial block must not
    /// fail the whole config decode (CROW-814).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoCompact = try c.decodeIfPresent(Bool.self, forKey: .autoCompact) ?? false
        minContextTokens = try c.decodeIfPresent(Int.self, forKey: .minContextTokens)
            ?? Self.defaultMinContextTokens
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? Self.defaultIdleMinutes
    }

    enum CodingKeys: String, CodingKey { case autoCompact, minContextTokens, idleMinutes }

    /// ``minContextTokens`` clamped to ``minContextTokensRange``.
    public var effectiveMinContextTokens: Int {
        min(max(minContextTokens, Self.minContextTokensRange.lowerBound), Self.minContextTokensRange.upperBound)
    }

    /// ``idleMinutes`` clamped to ``idleMinutesRange``, in seconds.
    public var effectiveIdleSeconds: TimeInterval {
        TimeInterval(min(max(idleMinutes, Self.idleMinutesRange.lowerBound), Self.idleMinutesRange.upperBound) * 60)
    }
}
