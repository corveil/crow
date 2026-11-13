import Foundation

/// When a harness last did something in a newline-delimited JSON transcript —
/// the time of its **newest timestamped entry**, not the file's mtime
/// (CROW-1449).
///
/// The mtime is not an activity signal. A live Claude Code process re-touches
/// its idle transcript about once an hour without changing a byte, and appends
/// untimestamped metadata lines (`custom-title`, `agent-name`, `mode`,
/// `permission-mode`, …) long after the last real turn. Both bump the mtime, so
/// a quiet period keyed on it never closes for a Manager whose agent is still
/// running: the hourly touch lands just before a 60-minute window ends, and the
/// conversation never uploads. Every real turn, though, writes lines that carry
/// a top-level `timestamp` — Claude's events, Codex's rollout lines and Grok's
/// session lines all do — so the newest one is when the agent was last active.
///
/// Used by both log-sync quiescence gates (work/review/job sessions and
/// Managers) and by the gateway verifier's "agent was active N ago".
///
/// **Cost.** Transcripts run to many MB, and this is read every log-sync pass,
/// so it never reads a whole file: it scans backward from the tail a chunk at a
/// time and stops at the first chunk holding a timestamped line, bounded by
/// `maxTailBytes`. Results are cached by (path, size, mtime), so an unchanged
/// file costs a `stat`.
///
/// **Fallback.** A file with no timestamped line within reach (an unknown
/// format, or a transcript that is all metadata) falls back to its mtime, which
/// is what the gates used before — never to "no activity", which would let a
/// live transcript upload early and freeze it under the server's write-once 409.
public enum TranscriptActivity {
    /// How much of the tail is read per step.
    static let chunkBytes = 64 * 1024
    /// The most the backward scan reads from one file before giving up on
    /// finding a timestamp and falling back to the mtime. Generous enough to
    /// get past one very large tool-result line.
    static let maxTailBytes = 16 * 1024 * 1024

    /// The newest activity across `files` (`nil` only when none is readable).
    public static func lastActivity(_ files: [URL]) -> Date? {
        files.compactMap { lastActivity($0) }.max()
    }

    /// The time of `file`'s newest timestamped entry, or its mtime when it has
    /// none within reach. `nil` when the file can't be stat'ed.
    public static func lastActivity(_ file: URL) -> Date? {
        // A fresh stat, not `URL.resourceValues`: those are cached on the URL
        // instance, so a caller holding one URL across passes would see a
        // stale size and mtime and be handed a stale cache hit.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        let size = (attrs[.size] as? UInt64) ?? (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let key = CacheKey(size: size, mtime: mtime)
        if let hit = cache.get(file.path, key) { return hit }
        let activity = newestTimestamp(inTailOf: file, size: size) ?? mtime
        cache.set(file.path, key, activity)
        return activity
    }

    // MARK: - Tail scan

    /// Scan `file` backward from its end, a chunk at a time, and return the
    /// newest top-level `timestamp` in the first chunk that holds one. Lines are
    /// appended in near-chronological order (Claude interleaves a few
    /// out-of-order lines within a turn), so the max across that final chunk is
    /// the newest entry. `nil` when nothing timestamped lies within
    /// `maxTailBytes`, or the file can't be read.
    static func newestTimestamp(inTailOf file: URL, size: UInt64) -> Date? {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let parser = TimestampParser()
        var end = size
        var carry = Data()  // the leading partial line of the previous chunk
        var scanned: UInt64 = 0
        while end > 0, scanned < UInt64(maxTailBytes) {
            // Grow the step with the carried partial line, so walking back
            // through one multi-MB line (a big tool result) copies it a
            // logarithmic number of times, not once per 64KB.
            let step = min(UInt64(max(chunkBytes, carry.count)), end)
            let start = end - step
            guard (try? handle.seek(toOffset: start)) != nil,
                  let chunk = try? handle.read(upToCount: Int(step)), !chunk.isEmpty
            else { return nil }
            scanned += UInt64(chunk.count)
            end = start
            var buffer = chunk
            buffer.append(carry)
            var lines = buffer.split(separator: 0x0A, omittingEmptySubsequences: false)
            // Unless this chunk starts the file, its first segment may be cut
            // mid-line: hold it over and complete it with the next (earlier)
            // chunk.
            if start > 0 {
                carry = Data(lines.removeFirst())
            } else {
                carry = Data()
            }
            let newest = lines.compactMap { parser.timestamp(ofLine: $0) }.max()
            if let newest { return newest }
        }
        return nil
    }

    /// The top-level `timestamp` of one JSON line, or `nil` for a blank,
    /// non-JSON or untimestamped line. Only the top level counts: a nested
    /// `timestamp` (inside a tool result, say) is content, not the entry's time.
    public static func timestamp(ofLine line: String) -> Date? {
        TimestampParser().timestamp(ofLine: Data(line.utf8)[...])
    }

    /// Parses a line's `timestamp`. A class so one `ISO8601DateFormatter` serves
    /// a whole scan; it never leaves the scan that made it.
    final class TimestampParser {
        private let withFraction: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private let plain: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        func timestamp(ofLine line: Data.SubSequence) -> Date? {
            // Cheap reject before a JSON parse: no `"timestamp"` key, no date.
            guard line.count > 2, line.range(of: Data("\"timestamp\"".utf8)) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { return nil }
            switch obj["timestamp"] {
            case let s as String: return parse(s)
            case let n as NSNumber:
                // Epoch seconds, or milliseconds when too large to be seconds.
                let v = n.doubleValue
                guard v > 0 else { return nil }
                return Date(timeIntervalSince1970: v > 1e11 ? v / 1000 : v)
            default: return nil
            }
        }

        /// ISO-8601 with or without fractional seconds. Grok writes six
        /// fractional digits; the formatter's fractional mode is only reliable
        /// to three, so longer fractions are cut to milliseconds first.
        func parse(_ raw: String) -> Date? {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if let d = withFraction.date(from: s) ?? plain.date(from: s) { return d }
            guard let dot = s.firstIndex(of: ".") else { return nil }
            let digitsEnd = s[s.index(after: dot)...].firstIndex(where: { !$0.isNumber }) ?? s.endIndex
            let digits = s[s.index(after: dot)..<digitsEnd]
            guard digits.count > 3 else { return nil }
            let trimmed = String(s[..<dot]) + "." + digits.prefix(3) + String(s[digitsEnd...])
            return withFraction.date(from: trimmed)
        }
    }

    // MARK: - Cache

    struct CacheKey: Equatable {
        var size: UInt64
        var mtime: Date
    }

    /// Path → last result, valid while the file's size and mtime are unchanged.
    /// Bounded: cleared wholesale past `limit` entries, which only costs a
    /// re-read of each tail.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (key: CacheKey, activity: Date)] = [:]
        private let limit = 4096

        func get(_ path: String, _ key: CacheKey) -> Date? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entries[path], e.key == key else { return nil }
            return e.activity
        }

        func set(_ path: String, _ key: CacheKey, _ activity: Date) {
            lock.lock(); defer { lock.unlock() }
            if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
            entries[path] = (key, activity)
        }
    }

    static let cache = Cache()
}
