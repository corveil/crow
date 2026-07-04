import Foundation

/// Pure heuristics for picking URLs and `path:line` references out of a
/// terminal selection so the right-click menu / Cmd+click can offer
/// "Open URL" and "Open in Editor" actions (#471 gap 5).
///
/// Kept free of AppKit so it can be exercised by unit tests without a
/// window server.
public enum SmartDetect {
    /// Returns the first URL in `text` whose scheme is in `allowedSchemes`.
    /// Uses `NSDataDetector` so it accepts the same bare-URL shapes the
    /// system's data detectors do (paren-balanced, trailing-punctuation
    /// stripped, etc.). `text` is trimmed before scanning so a
    /// single-line selection with leading/trailing whitespace still hits.
    public static func detectURL(
        in text: String,
        allowedSchemes: Set<String>
    ) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        #if canImport(Darwin)
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        )
        guard let detector else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for match in detector.matches(in: trimmed, range: range) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  allowedSchemes.contains(scheme) else { continue }
            return url
        }
        return nil
        #else
        // Linux: swift-corelibs-Foundation ships no NSDataDetector, so fall back
        // to a scheme-anchored scan. Match `scheme://…` up to whitespace, then
        // strip the trailing punctuation the system detector also drops so a
        // URL at the end of a sentence still parses.
        let pattern = #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsrange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for match in regex.matches(in: trimmed, range: nsrange) {
            guard let r = Range(match.range, in: trimmed) else { continue }
            var candidate = String(trimmed[r])
            while let last = candidate.last, ".,;:!?)]}'\"".contains(last) {
                candidate.removeLast()
            }
            guard let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(),
                  allowedSchemes.contains(scheme) else { continue }
            return url
        }
        return nil
        #endif
    }

    /// Match `path/to/file.ext:LINE` (optional `:COLUMN`) in a trimmed
    /// selection. Reject anything that doesn't look like a file reference
    /// — must contain a period in the basename, must not contain a scheme
    /// (`://`), and must have a numeric line component. Caller resolves
    /// the path against the live filesystem; we do not check existence here
    /// so the function stays pure.
    public static func detectFileLine(in text: String) -> (path: String, line: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }

        // Path may include `/`, `.`, `_`, `-`, alnum. No whitespace, no `:`.
        // Basename must contain a dot so we don't grab `foo:42` arbitrarily.
        let pattern = #"^([^\s:]+\.[A-Za-z0-9_]+):(\d+)(?::\d+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsrange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: nsrange),
              match.numberOfRanges >= 3,
              let pathRange = Range(match.range(at: 1), in: trimmed),
              let lineRange = Range(match.range(at: 2), in: trimmed),
              let line = Int(trimmed[lineRange]) else { return nil }
        return (String(trimmed[pathRange]), line)
    }
}
