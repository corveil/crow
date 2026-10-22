import Foundation

/// Without `LocalizedError`, `localizedDescription` on a `ProviderError` is
/// "The operation couldn't be completed. (CrowProvider.ProviderError error 1.)"
/// — every `[BoardPoller]`/`[IssueTracker]` log line that prints it loses the
/// real `gh`/`glab` failure (CROW-1352). The payloads are raw CLI output
/// (stdout + stderr share one pipe), so a 502 can drag in a whole HTML page:
/// `errorDescription` trims it to one log-safe line.
extension ProviderError: LocalizedError {
    /// Upper bound on a description, in characters. Long enough for a `gh:`
    /// line plus GitHub's message, short enough to keep a response body out.
    public static let descriptionLimit = 300

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "invalid URL: \(Self.logSafe(url))"
        case .commandFailed(let output):
            let detail = Self.logSafe(output)
            return detail.isEmpty ? "command failed with no output" : detail
        case .unimplemented(let msg):
            return Self.logSafe(msg)
        case .insufficientScope(let scope):
            return "GitHub token missing '\(Self.logSafe(scope))' scope"
        case .rateLimited(let output):
            return "rate limited: \(Self.logSafe(output))"
        case .samlRestricted(let output):
            return "SAML-restricted: \(Self.logSafe(output))"
        }
    }

    /// Reduce raw CLI output to one short line that is safe to log:
    /// prefer `gh`/`glab`'s own `gh: …` summary line when there is one (it
    /// trails the response body in the merged pipe), otherwise strip HTML;
    /// then redact anything token-shaped, collapse whitespace, and cap length.
    static func logSafe(_ raw: String) -> String {
        let headline = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { $0.hasPrefix("gh: ") || $0.hasPrefix("glab: ") })
        var text = headline ?? stripHTML(raw)
        text = redactSecrets(text)
        text = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard text.count > descriptionLimit else { return text }
        return String(text.prefix(descriptionLimit - 1)) + "…"
    }

    private static func stripHTML(_ text: String) -> String {
        guard text.range(of: "<[a-zA-Z!/]", options: .regularExpression) != nil else { return text }
        return text
            .replacingOccurrences(
                of: "(?is)<(script|style)\\b.*?</\\1\\s*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
    }

    /// Credential shapes that could plausibly ride along in CLI output: GitHub
    /// and GitLab tokens, Corveil/OpenAI-style `sk-` keys, and HTTP auth
    /// header values. Nothing Crow builds puts one there today; this is the
    /// backstop for whatever a CLI decides to echo.
    private static let secretPatterns = [
        "\\bgh[pousr]_[A-Za-z0-9]{16,}",
        "\\bgithub_pat_[A-Za-z0-9_]{16,}",
        "\\bglpat-[A-Za-z0-9_-]{16,}",
        "\\bsk-[A-Za-z0-9_-]{16,}",
        "(?i)\\b(?:bearer|basic|token)\\s+[A-Za-z0-9._~+/=-]{16,}",
    ]

    private static func redactSecrets(_ text: String) -> String {
        secretPatterns.reduce(text) {
            $0.replacingOccurrences(of: $1, with: "[REDACTED]", options: .regularExpression)
        }
    }
}
