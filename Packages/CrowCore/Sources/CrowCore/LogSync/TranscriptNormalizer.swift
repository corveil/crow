import Foundation

/// A harness log normalized to the NDJSON bytes the upload endpoint stores, plus
/// the cheap hint counts the server-side derivation can use (corveil#2426).
public struct NormalizedTranscript: Sendable, Equatable {
    /// The artifact body, uploaded verbatim: plain NDJSON as the normalizer
    /// produces it, or gzip-compressed NDJSON once `gzipForUpload` has run
    /// (`gzipped`). The server sniffs the encoding from the magic bytes either
    /// way. `sha256`/`sizeBytes` in the ledger describe these exact bytes.
    public let data: Data
    /// Number of NDJSON events (non-empty lines). A hint; the server treats it as
    /// optional.
    public let eventCount: Int
    /// Number of tool-use events seen (best-effort substring count). A hint.
    public let toolCallCount: Int
    /// Whether the transcript was cut to fit `maxBytes`.
    public let truncated: Bool
    /// Whether `data` is gzip-compressed (sent with `Content-Encoding: gzip`).
    public let gzipped: Bool

    public init(data: Data, eventCount: Int, toolCallCount: Int, truncated: Bool, gzipped: Bool = false) {
        self.data = data
        self.eventCount = eventCount
        self.toolCallCount = toolCallCount
        self.truncated = truncated
        self.gzipped = gzipped
    }
}

/// Turns a harness's resolved on-disk log files into one NDJSON artifact body,
/// bounded by a byte cap (CROW-1056). Pure and dependency-free so it is unit
/// tested in CrowCore.
public enum TranscriptNormalizer {
    /// Normalize `files` (already resolved to concrete regular files, in the
    /// order they should be concatenated) into a single NDJSON body.
    ///
    /// Returns `nil` when there is nothing to upload (no files, all empty) or the
    /// format yields no plaintext transcript (`.sqlite` — a Cursor store that is
    /// unreadable, empty, or whose blobs aren't plaintext JSON).
    public static func normalize(
        files: [URL],
        format: AgentLogFormat,
        maxBytes: Int
    ) -> NormalizedTranscript? {
        switch format {
        case .jsonl, .logDir:
            return concatenateNDJSON(files: files, maxBytes: maxBytes)
        case .openCodeStore:
            // OpenCode's SQLite store (`opencode.db`) selects rows by cwd (live
            // collector) or session id (backfill) — a selector this file-list
            // signature can't express — so it is normalized through `OpenCodeStore`
            // directly by the collector / backfill, never here (CROW-1096).
            return nil
        case .sqlite:
            // Cursor's `store.db` keeps the conversation as content-addressed
            // blobs, not NDJSON on disk; `CursorStore` extracts the ordered
            // message lines (an unreadable or encrypted store yields none), which
            // are then concatenated into the same NDJSON artifact as every other
            // harness (CROW-1095).
            return concatenateCursorStores(files: files, maxBytes: maxBytes)
        }
    }

    /// How many raw NDJSON bytes to read for an upload whose **compressed** body
    /// is capped at `compressedCap` (CROW-1394). Transcripts gzip about 5×, so
    /// 16× leaves room for unusually repetitive logs; a transcript that hits
    /// this budget would not have fit the compressed cap at any realistic
    /// ratio, so stopping the read here loses nothing `gzipForUpload` would
    /// have kept.
    public static func rawReadBudget(forCompressedCap compressedCap: Int) -> Int {
        let (budget, overflow) = max(1, compressedCap).multipliedReportingOverflow(by: 16)
        return overflow ? Int.max : budget
    }

    /// gzip an NDJSON transcript for upload, keeping the **compressed** body at
    /// or under `maxBytes` (CROW-1394). Corveil's artifact limit applies to the
    /// body as sent, so the cap is measured after compression.
    ///
    /// When the whole transcript compresses under the cap it ships whole, and
    /// `truncated` stays whatever the read reported. Only when it is still over
    /// is the NDJSON cut, keeping the oldest lines as before, and `truncated`
    /// set. Event counts describe the lines actually kept. If zlib fails, or no
    /// whole-line prefix compresses under the cap, the plain NDJSON is cut to
    /// the cap and sent uncompressed rather than dropped.
    public static func gzipForUpload(_ transcript: NormalizedTranscript, maxBytes: Int) -> NormalizedTranscript? {
        guard maxBytes > 0 else { return nil }
        let raw = transcript.data
        guard let whole = Gzip.compress(raw) else { return uncompressedFallback(raw, transcript, maxBytes) }
        if whole.count <= maxBytes {
            return NormalizedTranscript(
                data: whole, eventCount: transcript.eventCount, toolCallCount: transcript.toolCallCount,
                truncated: transcript.truncated, gzipped: true)
        }

        // Still over the cap: shrink the kept prefix by the observed ratio
        // (with a little headroom) and recompress until it fits. Converges in
        // a few rounds because compression ratio is near-linear in length.
        var keep = raw.count
        var compressedSize = whole.count
        for _ in 0..<12 {
            let scaled = Double(keep) * Double(maxBytes) / Double(compressedSize) * 0.95
            keep = min(keep - 1, Int(scaled))
            guard keep > 0 else { break }
            let kept = trimToLastNewline(raw.prefix(keep))
            guard !kept.isEmpty, let gz = Gzip.compress(kept) else { break }
            if gz.count <= maxBytes {
                let (events, toolCalls) = countEvents(kept)
                return NormalizedTranscript(
                    data: gz, eventCount: events, toolCallCount: toolCalls, truncated: true, gzipped: true)
            }
            keep = kept.count
            compressedSize = gz.count
        }
        // No line-bounded prefix compresses under the cap (a tiny cap, or a
        // first line too big for it): send the head uncompressed rather than
        // drop the transcript.
        return uncompressedFallback(raw, transcript, maxBytes)
    }

    private static func uncompressedFallback(
        _ raw: Data, _ transcript: NormalizedTranscript, _ maxBytes: Int
    ) -> NormalizedTranscript? {
        guard raw.count > maxBytes else { return transcript }
        let kept = trimToLastNewline(raw.prefix(maxBytes))
        guard !kept.isEmpty, kept.count <= maxBytes else { return nil }
        let (events, toolCalls) = countEvents(kept)
        return NormalizedTranscript(data: kept, eventCount: events, toolCallCount: toolCalls, truncated: true)
    }

    /// Wrap already-assembled NDJSON `data` in a `NormalizedTranscript`, computing
    /// the same best-effort event/tool-call hint counts `normalize` produces. The
    /// shared finalizer for producers that build their bytes outside the
    /// file-concatenation path — currently `OpenCodeStore`, which reassembles rows
    /// from `opencode.db` (CROW-1096). `nil` for empty input.
    public static func finalize(_ data: Data, truncated: Bool) -> NormalizedTranscript? {
        guard !data.isEmpty else { return nil }
        let (events, toolCalls) = countEvents(data)
        return NormalizedTranscript(
            data: data, eventCount: events, toolCallCount: toolCalls, truncated: truncated)
    }

    /// Concatenate NDJSON files, inserting a newline between files that don't end
    /// in one, and cutting at the last newline within `maxBytes` if the total
    /// would exceed the cap (marking the result truncated). Reads incrementally so
    /// a pathologically large file can't blow past the budget in memory.
    private static func concatenateNDJSON(files: [URL], maxBytes: Int) -> NormalizedTranscript? {
        guard maxBytes > 0 else { return nil }
        var out = Data()
        out.reserveCapacity(min(maxBytes, 1 << 20))
        let newline: UInt8 = 0x0A
        var truncated = false

        outer: for url in files {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            // Separate files with a newline so a file missing its trailing
            // newline can't glue two events into one line.
            if let last = out.last, last != newline, !out.isEmpty {
                if out.count + 1 > maxBytes { truncated = true; break }
                out.append(newline)
            }
            while out.count < maxBytes {
                let remaining = maxBytes - out.count
                guard let chunk = try? handle.read(upToCount: min(65_536, remaining + 1)),
                      !chunk.isEmpty
                else { break }
                if out.count + chunk.count <= maxBytes {
                    out.append(chunk)
                } else {
                    out.append(chunk.prefix(maxBytes - out.count))
                    truncated = true
                    break outer
                }
            }
            if out.count >= maxBytes {
                // Reached the cap; if more files/bytes remain they're dropped.
                truncated = truncated || url != files.last
                break
            }
        }

        if truncated {
            out = trimToLastNewline(out)
        }
        guard !out.isEmpty else { return nil }

        let (events, toolCalls) = countEvents(out)
        return NormalizedTranscript(
            data: out, eventCount: events, toolCallCount: toolCalls, truncated: truncated)
    }

    /// Extract each Cursor `store.db`'s ordered message lines (`CursorStore`) and
    /// concatenate them into one NDJSON body, bounded by `maxBytes` and marked
    /// truncated if the cap is hit. A store that yields no plaintext messages
    /// contributes nothing; if none do, the result is `nil` (upload nothing).
    /// Each line is appended whole — a line that would cross the cap ends the
    /// concatenation, so the body is always valid NDJSON, never a partial object.
    private static func concatenateCursorStores(files: [URL], maxBytes: Int) -> NormalizedTranscript? {
        guard maxBytes > 0 else { return nil }
        let newline: UInt8 = 0x0A
        var out = Data()
        out.reserveCapacity(min(maxBytes, 1 << 20))
        var truncated = false

        outer: for url in files {
            guard let lines = CursorStore.messageLines(fromStoreDB: url) else { continue }
            for line in lines {
                // +1 for the separating newline after this line.
                if out.count + line.count + 1 > maxBytes { truncated = true; break outer }
                out.append(line)
                out.append(newline)
            }
        }

        guard !out.isEmpty else { return nil }
        let (events, toolCalls) = countEvents(out)
        return NormalizedTranscript(
            data: out, eventCount: events, toolCallCount: toolCalls, truncated: truncated)
    }

    /// Drop a trailing partial line so a truncated artifact still parses as clean
    /// NDJSON. If there is no newline at all, the data is returned unchanged.
    private static func trimToLastNewline(_ data: Data) -> Data {
        let newline: UInt8 = 0x0A
        guard let idx = data.lastIndex(of: newline) else { return data }
        return data.prefix(through: idx)
    }

    /// Count NDJSON events (non-empty lines) and tool-use events (lines carrying
    /// the `"type":"tool_use"` marker). Best-effort hints; a single pass over the
    /// bytes, no JSON parsing.
    private static func countEvents(_ data: Data) -> (events: Int, toolCalls: Int) {
        let newline: UInt8 = 0x0A
        var events = 0
        var lineHadBytes = false
        for byte in data {
            if byte == newline {
                if lineHadBytes { events += 1 }
                lineHadBytes = false
            } else if byte != 0x0D { // ignore CR
                lineHadBytes = true
            }
        }
        if lineHadBytes { events += 1 } // last line with no trailing newline

        // Tool-use marker count over the whole body (cheap substring scan).
        let toolCalls: Int
        if let marker = "\"type\":\"tool_use\"".data(using: .utf8) {
            toolCalls = data.ranges(of: marker).count
        } else {
            toolCalls = 0
        }
        return (events, toolCalls)
    }
}

private extension Data {
    /// Non-overlapping occurrences of `pattern` in this data.
    func ranges(of pattern: Data) -> [Range<Data.Index>] {
        guard !pattern.isEmpty, count >= pattern.count else { return [] }
        var result: [Range<Data.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let found = self.range(of: pattern, in: searchStart..<endIndex) {
            result.append(found)
            searchStart = found.upperBound
        }
        return result
    }
}
