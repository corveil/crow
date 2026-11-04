import Foundation
import CrowCore

/// Routes a Codex launch through a workspace's (or the Manager's) AI gateway
/// using Corveil's `/v1/responses` passthrough (CROW-1407, ADR 0030).
///
/// Claude gets the gateway as `ANTHROPIC_BASE_URL` / `ANTHROPIC_CUSTOM_HEADERS`.
/// Codex can't take that shape: Corveil returns 401 when its own key arrives in
/// `Authorization` (corveil#5022), and Codex has to keep sending its own ChatGPT
/// or OpenAI credential there so Corveil can forward it upstream. So Codex gets
/// a **per-run model provider**, built from `-c` config overrides, that never
/// touches the user's `~/.codex/config.toml`:
///
/// ```
/// codex -c model_provider=crow-corveil
///       -c model_providers.crow-corveil.name=Corveil
///       -c model_providers.crow-corveil.base_url='https://corveil.io/v1'
///       -c model_providers.crow-corveil.wire_api=responses
///       -c model_providers.crow-corveil.requires_openai_auth=true
///       -c model_providers.crow-corveil.http_headers.X-Corveil-Upstream=chatgpt_codex
///       -c model_providers.crow-corveil.env_http_headers.X-Corveil-Key=CROW_CORVEIL_GATEWAY_KEY
/// ```
///
/// **The key is never in these overrides.** `env_http_headers` names an
/// environment variable, and Codex reads the header value from it at request
/// time. The overrides hold only the base URL, the upstream and that variable's
/// name, so they are safe to persist (a Manager terminal's stored `command`), to
/// send over the socket (`crow new-terminal --command`), and to show in `ps`.
/// The variable is set separately by ``keyExportPrefix(_:)``. The daemon types
/// that prefix into the pane immediately before the command, so the key is shell
/// state, never argv. This is the same trick the Claude prefix uses, minus
/// Claude's `settings.local.json` copy, because nothing Codex or Grok reads
/// carries the key.
///
/// Formatting constraints, all deliberate:
///
/// - **No `"` anywhere.** Codex's prompt-seeded launches go through
///   ``ShellLaunchArgs/evalPromptLaunch(prefix:promptPath:endOfOptions:)``, which
///   wraps the prefix in `eval "…"`, so a double quote would end that string.
///   Dotted keys (`http_headers.X-Corveil-Upstream=…`) replace the inline TOML
///   tables the ticket sketched, and bare values rely on Codex's documented
///   fallback: "If it fails to parse as TOML, the raw string is used as a
///   literal."
/// - **Its own provider id** (`crow-corveil`, not `corveil`). Users who followed
///   Corveil's Codex guide already have a `[model_providers.corveil]` table with
///   the key inline in `http_headers`. `-c` merges into a same-named table, so
///   reusing the name would send their header and ours together.
/// - **A Crow-specific env var** (`CROW_CORVEIL_GATEWAY_KEY`, not
///   `CORVEIL_API_KEY`). The `corveil` CLI reads `CORVEIL_API_KEY` as an
///   override of its stored profile, so exporting the gateway key under that
///   name would silently change which key every `corveil` command in the
///   session uses. The name also contains `KEY`, which Codex's default
///   `shell_environment_policy` excludes from the commands it runs.
public enum CodexGatewayArgs {
    /// The per-run model provider id. See the type doc for why not `corveil`.
    public static let providerID = "crow-corveil"

    /// The env var Codex reads the Corveil key from (`env_http_headers`).
    public static let keyEnvVar = "CROW_CORVEIL_GATEWAY_KEY"

    /// The header Corveil reads the virtual key from in passthrough mode.
    public static let keyHeader = "X-Corveil-Key"

    /// Gateway header names that carry a Corveil key, compared case-insensitively.
    /// Corveil accepts the key under either name, and Crow's own derived gateways
    /// use `x-citadel-api-key` (``CorveilConnection/gatewayAPIKeyHeader``). A
    /// gateway with neither isn't a Corveil gateway, so there is no
    /// `/v1/responses` passthrough to route Codex to.
    public static let keyHeaderNames: [String] = ["x-citadel-api-key", "x-corveil-key"]

    /// The override that names ``keyEnvVar``. Its presence in a command is how the
    /// paste paths know the command needs ``keyExportPrefix(_:)`` (see
    /// ``commandRequestsKey(_:)``).
    static var keyOverride: String {
        "model_providers.\(providerID).env_http_headers.\(keyHeader)=\(keyEnvVar)"
    }

    /// The non-secret half of a routed Codex launch: where to send requests and
    /// which upstream Corveil should forward them to.
    public struct Route: Equatable, Sendable {
        /// The gateway base URL with `/v1` appended. Codex's provider
        /// `base_url` is the API root, and Corveil's Codex docs require the suffix.
        public var baseURL: String
        /// The `X-Corveil-Upstream` value: `chatgpt_codex` or `openai_api`.
        public var upstream: String

        public init(baseURL: String, upstream: String) {
            self.baseURL = baseURL
            self.upstream = upstream
        }
    }

    /// How Codex is signed in, read from `$CODEX_HOME/auth.json`.
    public enum AuthMode: Equatable, Sendable {
        case chatgpt
        case apiKey
    }

    /// Why a gateway didn't produce a ``Route``, for the one-line launch log.
    public enum Skip: Error, Equatable, Sendable {
        /// No gateway, or an empty one.
        case noGateway
        /// The gateway has not opted Codex in (`codexUpstream` unset).
        case notOptedIn
        /// The gateway carries no Corveil key header, so it isn't a Corveil gateway.
        case notCorveil
        /// The base URL has characters that can't sit safely inside the
        /// `eval "…"` launch line.
        case unsafeBaseURL

        public var reason: String {
            switch self {
            case .noGateway: return "no gateway"
            case .notOptedIn: return "the gateway has not opted Codex in (crow gateway set … --codex-upstream)"
            case .notCorveil: return "the gateway has no x-citadel-api-key / X-Corveil-Key header, so it is not a Corveil gateway"
            case .unsafeBaseURL: return "the gateway base URL contains shell-special characters"
            }
        }
    }

    /// Decide whether `gateway` routes Codex, and where. Pure apart from
    /// `authMode`, which is only consulted for ``CodexUpstream/auto``.
    ///
    /// When `auto` can't tell how Codex is signed in (no `auth.json`, or a
    /// keyring-backed credential store), it falls back to `chatgpt_codex`, the
    /// common sign-in. A wrong guess fails loudly at the gateway with a 401. It
    /// never silently bypasses Corveil.
    public static func route(
        for gateway: WorkspaceGateway?,
        authMode: () -> AuthMode? = { readAuthMode() }
    ) -> Result<Route, Skip> {
        guard let gateway, !gateway.isEmpty else { return .failure(.noGateway) }
        guard let mode = gateway.codexUpstream else { return .failure(.notOptedIn) }
        guard keyHeaderName(in: gateway) != nil else { return .failure(.notCorveil) }
        guard let base = responsesBaseURL(gateway.baseURL) else { return .failure(.unsafeBaseURL) }
        let upstream: CodexUpstream
        switch mode {
        case .auto:
            upstream = authMode() == .apiKey ? .openaiAPI : .chatgptCodex
        case .chatgptCodex, .openaiAPI:
            upstream = mode
        }
        return .success(Route(baseURL: base, upstream: upstream.rawValue))
    }

    /// The stored name of the gateway's Corveil key header, if it has one.
    static func keyHeaderName(in gateway: WorkspaceGateway) -> String? {
        gateway.customHeaders.keys.sorted().first { name in
            keyHeaderNames.contains(name.lowercased())
        }
    }

    /// `baseURL` with a single trailing `/v1`, or nil when it is blank or holds a
    /// character that is unsafe on the launch line. The line can be pasted into an
    /// interactive zsh inside `eval "…"`, so `"`, `$`, `` ` `` and `\` would be
    /// re-interpreted, `!` would trigger history expansion, `'` would break the
    /// quoting, and whitespace or control characters would split or submit it.
    /// A real gateway URL has none of these.
    static func responsesBaseURL(_ raw: String) -> String? {
        var base = raw.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        let forbidden = CharacterSet(charactersIn: "\"$`\\!'")
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        guard base.rangeOfCharacter(from: forbidden) == nil else { return nil }
        return base.hasSuffix("/v1") ? base : base + "/v1"
    }

    /// The `-c` overrides for `route`, with a leading space so they append
    /// directly after the `codex` binary path, or `""` when Codex isn't routed.
    /// Root-level `-c` also applies to `codex resume …`, so one placement covers
    /// fresh launches and resumes (verified on codex-cli 0.147.0).
    public static func configOverrides(_ route: Route?) -> String {
        guard let route else { return "" }
        let p = "model_providers.\(providerID)"
        let pairs = [
            "model_provider=\(providerID)",
            "\(p).name=Corveil",
            "\(p).base_url=\(ShellLaunchArgs.shellQuote(route.baseURL))",
            "\(p).wire_api=responses",
            "\(p).requires_openai_auth=true",
            "\(p).http_headers.X-Corveil-Upstream=\(route.upstream)",
            keyOverride,
        ]
        return pairs.map { " -c \($0)" }.joined()
    }

    /// Whether `command` carries the overrides that read ``keyEnvVar``, so the
    /// key must be exported before it runs.
    public static func commandRequestsKey(_ command: String) -> Bool {
        command.contains(keyOverride)
    }

    /// `export CROW_CORVEIL_GATEWAY_KEY='…' && `, typed into the pane ahead of a
    /// routed command. `export … &&` rather than a bare `VAR=… cmd` assignment so
    /// it binds through a `cd … && _CROW_P=…; eval "…"` launch line, the same
    /// reason ``ClaudeLaunchArgs`` uses the form. A key with a control character
    /// (a pasted newline would submit the line early) is exported empty. Codex
    /// then omits the header and Corveil rejects the request loudly instead of the
    /// paste misfiring.
    public static func keyExportPrefix(_ key: String) -> String {
        let safe = key.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil ? key : ""
        return "export \(keyEnvVar)=\(ShellLaunchArgs.shellQuote(safe)) && "
    }

    /// Resolve the gateway's Corveil key: the stored value, or the secret behind an
    /// `op://` reference. Nil when the gateway has no key header or the reference
    /// fails. The caller still routes in that case, and Corveil returns a 401,
    /// matching ``GatewayResolver``'s "fail loudly at the gateway" rule. Never
    /// logged.
    public static func resolveKey(
        _ gateway: WorkspaceGateway,
        resolveSecret: (String) -> String? = GatewayResolver.opRead
    ) -> String? {
        guard let name = keyHeaderName(in: gateway),
              let value = gateway.customHeaders[name] else { return nil }
        if value.hasPrefix("op://") {
            guard let secret = resolveSecret(value) else {
                CrowLog.info("[CodexGatewayArgs] Failed to resolve secret reference for header '\(name)'; Codex will reach the gateway without X-Corveil-Key and be rejected")
                return nil
            }
            return secret
        }
        return value
    }

    /// Read how Codex is signed in from `<codexHome>/auth.json`, looking only at
    /// its mode, never a token. `auth_mode` is authoritative when present. Older
    /// files lack it, so fall back to which credential is populated. Nil when the
    /// file is missing or unreadable (keyring storage, never signed in).
    public static func readAuthMode(codexHome: String = CodexHome.path()) -> AuthMode? {
        let path = (codexHome as NSString).appendingPathComponent("auth.json")
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return authMode(fromAuthJSON: object)
    }

    static func authMode(fromAuthJSON object: [String: Any]) -> AuthMode? {
        if let mode = (object["auth_mode"] as? String)?.lowercased() {
            if mode.contains("chatgpt") { return .chatgpt }
            if mode.contains("api") { return .apiKey }
        }
        if object["tokens"] is [String: Any] { return .chatgpt }
        if let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty { return .apiKey }
        return nil
    }
}
