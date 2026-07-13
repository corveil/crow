import Foundation

/// One reconstructed turn of a session: metric rows segmented between
/// successive `claude_code.user_prompt` events (ADR 0008 follow-up 7).
///
/// Values are per-turn sums of the stored delta rows, so they aggregate
/// exactly: summing a field across all turns reproduces the corresponding
/// `SessionAnalytics` total.
public struct TurnAnalytics: Codable, Equatable, Sendable {
    /// Zero-based position of the turn within the session.
    public var turnIndex: Int
    /// Input tokens (from `claude_code.token.usage` where type=input).
    public var inputTokens: Int
    /// Output tokens (from `claude_code.token.usage` where type=output).
    public var outputTokens: Int
    /// Cache read tokens (from `claude_code.token.usage` where type=cacheRead).
    public var cacheReadTokens: Int
    /// Cache creation tokens (from `claude_code.token.usage` where type=cacheCreation).
    public var cacheCreationTokens: Int
    /// Cost in USD (from `claude_code.cost.usage`).
    public var cost: Double

    /// Approximate context size at this turn (fresh input plus cache reads).
    /// Stored rows are export-granularity deltas, so a turn spanning multiple
    /// API requests sums their contexts — this upper-bounds the true size.
    public var contextTokenEstimate: Int { inputTokens + cacheReadTokens }

    public init(
        turnIndex: Int,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cost: Double = 0
    ) {
        self.turnIndex = turnIndex
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cost = cost
    }
}
