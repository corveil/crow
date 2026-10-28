import Foundation

/// Seeds per-project trust into `~/.codex/config.toml` so Codex skips its
/// "Do you trust the files in this folder?" gate when Crow auto-launches a
/// session in a fresh worktree or review clone (#830). Codex's trusted-project
/// gate governs whether it will run in — and load project-scoped config from —
/// a directory; an untrusted folder blocks an unattended `codex` / `codex exec`
/// launch, exactly the way Claude Code's trust dialog does (the analog Crow
/// solves via `ClaudeTrustSeeder`, CROW-600). Trust does NOT inherit from
/// parent directories, so every fresh worktree/clone would otherwise prompt.
///
/// Codex records trust as
/// ```toml
/// [projects."/abs/path"]
/// trust_level = "trusted"
/// ```
/// This is the deliberate, bounded alternative to Codex's
/// `--dangerously-bypass-hook-trust` (which the #830 scope-correction forbids):
/// we persist trust for *this specific worktree* rather than blanket-trusting
/// every folder Crow ever opens.
///
/// **Only trust worktrees Crow creates off a trusted base.** `SessionService`
/// seeds trust for `.work`/`.job` git worktrees (branched from a trusted base)
/// and the Manager's devRoot — never for a `.review` clone, whose working tree
/// is `gh repo clone` output checked out at the PR author's head and is
/// therefore attacker-controlled. Trusting such a clone would arm a committed
/// `.codex/hooks.json` on launch (#843 review round 5); review clones fall back
/// to Codex's own folder-trust prompt (they're the human-gated path), and
/// `prepareReviewClone` additionally strips any committed `.codex/` as
/// defense-in-depth. So this seeder is safe *given that contract* — it does not
/// itself distinguish clone from worktree; the caller does.
///
/// **Per-hook trust (CROW-1381).** Folder trust alone does not make Codex run a
/// project's hooks: each non-managed hook also needs a `[hooks.state."<key>"]
/// trusted_hash` matching its current definition, or the TUI shows "Hooks need
/// review" and `codex exec` skips it. Without that, a seeded `.work`/`.job`
/// launch either blocks on the prompt or, if someone picks "Continue without
/// trusting", loses `Stop` and with it Crow's completion detection. So callers
/// pass `hookHashes` (from `CodexHookConfigWriter.hookTrustHashes`) and this
/// writes them in the same edit as `trust_level`. They are hashes of the
/// commands **Crow generates**, so a hooks.json Crow didn't write still gates.
/// Same `.review` contract as folder trust: the caller never seeds a clone.
///
/// `config.toml` is Codex's own mutable state (model, providers, credentials,
/// `[hooks]`, other projects), so this **merges** — it only inserts/updates the
/// `trust_level` line inside the target `[projects."…"]` table, preserving every
/// other line. A concurrently running `codex` may rewrite the file; the atomic
/// write plus skip-when-unchanged keeps that window small, and losing our write
/// only re-shows the trust gate (benign).
public enum CodexTrustSeeder {

    public enum Outcome: Equatable {
        /// The trust line was written/updated for the project path.
        case seeded
        /// Every target path was already trusted; nothing written.
        case alreadyTrusted
        /// Read or write failed.
        case failed(String)
    }

    /// Ensure `~/.codex/config.toml` marks `projectPath` as trusted before Codex
    /// launches there, and trusts each of Crow's hooks in its
    /// `.codex/hooks.json`. `hookHashes` maps a `hooks.state` event label
    /// (`stop`) to its `sha256:` hash; empty seeds folder trust only. Pass
    /// `codexConfigPath` to target a different file (tests); `nil` uses the
    /// real `~/.codex/config.toml` (honoring `$CODEX_HOME` when set).
    @discardableResult
    public static func seedTrust(
        projectPath: String,
        hookHashes: [String: String] = [:],
        codexConfigPath: String? = nil
    ) -> Outcome {
        let tomlPath = codexConfigPath ?? defaultConfigPath()

        // Codex keys `projects` (and the `hooks.state` paths) by its resolved
        // cwd, which may differ from the path Crow launches with (symlinks).
        // Trust both spellings so the gate stays quiet regardless of which
        // Codex canonicalizes to.
        let projectPaths = pathSpellings(projectPath)

        let fm = FileManager.default
        let dir = (tomlPath as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .failed(error.localizedDescription)
        }

        var content = ""
        if let data = fm.contents(atPath: tomlPath) {
            // "Exists but not UTF-8" must not read as "" — that would truncate a
            // config.toml holding credentials/providers/trusted-projects on the
            // read-modify-write. Refuse instead (#843 review round 6).
            guard let text = String(data: data, encoding: .utf8) else {
                return .failed("\(tomlPath) is not valid UTF-8; refusing to rewrite")
            }
            content = text
        }

        let original = content
        for path in projectPaths {
            // The path is a TOML quoted key inside the dotted section header
            // `[projects."<path>"]`; escape it so a path with a quote/backslash
            // can't break the header.
            let section = "projects.\"\(CodexHookConfigWriter.escapeTomlString(path))\""
            content = CodexHookConfigWriter.upsertTomlSectionLine(
                content,
                section: section,
                key: "trust_level",
                line: "trust_level = \"trusted\""
            )
            // Sorted so the appended tables land in a stable order.
            for (label, hash) in hookHashes.sorted(by: { $0.key < $1.key }) {
                let key = CodexHookTrust.stateKey(projectPath: path, eventLabel: label)
                content = CodexHookConfigWriter.upsertTomlSectionLine(
                    content,
                    section: "hooks.state.\"\(CodexHookConfigWriter.escapeTomlString(key))\"",
                    key: "trusted_hash",
                    line: "trusted_hash = \"\(CodexHookConfigWriter.escapeTomlString(hash))\""
                )
            }
        }

        if content == original {
            return .alreadyTrusted
        }

        do {
            // config.toml can carry provider credentials — write via the
            // owner-only-temp path so secrets never touch a 0644 temp.
            try CodexHookConfigWriter.writeConfigPrivately(content, toFile: tomlPath)
            return .seeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Remove every `[hooks.state."…"]` table for `projectPath`'s
    /// `.codex/hooks.json` (both path spellings) — the per-hook trust
    /// `seedTrust` recorded. Called when Crow deletes its hooks file, so a
    /// reaped session doesn't leave its tables in `config.toml` forever.
    /// Folder trust is left alone, as it always has been. Never creates the
    /// file; `.alreadyTrusted` means there was nothing to remove.
    @discardableResult
    public static func removeHookTrust(
        projectPath: String,
        codexConfigPath: String? = nil
    ) -> Outcome {
        let tomlPath = codexConfigPath ?? defaultConfigPath()
        guard let data = FileManager.default.contents(atPath: tomlPath) else {
            return .alreadyTrusted
        }
        guard let content = String(data: data, encoding: .utf8) else {
            return .failed("\(tomlPath) is not valid UTF-8; refusing to rewrite")
        }
        let prefixes = pathSpellings(projectPath).map {
            CodexHookTrust.stateKeyPrefix(projectPath: $0)
        }
        let updated = removeTomlSections(content) { segments in
            segments.count == 3 && segments[0] == "hooks" && segments[1] == "state"
                && prefixes.contains { segments[2].hasPrefix($0) }
        }
        if updated == content {
            return .alreadyTrusted
        }
        do {
            try CodexHookConfigWriter.writeConfigPrivately(updated, toFile: tomlPath)
            return .seeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Drop each `[table]` whose header segments satisfy `matches`, from its
    /// header up to the next header. Header matching goes through
    /// `tomlHeaderSegments`, so it tolerates the same spellings the upsert does.
    /// A quoted segment's escapes are left as written, which is fine for the
    /// absolute paths Crow seeds.
    static func removeTomlSections(
        _ content: String, where matches: ([String]) -> Bool
    ) -> String {
        var kept: [String] = []
        var dropping = false
        for line in content.components(separatedBy: "\n") {
            if let segments = CodexHookConfigWriter.tomlHeaderSegments(line) {
                dropping = matches(segments)
            }
            if !dropping {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n")
    }

    /// `path` plus its symlink-resolved spelling when that differs.
    private static func pathSpellings(_ path: String) -> [String] {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved == path ? [path] : [path, resolved]
    }

    /// `$CODEX_HOME/config.toml` when `CODEX_HOME` is set and non-empty,
    /// otherwise `~/.codex/config.toml`. Delegates the home resolution to
    /// `CodexHome` — the one source of truth shared with the log collector and
    /// the launch path (CROW-1089) — so an empty `CODEX_HOME=` never yields a
    /// CWD-relative path.
    private static func defaultConfigPath() -> String {
        (CodexHome.path() as NSString).appendingPathComponent("config.toml")
    }
}
