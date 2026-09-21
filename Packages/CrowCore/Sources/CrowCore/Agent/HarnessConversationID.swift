import Foundation

/// The harness-native conversation identifier Crow persists on a session so a
/// cold-start Manager relaunch can resume *that* transcript (`claude --resume`,
/// `cursor-agent --resume`, `codex resume <id>`) instead of `--continue` /
/// `resume --last`, which are cwd-scoped and shuffle when several Managers
/// share `{devRoot}` (CROW-1281).
public enum HarnessConversationID {
    /// Keys each harness has been observed (or documented) to put on hook stdin.
    /// Order is most-specific first so a payload that carries both a chat id and
    /// a generic `session_id` prefers the former.
    private static let payloadKeys = [
        "conversationId", "conversation_id",
        "chatId", "chat_id",
        "thread_id", "threadId",
        "session_id", "sessionId",
    ]

    /// Pull a harness conversation id out of a hook payload's string fields.
    /// Rejects Crow's own session UUID (the `--session` baked into hook
    /// commands) so we never persist the wrong namespace, and rejects empty /
    /// control-bearing values that would break a later shell resume flag.
    public static func extract(fields: [String: String], crowSessionID: UUID) -> String? {
        for key in payloadKeys {
            if let raw = fields[key], let id = sanitize(raw, rejecting: crowSessionID) {
                return id
            }
        }
        for key in ["transcript_path", "transcriptPath"] {
            if let path = fields[key],
               let id = fromTranscriptPath(path, rejecting: crowSessionID) {
                return id
            }
        }
        return nil
    }

    /// Trim, drop empties / control characters, and skip Crow's own UUID.
    public static func sanitize(_ raw: String?, rejecting crowSessionID: UUID? = nil) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(where: { $0.isNewline || $0 == "\0" }) { return nil }
        if let crowSessionID,
           trimmed.caseInsensitiveCompare(crowSessionID.uuidString) == .orderedSame {
            return nil
        }
        return trimmed
    }

    /// Claude records the session UUID as the jsonl basename under
    /// `~/.claude/projects/<slug>/<id>.jsonl`. Other harnesses that put a
    /// transcript path on the hook payload get the same treatment.
    static func fromTranscriptPath(_ path: String, rejecting crowSessionID: UUID) -> String? {
        let name = (path as NSString).lastPathComponent
        let stem: String
        if let dot = name.lastIndex(of: "."), dot > name.startIndex {
            stem = String(name[..<dot])
        } else {
            stem = name
        }
        return sanitize(stem, rejecting: crowSessionID)
    }
}
