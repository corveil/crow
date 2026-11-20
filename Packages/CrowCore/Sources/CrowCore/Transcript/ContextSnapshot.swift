import Foundation

/// How much context a session's agent carries, and how warm its prompt cache
/// is, as of the transcript's latest main-conversation model call (CROW-1493).
///
/// `get-session` / `list-sessions` report it as `context`, the sidebar shows
/// it, and the opt-in pre-expiry compaction (``ContextCompactionSettings``)
/// decides from it. Read from the JSONL the harness already writes, with the
/// same usage rules as the Chat view's context meter (``ChatTranscript``).
public struct ContextSnapshot: Sendable, Equatable {
    /// Prompt tokens of the latest call (Claude: input + cache read + cache
    /// write). After a compaction with no call since, the compaction's own
    /// `postTokens`. Nil only when the transcript ends in a compaction that
    /// didn't record its size.
    public var tokens: Int?
    public var model: String?
    /// The window, from the transcript (Codex) or the model table (Claude).
    public var maxTokens: Int?
    /// When the latest model call (or compaction) was recorded. The prompt
    /// cache is refreshed by every call, so the cache ages from here.
    public var lastRequestAt: Date?
    /// The cache entry lifetime the harness last wrote, from Claude's
    /// `usage.cache_creation` (`ephemeral_1h_input_tokens` → 1h,
    /// `ephemeral_5m_input_tokens` → 5m). Nil when the tail shows neither, and
    /// for Codex, whose caching the transcript doesn't describe.
    public var cacheTTL: TimeInterval?
    /// Set when the transcript's latest record is a compaction boundary: the
    /// conversation was compacted and no model call has happened since.
    public var compactedAt: Date?

    public init(
        tokens: Int?, model: String? = nil, maxTokens: Int? = nil, lastRequestAt: Date? = nil,
        cacheTTL: TimeInterval? = nil, compactedAt: Date? = nil
    ) {
        self.tokens = tokens
        self.model = model
        self.maxTokens = maxTokens
        self.lastRequestAt = lastRequestAt
        self.cacheTTL = cacheTTL
        self.compactedAt = compactedAt
    }

    /// Seconds since the latest call, or nil when its time is unknown.
    public func idleSeconds(now: Date = Date()) -> TimeInterval? {
        lastRequestAt.map { max(0, now.timeIntervalSince($0)) }
    }

    /// Whether the cache entry has likely expired, so the next message
    /// re-writes the whole context instead of reading it. Nil when either the
    /// lifetime or the last call time is unknown. "Likely": the harness can
    /// refresh the cache with calls the transcript doesn't record (a
    /// background summary), which only ever makes it warmer than this says.
    public func cacheLikelyExpired(now: Date = Date()) -> Bool? {
        guard let ttl = cacheTTL, let idle = idleSeconds(now: now) else { return nil }
        return idle >= ttl
    }
}

public enum ContextSnapshotReader {
    /// Bytes read from the end of the transcript on the first try. A Claude
    /// transcript writes a usage record on every model call, so the latest one
    /// is nearly always this close to the end.
    public static let initialTailBytes = 512 * 1_024
    /// Ceiling for the second try, when the first tail held no usage (one huge
    /// tool result can push it further back).
    public static let maxTailBytes = 4 * 1_024 * 1_024

    /// The snapshot as of the end of `path`, or nil when the tail holds no
    /// usage at all (a fresh conversation, or an unsupported file).
    public static func read(
        path: String, format: ChatTranscriptFormat,
        initialTailBytes: Int = ContextSnapshotReader.initialTailBytes,
        maxTailBytes: Int = ContextSnapshotReader.maxTailBytes
    ) throws -> ContextSnapshot? {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        var window = max(1, initialTailBytes)
        while true {
            let start = max(0, size - window)
            try handle.seek(toOffset: UInt64(start))
            let data = try handle.read(upToCount: size - start) ?? Data()
            if let snapshot = snapshot(tail: data, format: format, startsMidLine: start > 0) {
                return snapshot
            }
            if start == 0 || window >= maxTailBytes { return nil }
            window = min(maxTailBytes, window * 4)
        }
    }

    /// Parse an NDJSON tail. `startsMidLine` drops the first (partial) line.
    /// A trailing partial line fails to decode and is skipped. Pure, so the
    /// rules are unit-testable.
    public static func snapshot(
        tail data: Data, format: ChatTranscriptFormat, startsMidLine: Bool = false
    ) -> ContextSnapshot? {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        switch format {
        case .claude: return claude(lines)
        case .codex: return codex(lines)
        }
    }

    // MARK: - Claude Code

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let compactMarker = Data("compact_boundary".utf8)

    private static func claude(_ lines: [Data.SubSequence]) -> ContextSnapshot? {
        var usage: ChatUsage?
        var lastRequestAt: Date?
        var cacheTTL: TimeInterval?
        var compactedAt: Date?
        var postCompactTokens: Int?
        var sawCompactAfterUsage = false
        for line in lines {
            // Most lines are tool output; skip the JSON decode unless the line
            // can matter.
            guard line.range(of: usageMarker) != nil || line.range(of: compactMarker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if obj["type"] as? String == "system", obj["subtype"] as? String == "compact_boundary" {
                guard obj["isSidechain"] as? Bool != true else { continue }
                sawCompactAfterUsage = true
                compactedAt = timestamp(obj) ?? compactedAt
                let meta = obj["compactMetadata"] as? [String: Any]
                postCompactTokens = (meta?["postTokens"] as? NSNumber)?.intValue
                continue
            }
            guard let u = ChatTranscript.claudeUsage(obj) else { continue }
            usage = u
            lastRequestAt = timestamp(obj) ?? lastRequestAt
            if let ttl = claudeCacheTTL(obj) { cacheTTL = ttl }
            sawCompactAfterUsage = false
            compactedAt = nil
            postCompactTokens = nil
        }
        if sawCompactAfterUsage {
            // Compacted, and nothing has been sent since: the context is the
            // compaction's result, not the call before it.
            return ContextSnapshot(
                tokens: postCompactTokens, model: usage?.model,
                maxTokens: ChatContextWindow.maxTokens(model: usage?.model),
                lastRequestAt: compactedAt ?? lastRequestAt, cacheTTL: cacheTTL,
                compactedAt: compactedAt)
        }
        guard let usage else { return nil }
        return ContextSnapshot(
            tokens: usage.usedTokens, model: usage.model,
            maxTokens: ChatContextWindow.maxTokens(model: usage.model),
            lastRequestAt: lastRequestAt, cacheTTL: cacheTTL)
    }

    /// The lifetime of the cache entry this call wrote, when it wrote one.
    /// A pure cache read writes nothing and says nothing, so the caller keeps
    /// the last lifetime it saw.
    static func claudeCacheTTL(_ obj: [String: Any]) -> TimeInterval? {
        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let creation = usage["cache_creation"] as? [String: Any] else { return nil }
        func n(_ k: String) -> Int { (creation[k] as? NSNumber)?.intValue ?? 0 }
        if n("ephemeral_1h_input_tokens") > 0 { return 3_600 }
        if n("ephemeral_5m_input_tokens") > 0 { return 300 }
        return nil
    }

    // MARK: - Codex

    private static let tokenCountMarker = Data("token_count".utf8)
    private static let turnContextMarker = Data("turn_context".utf8)

    private static func codex(_ lines: [Data.SubSequence]) -> ContextSnapshot? {
        var model: String?
        var usage: ChatUsage?
        var lastRequestAt: Date?
        for line in lines {
            guard line.range(of: tokenCountMarker) != nil || line.range(of: turnContextMarker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if let u = ChatTranscript.codexUsage(obj, model: &model) {
                usage = u
                lastRequestAt = timestamp(obj) ?? lastRequestAt
            }
        }
        guard let usage else { return nil }
        return ContextSnapshot(
            tokens: usage.usedTokens, model: usage.model,
            maxTokens: usage.maxTokens ?? ChatContextWindow.maxTokens(model: usage.model),
            lastRequestAt: lastRequestAt)
    }

    // MARK: - Helpers

    static func timestamp(_ obj: [String: Any]) -> Date? {
        guard let raw = obj["timestamp"] as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
