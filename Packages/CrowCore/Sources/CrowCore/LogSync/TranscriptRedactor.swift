import Foundation

/// Removes gateway keys from a transcript before log sync uploads it (CROW-1484).
///
/// An agent that prints its environment, `settings.local.json` or `config.json`
/// writes the Corveil gateway key into its own transcript, and log sync would
/// upload it unchanged. Two passes run over the raw NDJSON bytes:
///
/// 1. **Known secrets.** Each value in `secrets` (the session's own gateway
///    key, which is also the key log sync uploads with) is replaced wherever it
///    appears, whatever its shape.
/// 2. **The Corveil key shape.** `sk-citadel-` followed by at least
///    ``minimumTokenLength`` key characters (`[A-Za-z0-9_-]`) is replaced, so a
///    key from another workspace, or a rotated one, is caught too.
///
/// Both are replaced with ``replacement``, which is plain ASCII with no quote
/// or backslash, so every NDJSON line stays valid JSON and the line count is
/// unchanged. Works on bytes, so a transcript that isn't valid UTF-8 is left
/// otherwise untouched.
public enum TranscriptRedactor {
    /// What a redacted key reads as in the uploaded transcript.
    public static let replacement = "[REDACTED:gateway-key]"

    /// The prefix every Corveil virtual key starts with.
    public static let corveilKeyPrefix = "sk-citadel-"

    /// Key characters after ``corveilKeyPrefix`` needed to count as a key.
    /// Short enough to catch a printed key prefix (`sk-citadel-0a1b2c3d4`),
    /// long enough to leave prose like `sk-citadel-…` or `sk-citadel-<key>` alone.
    public static let minimumTokenLength = 8

    /// A literal secret shorter than this is skipped: replacing a short
    /// common string would mangle unrelated text, and no real gateway key is
    /// that short.
    public static let minimumSecretLength = 12

    /// The redacted bytes and how many keys were replaced.
    public struct Result: Equatable, Sendable {
        public let data: Data
        public let count: Int
    }

    /// Redact `data`. `secrets` are trimmed; blank, short and duplicate values
    /// are ignored.
    public static func redact(_ data: Data, secrets: [String]) -> Result {
        guard !data.isEmpty else { return Result(data: data, count: 0) }

        var ranges: [Range<Int>] = []
        let bytes = [UInt8](data)

        // Pass 1: known secrets, longest first so a secret that contains
        // another is matched whole.
        let literals = Set(secrets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.utf8.count >= minimumSecretLength })
            .sorted { $0.utf8.count > $1.utf8.count }
        for secret in literals {
            ranges += occurrences(of: Array(secret.utf8), in: bytes)
        }

        // Pass 2: anything shaped like a Corveil key.
        let prefix = Array(corveilKeyPrefix.utf8)
        for start in occurrences(of: prefix, in: bytes).map(\.lowerBound) {
            var end = start + prefix.count
            while end < bytes.count, isKeyByte(bytes[end]) { end += 1 }
            if end - start - prefix.count >= minimumTokenLength {
                ranges.append(start..<end)
            }
        }

        guard !ranges.isEmpty else { return Result(data: data, count: 0) }

        // Merge overlapping or touching matches, then rebuild in one pass.
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }

        let replacementBytes = Array(replacement.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var cursor = 0
        for range in merged {
            out.append(contentsOf: bytes[cursor..<range.lowerBound])
            out.append(contentsOf: replacementBytes)
            cursor = range.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
        return Result(data: Data(out), count: merged.count)
    }

    /// Redact a transcript's body, keeping its counts and flags. Only meant for
    /// the plain NDJSON a normalizer produces; a gzipped body is returned as is.
    public static func redact(_ transcript: NormalizedTranscript, secrets: [String]) -> (NormalizedTranscript, Int) {
        guard !transcript.gzipped else { return (transcript, 0) }
        let result = redact(transcript.data, secrets: secrets)
        guard result.count > 0 else { return (transcript, 0) }
        return (NormalizedTranscript(
            data: result.data,
            eventCount: transcript.eventCount,
            toolCallCount: transcript.toolCallCount,
            truncated: transcript.truncated,
            gzipped: false), result.count)
    }

    private static func isKeyByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) // 0-9
            || (b >= 0x41 && b <= 0x5A) // A-Z
            || (b >= 0x61 && b <= 0x7A) // a-z
            || b == 0x2D || b == 0x5F // - _
    }

    /// Start..end of every (possibly overlapping) occurrence of `needle`.
    private static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Range<Int>] {
        guard let first = needle.first, needle.count <= haystack.count else { return [] }
        var found: [Range<Int>] = []
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { found.append(i..<(i + needle.count)) }
            }
            i += 1
        }
        return found
    }
}
