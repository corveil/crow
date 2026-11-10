import Foundation

/// What gateway a session's agent was actually **launched** with (CROW-1423,
/// the debug-mode recording indicator).
///
/// `crow get-session`'s `gateway_set` / `gateway_base_url` describe
/// *configuration*: the gateway a launch would pick up now. A session launched
/// before its workspace got a gateway still reads `gateway_set: true` there.
/// This record is taken at the moment Crow types the launch line into the
/// pane, so it describes the running process instead.
///
/// Holds the **base URL only**, reduced to scheme, host, port and path by
/// ``displayableBaseURL(_:)``. Header names and values are credentials and
/// never enter this type (see the ⚠️ REDACTION note in
/// `EngineSessionRPCHandlers`), because `list-sessions` is readable by remote
/// `/rpc` peers.
///
/// Recorded on every launch whether or not debug mode is on: it is one
/// in-memory write plus a store save, and it means turning debug mode on shows
/// the real launch state at once instead of after every agent relaunches.
public struct LaunchedGateway: Codable, Sendable, Equatable {
    /// How the gateway reached the launched process.
    public enum Via: String, Codable, Sendable, Equatable {
        /// `ANTHROPIC_BASE_URL=…` on the launch line (Claude, CROW-402).
        case launchLine
        /// `-c model_providers.<id>.base_url=…` on a Codex launch (CROW-1407).
        case codexOverride
        /// The `env` block of the cwd's `.claude/settings.local.json` set it.
        /// For Claude this beats the launch line (see ``record(launchText:agentKind:settingsJSON:at:)``),
        /// and it is how a Claude Manager, whose stored command carries no
        /// prefix, gets its gateway.
        case settingsEnv
        /// The launch line explicitly cleared the gateway
        /// (`unset ANTHROPIC_BASE_URL`), or a Claude launch with no settings
        /// `env` block either: the process talks to the vendor directly.
        case none
        /// A harness Crow has no gateway route for (Cursor, OpenCode, …), or a
        /// gateway URL that isn't an absolute http(s) URL Crow can show.
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
    /// **Claude:** the cwd's `settings.local.json` `env` block wins, then the
    /// launch line, then nothing (vendor direct). Claude Code applies its
    /// settings `env` on top of the environment it inherited, so a launch
    /// line's `ANTHROPIC_BASE_URL=…` or `unset ANTHROPIC_BASE_URL` loses to a
    /// settings value (checked against Claude Code 2.1.322: a variable set in
    /// both reads the settings value inside the agent). Crow writes the same
    /// gateway to both places on a normal launch, so they only disagree when
    /// something else edited the file. `settingsJSON` is nil when the file is
    /// absent.
    ///
    /// **Codex:** the launch line's `crow-corveil` override, else OpenAI
    /// directly. **Every other harness** is `.unknown`: Crow has no gateway
    /// route for it.
    public static func record(
        launchText: String, agentKind: AgentKind, settingsJSON: Data?, at: Date = Date()
    ) -> LaunchedGateway {
        func make(_ url: String?, _ via: Via) -> LaunchedGateway {
            let shown = url.flatMap(displayableBaseURL)
            // A URL we can't show safely is still a gateway, just an unnamed one.
            let recorded: Via = (url != nil && shown == nil && via != .none) ? .unknown : via
            return LaunchedGateway(baseURL: shown, via: recorded, agentKind: agentKind, at: at)
        }
        switch agentKind {
        case .claudeCode:
            if let settingsJSON, let url = settingsEnvBaseURL(settingsJSON: settingsJSON) {
                return make(url, .settingsEnv)
            }
            if let found = detect(launchText: launchText), found.via != .codexOverride {
                return make(found.baseURL, found.via)
            }
            return make(nil, .none)
        case .codex:
            if let found = detect(launchText: launchText), found.via == .codexOverride {
                return make(found.baseURL, found.via)
            }
            return make(nil, .none)
        default:
            return make(nil, .unknown)
        }
    }

    /// A base URL reduced to what is safe to show a remote `/rpc` peer:
    /// scheme, host, port and path. User info, query and fragment are dropped
    /// (a hand-written URL can carry a credential in any of them), and the
    /// result is capped at 256 characters. Nil when `raw` isn't an absolute
    /// URL with a host.
    ///
    /// The settings file it is read from can come from a review clone, so its
    /// content is treated as untrusted text.
    public static func displayableBaseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty
        else { return nil }
        comps.user = nil
        comps.password = nil
        comps.query = nil
        comps.fragment = nil
        guard let shown = comps.string else { return nil }
        return shown.count > 256 ? String(shown.prefix(256)) : shown
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
