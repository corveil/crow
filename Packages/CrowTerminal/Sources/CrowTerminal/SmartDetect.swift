import Foundation

/// Pure heuristics for picking URLs and `path:line` references out of a
/// terminal selection so the right-click menu / Cmd+click can offer
/// "Open URL" and "Open in Editor" actions (#471 gap 5).
///
/// Kept free of AppKit so it can be exercised by unit tests without a
/// window server.
public enum SmartDetect {
    /// Returns the first URL in `text` whose scheme is in `allowedSchemes`.
    /// On Darwin, uses `NSDataDetector` (paren-balanced, trailing punctuation
    /// stripped, scheme-less hosts like `github.com/x`). On Linux, uses
    /// `detectURLFallback`, which matches explicit `scheme://` and `mailto:`
    /// URLs only. `text` is trimmed before scanning.
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
        guard let detector else { return detectURLFallback(in: trimmed, allowedSchemes: allowedSchemes) }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for match in detector.matches(in: trimmed, range: range) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  allowedSchemes.contains(scheme) else { continue }
            return url
        }
        return nil
        #else
        return detectURLFallback(in: trimmed, allowedSchemes: allowedSchemes)
        #endif
    }

    /// Regex fallback for platforms without `NSDataDetector`. Exercised on every
    /// platform via `SmartDetectTests` so Linux behavior is gated in CI.
    static func detectURLFallback(in text: String, allowedSchemes: Set<String>) -> URL? {
        guard !text.isEmpty else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)

        if allowedSchemes.contains("mailto"),
           let regex = try? NSRegularExpression(pattern: #"mailto:[^\s<>"']+"#) {
            for match in regex.matches(in: text, range: nsrange) {
                guard let urlRange = Range(match.range, in: text) else { continue }
                let raw = trimTrailingURLPunctuation(String(text[urlRange]))
                if let url = URL(string: raw), url.scheme?.lowercased() == "mailto" {
                    return url
                }
            }
        }

        let schemePattern = allowedSchemes
            .subtracting(["mailto"])
            .sorted()
            .joined(separator: "|")
        guard !schemePattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"(?:\#(schemePattern))://[^\s<>"']+"#)
        else { return nil }

        for match in regex.matches(in: text, range: nsrange) {
            guard let urlRange = Range(match.range, in: text) else { continue }
            let raw = trimTrailingURLPunctuation(String(text[urlRange]))
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  allowedSchemes.contains(scheme) else { continue }
            return url
        }
        return nil
    }

    /// Strip trailing sentence punctuation from a URL candidate. A trailing `)`
    /// is removed only when it closes punctuation *around* the URL, not when it
    /// is part of a balanced pair inside the path (e.g. Wikipedia disambiguation).
    static func trimTrailingURLPunctuation(_ raw: String) -> String {
        var s = raw
        while let last = s.last {
            switch last {
            case ".", ",", ";", ":", "!", "?", "\"", "'", "]":
                s.removeLast()
            case ")":
                let opens = s.filter { $0 == "(" }.count
                let closes = s.filter { $0 == ")" }.count
                if closes > opens { s.removeLast() } else { return s }
            default:
                return s
            }
        }
        return s
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
