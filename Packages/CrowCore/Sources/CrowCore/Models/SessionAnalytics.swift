import Foundation

/// Aggregated analytics data for a single Crow session, computed from OTLP telemetry.
public struct SessionAnalytics: Codable, Equatable, Sendable {
    /// Total cost in USD (from `claude_code.cost.usage`).
    public var totalCost: Double
    /// Input tokens (from `claude_code.token.usage` where type=input).
    public var inputTokens: Int
    /// Output tokens (from `claude_code.token.usage` where type=output).
    public var outputTokens: Int
    /// Cache read tokens (from `claude_code.token.usage` where type=cacheRead).
    public var cacheReadTokens: Int
    /// Cache creation tokens (from `claude_code.token.usage` where type=cacheCreation).
    public var cacheCreationTokens: Int
    /// Active time in seconds (from `claude_code.active_time.total`).
    public var activeTimeSeconds: Double
    /// Lines of code added (from `claude_code.lines_of_code.count` where type=added).
    public var linesAdded: Int
    /// Lines of code removed (from `claude_code.lines_of_code.count` where type=removed).
    public var linesRemoved: Int
    /// Git commits created (from `claude_code.commit.count`).
    public var commitCount: Int
    /// User prompts submitted (count of `claude_code.user_prompt` events).
    public var promptCount: Int
    /// Tool calls executed (count of `claude_code.tool_result` events).
    public var toolCallCount: Int
    /// API requests made (count of `claude_code.api_request` events).
    public var apiRequestCount: Int
    /// API errors encountered (count of `claude_code.api_error` events).
    public var apiErrorCount: Int

    /// Total tokens across all types.
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// True when no telemetry has been recorded for the session. The SQL
    /// aggregation (`COALESCE(SUM(value), 0)`) returns an all-zeros aggregate
    /// for a session with no rows, so callers persisting snapshots must treat
    /// an empty aggregate as "no data", not as a real measurement.
    public var isEmpty: Bool { self == SessionAnalytics() }

    public init(
        totalCost: Double = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        activeTimeSeconds: Double = 0,
        linesAdded: Int = 0,
        linesRemoved: Int = 0,
        commitCount: Int = 0,
        promptCount: Int = 0,
        toolCallCount: Int = 0,
        apiRequestCount: Int = 0,
        apiErrorCount: Int = 0
    ) {
        self.totalCost = totalCost
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.activeTimeSeconds = activeTimeSeconds
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.commitCount = commitCount
        self.promptCount = promptCount
        self.toolCallCount = toolCallCount
        self.apiRequestCount = apiRequestCount
        self.apiErrorCount = apiErrorCount
    }
}
