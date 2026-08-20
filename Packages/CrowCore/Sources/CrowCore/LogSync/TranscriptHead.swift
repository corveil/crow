import Foundation

/// The few facts the backfill scan needs out of a Claude `.jsonl` transcript,
/// read from its head without parsing the whole (often multi-MB) file
/// (CROW-1075). Claude records the real working directory and git branch on its
/// event lines, so these are the **authoritative** metadata source — far more
/// reliable than reversing the lossy project-slug directory name.
public struct TranscriptHead: Sendable, Equatable {
    public var sessionID: String?
    public var cwd: String?
    public var gitBranch: String?
    /// First `timestamp` seen (ISO-8601 string, verbatim) — a fallback "date"
    /// when the file mtime is misleading.
    public var firstTimestamp: String?

    public init(
        sessionID: String? = nil, cwd: String? = nil,
        gitBranch: String? = nil, firstTimestamp: String? = nil
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.firstTimestamp = firstTimestamp
    }

    /// Whether every field of interest is filled, so the reader can stop early.
    var isComplete: Bool {
        sessionID != nil && cwd != nil && gitBranch != nil && firstTimestamp != nil
    }
}

/// Reads the leading events of a Claude transcript to recover its
/// `cwd`/`gitBranch`/`sessionId` (CROW-1075). The line parse is pure and
/// unit-tested; the file read is a thin wrapper that streams line by line and
/// stops as soon as every field is found (Claude fills them within the first
/// handful of message events) or a line budget is hit.
public enum TranscriptHeadReader {
    /// Fold one JSON event line into the accumulating head. Only the four fields
    /// of interest are decoded; everything else is ignored. A non-JSON or
    /// unrelated line leaves the head unchanged.
    public static func absorb(_ line: String, into head: inout TranscriptHead) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        func str(_ key: String) -> String? {
            guard let v = obj[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if head.sessionID == nil { head.sessionID = str("sessionId") }
        if head.cwd == nil { head.cwd = str("cwd") }
        if head.gitBranch == nil { head.gitBranch = str("gitBranch") }
        if head.firstTimestamp == nil { head.firstTimestamp = str("timestamp") }
    }

    /// Parse a whole in-memory transcript body (test/fixture convenience).
    public static func parse(_ body: String, maxLines: Int = 400) -> TranscriptHead {
        var head = TranscriptHead()
        var seen = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if seen >= maxLines || head.isComplete { break }
            seen += 1
            absorb(String(line), into: &head)
        }
        return head
    }

    /// Stream a transcript file's head from disk. Reads in bounded chunks and
    /// stops once the head is complete or `maxLines` is reached, so a large file
    /// costs only its first few KB. Returns an empty head on an unreadable file.
    public static func read(_ url: URL, maxLines: Int = 400) -> TranscriptHead {
        var head = TranscriptHead()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return head }
        defer { try? handle.close() }
        var buffer = Data()
        var lines = 0
        let newline: UInt8 = 0x0A
        while lines < maxLines, !head.isComplete {
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let idx = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<idx]
                buffer.removeSubrange(buffer.startIndex...idx)
                lines += 1
                if let line = String(data: lineData, encoding: .utf8) {
                    absorb(line, into: &head)
                }
                if head.isComplete || lines >= maxLines { break }
            }
        }
        // A final partial line (no trailing newline) within budget.
        if !head.isComplete, lines < maxLines, !buffer.isEmpty,
           let line = String(data: buffer, encoding: .utf8) {
            absorb(line, into: &head)
        }
        return head
    }
}
