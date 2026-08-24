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
    ///
    /// Three harness shapes are recognized, so one reader serves the Claude, Codex,
    /// and Muse backfills (CROW-1089, CROW-1106):
    ///  - **Claude** records `cwd` / `gitBranch` / `sessionId` / `timestamp` as
    ///    top-level keys on its event lines.
    ///  - **Codex** records them on its first `session_meta` line under a nested
    ///    `payload` object (`payload.cwd`, `payload.id`, `payload.timestamp`);
    ///    Codex writes no git branch, so `gitBranch` simply stays `nil`.
    ///  - **Muse Code** records the absolute cwd one level deeper, on its line-1
    ///    `runtime.session.metadata` record: `payload.record.workspace_root`
    ///    (CROW-1106). Muse writes no git branch either, so `gitBranch` stays `nil`.
    ///    ⚠️ This key is from a first-hand third-party parser of Muse 0.1.0 logs
    ///    (`superbasedapp/observer`), **not yet verified against a live install**
    ///    (Muse is Meta-auth-gated). It fails safe: if the real key differs, `cwd`
    ///    stays `nil` and the file is dropped by the cwd filter — never guessed,
    ///    never misattributed (CROW-1099 / #1106).
    /// The three never collide — Claude transcripts carry no `payload`, and neither
    /// Codex nor Claude nests a `payload.record` — so each nested lookup is a
    /// harmless fallback for the others.
    public static func absorb(_ line: String, into head: inout TranscriptHead) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        func str(_ dict: [String: Any], _ key: String) -> String? {
            guard let v = dict[key] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let payload = obj["payload"] as? [String: Any]
        // Muse's line-1 metadata record nests the cwd under `payload.record`.
        let record = payload?["record"] as? [String: Any]
        if head.sessionID == nil {
            head.sessionID = str(obj, "sessionId") ?? payload.flatMap { str($0, "id") }
        }
        if head.cwd == nil {
            head.cwd = str(obj, "cwd")
                ?? payload.flatMap { str($0, "cwd") }
                ?? record.flatMap { str($0, "workspace_root") }
        }
        if head.gitBranch == nil { head.gitBranch = str(obj, "gitBranch") }
        if head.firstTimestamp == nil {
            head.firstTimestamp = str(obj, "timestamp") ?? payload.flatMap { str($0, "timestamp") }
        }
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

/// Reads *only* the working directory a harness log recorded, from the head of
/// the file, and stops the instant it finds one (CROW-1089).
///
/// This is the live collector's per-file attribution probe for a globally-stored
/// harness (Codex): `LogSyncCollector.resolveFiles` calls it for every candidate
/// rollout to decide whether that rollout ran in the session's worktree. It must
/// stay cheap — a Codex rollout's first `session_meta` line alone can be several
/// KB, and there can be hundreds of them — so unlike `TranscriptHeadReader.read`
/// (which keeps reading until *all* head fields are found, and Codex never fills
/// `gitBranch`) this returns as soon as `cwd` appears, scanning only a handful of
/// lines. `cwd` is on line 1 for both Claude and Codex; the small `maxLines`
/// budget is slack for a harness that emits a preamble line first.
public enum AgentLogCwdReader {
    /// The recorded `cwd` from the head of `url`, or `nil` if none is found within
    /// `maxLines`. Uses `TranscriptHeadReader.absorb`, so it recognizes the Claude
    /// (top-level `cwd`), Codex (`payload.cwd`), and Muse
    /// (`payload.record.workspace_root`) shapes.
    public static func read(_ url: URL, maxLines: Int = 8) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var head = TranscriptHead()
        var buffer = Data()
        var lines = 0
        let newline: UInt8 = 0x0A
        while lines < maxLines, head.cwd == nil {
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let idx = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<idx]
                buffer.removeSubrange(buffer.startIndex...idx)
                lines += 1
                if let line = String(data: lineData, encoding: .utf8) {
                    TranscriptHeadReader.absorb(line, into: &head)
                }
                if head.cwd != nil || lines >= maxLines { break }
            }
        }
        // A final partial line (no trailing newline) within budget.
        if head.cwd == nil, lines < maxLines, !buffer.isEmpty,
           let line = String(data: buffer, encoding: .utf8) {
            TranscriptHeadReader.absorb(line, into: &head)
        }
        return head.cwd
    }
}
