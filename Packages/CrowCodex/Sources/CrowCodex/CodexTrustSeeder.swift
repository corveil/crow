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
/// every folder Crow ever opens, so a cloned repo's committed hooks never
/// execute on checkout.
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
    /// launches there. Pass `codexConfigPath` to target a different file
    /// (tests); `nil` uses the real `~/.codex/config.toml` (honoring
    /// `$CODEX_HOME` when set).
    @discardableResult
    public static func seedTrust(
        projectPath: String,
        codexConfigPath: String? = nil
    ) -> Outcome {
        let tomlPath = codexConfigPath ?? defaultConfigPath()

        // Codex keys `projects` by its resolved cwd, which may differ from the
        // path Crow launches with (symlinks). Trust both spellings so the gate
        // stays quiet regardless of which Codex canonicalizes to.
        var projectPaths = [projectPath]
        let resolved = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().path
        if resolved != projectPath {
            projectPaths.append(resolved)
        }

        let fm = FileManager.default
        let dir = (tomlPath as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .failed(error.localizedDescription)
        }

        var content = ""
        if let data = fm.contents(atPath: tomlPath),
           let text = String(data: data, encoding: .utf8) {
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
        }

        if content == original {
            return .alreadyTrusted
        }

        do {
            try content.write(toFile: tomlPath, atomically: true, encoding: .utf8)
            // config.toml can carry provider credentials — keep it owner-only,
            // matching Codex's own posture and `ClaudeTrustSeeder`'s 0600.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tomlPath)
            return .seeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `$CODEX_HOME/config.toml` when `CODEX_HOME` is set and non-empty,
    /// otherwise `~/.codex/config.toml`. Mirrors `LaunchScaffold`'s
    /// empty-var-is-unset guard so an empty `CODEX_HOME=` never yields a
    /// CWD-relative path.
    private static func defaultConfigPath() -> String {
        let codexHome: String
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            codexHome = env
        } else {
            codexHome = NSString(string: "~/.codex").expandingTildeInPath
        }
        return (codexHome as NSString).appendingPathComponent("config.toml")
    }
}
