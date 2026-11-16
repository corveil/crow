import Foundation

/// The Crow build sent to an AI gateway as `X-Crow-Version` (CROW-1458).
///
/// A gateway's request log records the agent's own `User-Agent` (Claude Code,
/// Codex) and nothing about Crow, so a team could not tell which Crow build each
/// person ran. Every gateway request a Crow-launched agent makes now carries
/// `X-Crow-Version: <version>+<short sha>`, e.g. `0.2.0+8e32cc67`, or
/// `0.2.0+dev` for an unstamped build.
///
/// - Claude Code: ``GatewayResolver/resolve(_:crowVersion:resolveSecret:)``
///   appends the header to `ANTHROPIC_CUSTOM_HEADERS`, unless the gateway
///   already configures a header with that name (the user's value wins).
/// - Codex: `CodexGatewayArgs` names an env var in an `env_http_headers`
///   override, and the paste-time key export sets it, so a stored Manager
///   command never pins an old build.
///
/// The value holds only `[A-Za-z0-9._-]` plus the one `+` separator. It comes
/// from ``BuildInfo`` alone: no path, hostname or user data.
///
/// `crowd` calls ``install(_:)`` once at startup with the build it loaded. A
/// process that never installs one (the CLI, a test) sends no header.
public enum CrowVersionHeader {
    /// The header name, as sent.
    public static let name = "X-Crow-Version"

    /// Longest version or SHA component kept. A real one is far shorter; the cap
    /// only bounds a hand-edited `version.json`.
    static let maxComponentLength = 40

    /// `<version>+<short sha>` for `build`, reduced to the allowed characters.
    /// A component that is empty after that, or the loader's `"?"`
    /// placeholder, becomes `unknown`.
    public static func value(for build: BuildInfo) -> String {
        "\(component(build.version))+\(component(build.gitSha))"
    }

    static func component(_ raw: String) -> String {
        let kept = String(raw.unicodeScalars.filter { allowed.contains($0) }.prefix(maxComponentLength))
        return kept.isEmpty ? "unknown" : kept
    }

    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// The value this process sends, or nil when no build was installed.
    public static var current: String? { box.value }

    /// Record the running build. `crowd` calls this once at startup, before any
    /// agent launches. Nil clears it.
    public static func install(_ build: BuildInfo?) {
        box.value = build.map(value(for:))
    }

    /// Whether `headerNames` already holds this header, compared
    /// case-insensitively as HTTP does.
    public static func isConfigured(in headerNames: some Sequence<String>) -> Bool {
        headerNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static let box = Box()

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }
}
