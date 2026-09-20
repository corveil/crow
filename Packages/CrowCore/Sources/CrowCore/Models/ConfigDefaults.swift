import Foundation

/// Default settings applied when creating new workspaces or sessions.
public struct ConfigDefaults: Codable, Sendable, Equatable {
    public var provider: String
    public var cli: String
    public var branchPrefix: String
    public var excludeDirs: [String]
    public var excludeReviewRepos: [String]
    public var excludeTicketRepos: [String]
    public var ignoreReviewLabels: [String]
    /// Absolute-path overrides for executable binaries, keyed by tool name.
    ///
    /// Serves two callers that share the same map shape:
    /// - **Agent binary discovery** (CROW-484): keyed by `AgentKind.rawValue`
    ///   (`"codex"`, `"cursor"`, `"claude-code"`). `CodingAgent.findBinary()`
    ///   consults this map before walking PATH — set this when discovery
    ///   doesn't find your install (exotic Node manager, sandboxed PATH, etc.).
    /// - **External tool installers** (CROW-482): keyed by tool name (e.g.
    ///   `"corveil"`) and used by `Scaffolder` to run each tool's own skill
    ///   installer on launch. The Settings UI currently exposes only the
    ///   `corveil` slot; the map shape is intentionally generic so future
    ///   tools (soulstone, tanzanite, …) extend the same field without a
    ///   schema change.
    ///
    /// Agent keys (`claude-code`, `codex`, `cursor`) and tool keys (`corveil`,
    /// …) don't overlap, so the two callers coexist in one map.
    public var binaries: [String: String]

    /// Whether Crow mirrors the user's `~/.claude.json` `mcpServers` into Codex's
    /// `~/.codex/config.toml` on daemon boot (#830). Default `true` for MCP
    /// parity with Claude sessions. Set `false` to opt out: mirroring copies MCP
    /// `env` values (often API tokens) into a second on-disk file, so a user who
    /// deliberately keeps credentials in one place can suppress the duplication.
    public var mirrorClaudeMCPToCodex: Bool

    /// When true, Crow downloads the host-platform `corveil` CLI from the public
    /// `corveil/corveil-releases` GitHub repo and links it under Application
    /// Support (CROW-1210). Default **on** (CROW-1229) so a fresh install gets a
    /// CLI without pointing `binaries["corveil"]` at a build. A missing key
    /// decodes as on; an explicit `false` stays off **after** the CROW-1247
    /// leftover one-shot (see ``corveilAutoUpdateOptOut``).
    ///
    /// When this is on, Crow owns `binaries["corveil"]` — a previous source-build
    /// path is adopted onto the managed install, not skipped. Turn it off to
    /// keep an operator path, including `out/`.
    public var corveilAutoUpdate: Bool

    /// Sticky sentinel (CROW-1247). Distinguishes leftover `corveilAutoUpdate:
    /// false` persisted when #1228 defaulted the toggle off from a later
    /// explicit opt-out. Missing decodes as false. Once true, a `false`
    /// auto-update flag is left alone and is not one-shot onto the downloader
    /// again. Not a user-facing setting — written when the leftover adopt
    /// runs and when the operator sets auto-update off.
    public var corveilAutoUpdateOptOut: Bool

    /// Which `corveil-releases` tag to keep linked: `"latest"` or a pin like
    /// `"v0.4.32"`. Ignored unless `corveilAutoUpdate` is on.
    public var corveilVersion: String

    /// Forge providers the Settings → Workspaces picker offers.
    ///
    /// Lives on the model, not in the CLI or the RPC layer, so `crow defaults
    /// set --provider` and the `defaults-set` handler validate against one list
    /// (CROW-810). `GitManager` compares `provider` with `==`, so a casing
    /// variant is a real mismatch, not a cosmetic one — hence no lowercasing
    /// anywhere; callers are told the exact accepted spellings.
    public static let validProviders = ["github", "gitlab"]

    /// Forge CLIs `GitManager` shells out to. Paired with `validProviders`, but
    /// stored independently — see `provider`/`cli` in `GitManager`.
    public static let validCLIs = ["gh", "glab"]

    /// Binary-override name `Scaffolder` owns outright.
    ///
    /// Mirrors its `managedBinarySymlinks`: the reap loop skips this key and
    /// `ClaudeHookConfigWriter.ensureCrowCLISymlink` re-points it at the running
    /// app's own CLI on every launch, while `BinaryOverrides` never consults it
    /// (it is not an `AgentKind`). An override here can therefore never take effect.
    public static let reservedBinaryName = "crow"

    /// Whether a `binaries` key is safe to write.
    ///
    /// The name becomes `{devRoot}/.claude/bin/<name>` in
    /// `Scaffolder.installBinarySymlinks`, which builds that path with
    /// `appendingPathComponent` and then `removeItem`s it before symlinking. A
    /// **blank** name resolves to the bin *directory*, which that code would
    /// delete and replace with a symlink; a name containing a path separator
    /// escapes the directory entirely, and the reap loop (which walks
    /// `contentsOfDirectory`) could never clean the orphan up.
    public static func isValidBinaryName(_ name: String) -> Bool {
        guard !name.isEmpty, name != reservedBinaryName else { return false }
        return !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }

    /// Sentinel for `corveilVersion`: resolve the current
    /// `corveil/corveil-releases` GitHub release at check time (CROW-1210).
    public static let corveilVersionLatest = "latest"

    /// Canonicalize a `corveilVersion` value: `"latest"`, or a `vX.Y.Z` tag.
    ///
    /// Shared by `crow defaults set --corveil-version` and `defaults-set` so the
    /// CLI and the daemon cannot drift on what a pin looks like. A path-like
    /// value is rejected — the string becomes a directory name under Application
    /// Support, and `..` / `/` would escape it.
    public static func normalizedCorveilVersion(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased() == corveilVersionLatest { return corveilVersionLatest }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("..") {
            return nil
        }
        let rest: String
        if trimmed.first == "v" || trimmed.first == "V" {
            rest = String(trimmed.dropFirst())
        } else {
            rest = trimmed
        }
        guard rest.range(of: #"^\d+\.\d+\.\d+([.-][0-9A-Za-z]+)*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "v" + rest
    }

    /// Characters that are invalid in git ref names (see `git check-ref-format`).
    private static let invalidBranchChars = CharacterSet(charactersIn: " ~^:?*[\\")

    /// Check whether a branch prefix is valid for use in git ref names.
    ///
    /// Rejects prefixes containing characters forbidden by `git check-ref-format`,
    /// as well as patterns like consecutive dots or a trailing dot/slash.
    public static func isValidBranchPrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true } // empty is allowed (means no prefix)
        if prefix.unicodeScalars.contains(where: { invalidBranchChars.contains($0) }) {
            return false
        }
        if prefix.contains("..") { return false }
        if prefix.hasSuffix(".") { return false }
        if prefix.contains("@{") { return false }
        return true
    }

    public init(
        provider: String = "github",
        cli: String = "gh",
        branchPrefix: String = "feature/",
        excludeDirs: [String] = ["node_modules", ".git", "vendor", "dist", "build", "target"],
        excludeReviewRepos: [String] = [],
        excludeTicketRepos: [String] = [],
        ignoreReviewLabels: [String] = [],
        binaries: [String: String] = [:],
        mirrorClaudeMCPToCodex: Bool = true,
        corveilAutoUpdate: Bool = true,
        corveilAutoUpdateOptOut: Bool = false,
        corveilVersion: String = ConfigDefaults.corveilVersionLatest
    ) {
        self.provider = provider
        self.cli = cli
        self.branchPrefix = branchPrefix
        self.excludeDirs = excludeDirs
        self.excludeReviewRepos = excludeReviewRepos
        self.excludeTicketRepos = excludeTicketRepos
        self.ignoreReviewLabels = ignoreReviewLabels
        self.binaries = binaries
        self.mirrorClaudeMCPToCodex = mirrorClaudeMCPToCodex
        self.corveilAutoUpdate = corveilAutoUpdate
        self.corveilAutoUpdateOptOut = corveilAutoUpdateOptOut
        self.corveilVersion = Self.normalizedCorveilVersion(corveilVersion) ?? Self.corveilVersionLatest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "github"
        cli = try container.decodeIfPresent(String.self, forKey: .cli) ?? "gh"
        branchPrefix = try container.decodeIfPresent(String.self, forKey: .branchPrefix) ?? "feature/"
        excludeDirs = try container.decodeIfPresent([String].self, forKey: .excludeDirs) ?? ["node_modules", ".git", "vendor", "dist", "build", "target"]
        excludeReviewRepos = try container.decodeIfPresent([String].self, forKey: .excludeReviewRepos) ?? []
        excludeTicketRepos = try container.decodeIfPresent([String].self, forKey: .excludeTicketRepos) ?? []
        ignoreReviewLabels = try container.decodeIfPresent([String].self, forKey: .ignoreReviewLabels) ?? []
        binaries = try container.decodeIfPresent([String: String].self, forKey: .binaries) ?? [:]
        mirrorClaudeMCPToCodex = try container.decodeIfPresent(Bool.self, forKey: .mirrorClaudeMCPToCodex) ?? true
        corveilAutoUpdate = try container.decodeIfPresent(Bool.self, forKey: .corveilAutoUpdate) ?? true
        corveilAutoUpdateOptOut = try container.decodeIfPresent(Bool.self, forKey: .corveilAutoUpdateOptOut) ?? false
        if let raw = try container.decodeIfPresent(String.self, forKey: .corveilVersion),
           let normalized = Self.normalizedCorveilVersion(raw) {
            corveilVersion = normalized
        } else {
            corveilVersion = Self.corveilVersionLatest
        }
    }

    private enum CodingKeys: String, CodingKey {
        case provider, cli, branchPrefix, excludeDirs, excludeReviewRepos, excludeTicketRepos, ignoreReviewLabels, binaries, mirrorClaudeMCPToCodex, corveilAutoUpdate, corveilAutoUpdateOptOut, corveilVersion
    }

    /// Sticky OR for ``corveilAutoUpdateOptOut`` across a `set-config` replace
    /// (CROW-1247). Once true it stays true; a true→false auto-update transition
    /// also sets it. A leftover `false` that is saved unchanged does **not**.
    public static func stickyOptOutSentinel(
        incoming: Bool,
        stored: Bool?,
        storedAutoUpdate: Bool?,
        incomingAutoUpdate: Bool
    ) -> Bool {
        let storedSentinel = stored ?? false
        let wasOn = storedAutoUpdate ?? true
        return storedSentinel || incoming || (wasOn && !incomingAutoUpdate)
    }
}
