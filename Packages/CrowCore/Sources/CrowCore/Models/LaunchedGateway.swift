import Foundation

/// What gateway a session's agent was actually **launched** with (spike:
/// sidebar recording indicator).
///
/// `crow get-session`'s `gateway_set` / `gateway_base_url` describe
/// *configuration*: the gateway a launch would pick up now. A session launched
/// before its workspace got a gateway still reads `gateway_set: true` there.
/// This record is taken at the moment Crow types the launch line into the
/// pane, so it describes the running process instead.
///
/// Holds the **base URL only**. Header names and values are credentials and
/// never enter this type (see the ⚠️ REDACTION note in
/// `EngineSessionRPCHandlers`), because `list-sessions` is readable by remote
/// `/rpc` peers.
public struct LaunchedGateway: Codable, Sendable, Equatable {
    /// How the gateway reached the launched process.
    public enum Via: String, Codable, Sendable, Equatable {
        /// `ANTHROPIC_BASE_URL=…` on the launch line (Claude, CROW-402).
        case launchLine
        /// `-c model_providers.<id>.base_url=…` on a Codex launch (CROW-1407).
        case codexOverride
        /// The launch line said nothing; the `env` block of the cwd's
        /// `.claude/settings.local.json` did (a Claude Manager, whose stored
        /// command carries no prefix).
        case settingsEnv
        /// The launch line explicitly cleared the gateway
        /// (`unset ANTHROPIC_BASE_URL`), or a Claude launch with no settings
        /// `env` block either: the process talks to the vendor directly.
        case none
        /// A harness Crow has no gateway route for (Cursor, OpenCode, …), or a
        /// launch line Crow could not read a gateway decision from.
        case unknown
    }

    /// The base URL the process was launched against; nil for `.none` and
    /// `.unknown`.
    public var baseURL: String?
    public var via: Via
    /// The harness that was launched (a handoff changes it).
    public var agentKind: AgentKind
    public var at: Date

    public init(baseURL: String?, via: Via, agentKind: AgentKind, at: Date = Date()) {
        self.baseURL = baseURL
        self.via = via
        self.agentKind = agentKind
        self.at = at
    }

    /// What a launch line says about the gateway, or nil when it says nothing.
    ///
    /// Pure, so every launch path (the Swift builders and `setup.sh`'s
    /// `gateway_launch_prefix`) is judged by the same rule: the text actually
    /// typed into the pane. Only the base URL is extracted; the header value
    /// that rides beside it on the same line is never read.
    public static func detect(launchText text: String) -> (baseURL: String?, via: Via)? {
        if let url = firstQuotedValue(after: "ANTHROPIC_BASE_URL=", in: text) {
            return (url, .launchLine)
        }
        if let url = codexBaseURL(in: text) {
            return (url, .codexOverride)
        }
        if text.range(of: #"\bunset\s+ANTHROPIC_BASE_URL\b"#, options: .regularExpression) != nil {
            return (nil, .none)
        }
        return nil
    }

    /// The record for one launch of `agentKind`.
    ///
    /// The launch line wins. When it says nothing, a Claude launch falls back to
    /// the cwd's `settings.local.json` `env` block (`settingsJSON`, nil when
    /// absent), which is how a Claude Manager gets its gateway; with neither,
    /// Claude talks to Anthropic directly. A Codex launch with no
    /// `crow-corveil` override goes to OpenAI directly. Every other harness is
    /// `.unknown`: Crow has no gateway route for it.
    public static func record(
        launchText: String, agentKind: AgentKind, settingsJSON: Data?, at: Date = Date()
    ) -> LaunchedGateway {
        if let found = detect(launchText: launchText) {
            return LaunchedGateway(baseURL: found.baseURL, via: found.via, agentKind: agentKind, at: at)
        }
        if agentKind == .claudeCode {
            if let settingsJSON, let url = settingsEnvBaseURL(settingsJSON: settingsJSON) {
                return LaunchedGateway(baseURL: url, via: .settingsEnv, agentKind: agentKind, at: at)
            }
            return LaunchedGateway(baseURL: nil, via: .none, agentKind: agentKind, at: at)
        }
        if agentKind == .codex {
            return LaunchedGateway(baseURL: nil, via: .none, agentKind: agentKind, at: at)
        }
        return LaunchedGateway(baseURL: nil, via: .unknown, agentKind: agentKind, at: at)
    }

    /// `ANTHROPIC_BASE_URL` from a `settings.local.json` `env` block, or nil.
    public static func settingsEnvBaseURL(settingsJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any],
              let url = env["ANTHROPIC_BASE_URL"] as? String
        else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Parsing

    private static func codexBaseURL(in text: String) -> String? {
        let pattern = #"model_providers\.[A-Za-z0-9_\-]+\.base_url="#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return shellWord(in: text[range.upperBound...])
    }

    private static func firstQuotedValue(after marker: String, in text: String) -> String? {
        // The marker must start a word: `XANTHROPIC_BASE_URL=` is not ours.
        var searchStart = text.startIndex
        while let range = text.range(of: marker, range: searchStart..<text.endIndex) {
            let atWordStart = range.lowerBound == text.startIndex
                || !(text[text.index(before: range.lowerBound)].isLetter
                     || text[text.index(before: range.lowerBound)].isNumber
                     || text[text.index(before: range.lowerBound)] == "_")
            if atWordStart, let value = shellWord(in: text[range.upperBound...]) {
                return value
            }
            searchStart = range.upperBound
        }
        return nil
    }

    /// The first shell word of `rest`: a single-quoted, double-quoted, or bare
    /// run up to whitespace. Nil when empty.
    private static func shellWord(in rest: Substring) -> String? {
        guard let first = rest.first else { return nil }
        let value: Substring
        if first == "'" || first == "\"" {
            let body = rest.dropFirst()
            guard let close = body.firstIndex(of: first) else { return nil }
            value = body[..<close]
        } else {
            value = rest.prefix(while: { !$0.isWhitespace && $0 != ";" && $0 != "&" })
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
