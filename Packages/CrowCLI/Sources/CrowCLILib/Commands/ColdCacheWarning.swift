import CrowIPC
import Foundation

// MARK: - Cold-cache send warning (CROW-1499)

/// The stderr line `crow send` prints after sending into a session whose
/// context is large and whose prompt cache has likely expired.
///
/// Both facts come from `get-session`'s `context` object (CROW-1493):
/// `large` (tokens past `contextCompaction.minContextTokens`) and
/// `cache_expired` (idle past the cache lifetime the transcript records). Such
/// a message re-writes the whole context to the cache instead of reading it.
///
/// It only informs: the text is sent and stdout stays the `send` JSON. Token
/// counts only, no price: the repo has no price table to take one from.
public enum ColdCacheWarning {

    /// The warning for text sent to `terminal`, or nil when there is nothing
    /// to warn about: the context isn't both large and expired, the token
    /// count is unknown, or `terminal` isn't the session's agent terminal (a
    /// shell tab never reaches the model).
    public static func message(for snap: AgentWait.Snapshot, terminal: String) -> String? {
        guard let agentTerminal = snap.agentTerminalID,
              agentTerminal.caseInsensitiveCompare(terminal) == .orderedSame,
              let context = snap.context,
              context["large"]?.boolValue == true,
              context["cache_expired"]?.boolValue == true,
              let tokens = context["tokens"]?.intValue else { return nil }
        var idle = ""
        if let seconds = context["idle_seconds"]?.intValue { idle = " (idle \(formatIdle(seconds)))" }
        return "sent into a cold session: its prompt cache had expired\(idle), so this message "
            + "re-writes all \(groupThousands(tokens)) tokens of context to the cache. "
            + "See context in crow get-session."
    }

    /// `45m`, `3h 2m`, `2d`: the sidebar badge's wording (session-row.js).
    static func formatIdle(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours)h \(minutes % 60)m" : "\(hours / 24)d"
    }

    /// `704312` → `704,312`, independent of the locale.
    static func groupThousands(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }
}
