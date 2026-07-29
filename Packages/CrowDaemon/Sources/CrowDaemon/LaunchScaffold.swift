import CrowClaude
import CrowCodex
import CrowCore
import CrowCursor
import CrowEngine
import CrowOpenCode
import CrowAntigravity
import CrowPersistence
import Foundation

/// The per-launch dev-root scaffold: bundled skills, `CLAUDE.md`,
/// `settings.local.json`, the `.claude/bin` symlinks, and the per-agent
/// (Codex / Cursor / OpenCode) dev-root + global hook configs.
///
/// This used to run on every `applicationDidFinishLaunching` in the macOS app's
/// `AppDelegate.launchMainApp`. That file was deleted when the native app was
/// retired for Web UI parity (`eb7a489`, ADR 0007) and nothing on the daemon
/// startup path replaced it, so a fresh install came up with an empty
/// `{devRoot}/.claude/skills/` and the Manager had no knowledge of
/// `/crow-workspace` (#766). The only surviving `Scaffolder.scaffold(...)` call
/// was the one-shot `run-setup` wizard, which is rejected once a dev-root
/// pointer exists — so upgrades never refreshed their skills either.
///
/// `CrowDaemon.run` calls this synchronously before `startBoardPoll`, whose
/// first tick calls `SessionService.ensureManagerSession` — so the files are on
/// disk before the Manager agent is spawned.
enum LaunchScaffold {

    /// Re-materialize the dev-root scaffold. Idempotent by construction:
    /// `Scaffolder` merges `settings.local.json`, preserves the user's
    /// `## Known Issues / Corrections` block in `CLAUDE.md`, and only owns its
    /// own symlinks — so this is safe (and intended) to run on every launch.
    ///
    /// `configured` gates the whole thing. `DaemonOptions.parse` falls back to
    /// the current working directory when no dev root is configured, and
    /// scaffolding *that* would scatter `.claude/skills/` into whatever
    /// directory `crowd` happened to be started from. Only an explicitly
    /// configured root (App Support pointer, `--dev-root`, or `CROW_DEV_ROOT`)
    /// is scaffolded.
    ///
    /// Never throws: a scaffold failure is logged and boot continues. Returns
    /// the non-fatal `corveil skill install` warning (`nil` when unconfigured or
    /// successful), which the caller mirrors into
    /// `AppState.corveilSkillInstallWarning`.
    @discardableResult
    static func run(devRoot: String, configured: Bool) -> String? {
        guard configured else { return nil }

        let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()

        var warning: String?
        do {
            let result = try Scaffolder(devRoot: devRoot).scaffold(
                workspaceNames: config.workspaces.map(\.name),
                managerAgentKind: config.agentKind(for: .manager),
                corveilBinaryPath: config.defaults.binaries["corveil"],
                binaryOverrides: config.defaults.binaries)
            warning = result.warning
            CrowDaemon.log("dev-root scaffold refreshed at \(devRoot)")
        } catch {
            CrowDaemon.log("WARNING: dev-root scaffold failed: \(error.localizedDescription)")
        }

        scaffoldAgents(devRoot: devRoot, mirrorClaudeMCPToCodex: config.defaults.mirrorClaudeMCPToCodex)
        return warning
    }

    /// Repair Crow-written Claude hook blocks that have gone stale on disk
    /// (#897) — commands naming a `crow` binary that no longer exists, or a
    /// session that has been deleted. Both make every hook event in that
    /// directory fail, which is noisy *and* silently drops all telemetry for
    /// sessions run there.
    ///
    /// Runs on every boot, right after `run(...)` has re-pointed the
    /// `{devRoot}/.claude/bin/crow` symlink, and before `startBoardPoll` —
    /// whose first tick calls `ensureManagerSession` — so it never races the
    /// Manager's own hook writer.
    ///
    /// Set `CROW_HOOK_REPAIR=0` to disable: this is the only code that mutates
    /// `settings.local.json` files Crow did not itself just write, so it ships
    /// with an escape hatch.
    static func repairStaleHooks(devRoot: String, configured: Bool, appState: AppState) async {
        guard configured else { return }
        guard ProcessInfo.processInfo.environment["CROW_HOOK_REPAIR"] != "0" else {
            CrowDaemon.log("hook repair: skipped (CROW_HOOK_REPAIR=0)")
            return
        }

        // Snapshot the live state as values so the scan itself needs no actor.
        let (liveSessionIDs, sessionByWorktreePath) = await MainActor.run {
            let live = Set(appState.sessions.map(\.id))
            // `uniquingKeysWith`, not `uniqueKeysWithValues`: the latter traps
            // on duplicate keys, and two rows sharing a worktree path is
            // reachable through orphan recovery.
            let byPath = Dictionary(
                appState.worktrees.values.flatMap { $0 }.map {
                    (($0.worktreePath as NSString).standardizingPath, $0.sessionID)
                },
                uniquingKeysWith: { first, _ in first })
            return (live, byPath)
        }

        let crowPath = ClaudeHookConfigWriter.resolveCrowBinary(devRoot: devRoot)
        let excludeDirs = Set(ConfigStore.loadConfig(devRoot: devRoot)?.defaults.excludeDirs ?? [])

        // Detached: a filesystem walk is blocking I/O and must not sit on the
        // MainActor (#892). Awaiting the task keeps boot ordering intact.
        let summary = await Task.detached(priority: .utility) {
            ClaudeHookRepair.sweep(
                devRoot: devRoot,
                crowPath: crowPath,
                liveSessionIDs: liveSessionIDs,
                sessionByWorktreePath: sessionByWorktreePath,
                managerSessionID: AppState.managerSessionID,
                excludeDirs: excludeDirs)
        }.value

        if summary.scanned > 0 {
            CrowDaemon.log("hook repair: \(summary.logLine)")
        }
    }

    /// Per-agent dev-root files and global hook configs, each gated on the agent
    /// actually being registered (i.e. its binary resolved on PATH or via a
    /// `defaults.binaries.*` override) — so a user without Codex installed never
    /// gets a `~/.codex`. `AGENTS.md` is shared by all three scaffolders; all are
    /// idempotent and preserve the user-edited `## Known Issues / Corrections`
    /// section, so co-existence is safe.
    private static func scaffoldAgents(devRoot: String, mirrorClaudeMCPToCodex: Bool) {
        let crowPath = ClaudeHookConfigWriter.resolveCrowBinary(devRoot: devRoot)

        if AgentRegistry.shared.agent(for: .codex) != nil {
            attempt("Codex scaffold") { try CodexScaffolder.scaffold(devRoot: devRoot) }
            // An empty `CODEX_HOME=` is treated as unset — otherwise
            // `appendingPathComponent("hooks.json")` on "" is a relative path
            // and the config writes into the process CWD, matching the empty
            // `XDG_CONFIG_HOME` guard below (#766 review).
            let codexHome = nonEmptyEnv("CODEX_HOME") ?? NSString(string: "~/.codex").expandingTildeInPath
            // Sweep any `.crow-codex-*.tmp` left by a crash between
            // `writeConfigPrivately`'s createFile and rename(2) — a 0600 temp
            // that may hold mirrored MCP tokens (#843 review round 5). Nothing
            // else cleans it; best-effort at boot.
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: codexHome) {
                for name in entries where name.hasPrefix(".crow-codex-") && name.hasSuffix(".tmp") {
                    try? FileManager.default.removeItem(
                        atPath: (codexHome as NSString).appendingPathComponent(name))
                }
            }
            if let crowPath {
                attempt("Codex global config install") {
                    try CodexHookConfigWriter.installGlobalConfig(codexHome: codexHome, crowPath: crowPath)
                    try CodexHookConfigWriter.installGlobalTomlConfig(codexHome: codexHome, crowPath: crowPath)
                }
            }
            // #830: mirror the user's Claude MCP servers (e.g. `jira`) into
            // Codex so Codex sessions get the same tools a Claude session
            // inherits from ~/.claude.json. Append-only; a no-op when the user
            // has no `mcpServers` configured. Independent of `crowPath`.
            // Gated by `defaults.mirrorClaudeMCPToCodex` (default on) because it
            // copies MCP `env` values (often API tokens) into a second file.
            if mirrorClaudeMCPToCodex {
                attempt("Codex MCP mirror") {
                    let added = try CodexMCPWriter.installMCPConfig(codexHome: codexHome)
                    if !added.isEmpty {
                        CrowDaemon.log("Codex MCP mirror: added \(added.count) server(s) [\(added.joined(separator: ", "))] from ~/.claude.json into \(codexHome)/config.toml — any configured env values (e.g. API tokens) were copied. Set defaults.mirrorClaudeMCPToCodex = false to opt out.")
                    }
                }
            }
        }

        if AgentRegistry.shared.agent(for: .cursor) != nil {
            attempt("Cursor scaffold") { try CursorScaffolder.scaffold(devRoot: devRoot) }
            // Empty `CURSOR_CONFIG_DIR=` treated as unset, same reason as
            // `CODEX_HOME` above.
            let cursorHome = nonEmptyEnv("CURSOR_CONFIG_DIR") ?? NSString(string: "~/.cursor").expandingTildeInPath
            // Per-worktree `.cursor/hooks.json` (with `--session` baked in) is
            // now the authority (#829), written by the engine per session.
            // Cursor merges global + project hooks and runs both, so any global
            // config a prior Crow installed would double-fire every event —
            // strip our managed entries from `~/.cursor/hooks.json` (user
            // entries survive). Doesn't need `crowPath`.
            attempt("Cursor global hook cleanup") {
                CursorHookConfigWriter.removeManagedGlobalConfig(cursorHome: cursorHome)
            }
            // The Jira MCP bridge is NOT run here. Gating it on "a binary named
            // `agent` is on PATH" would copy the user's token onto a CI box that
            // ships its own `agent`, and gating on config would miss Cursor
            // selected per-session (handoff / Manager picker). Instead it runs
            // when a Cursor agent actually launches — the strongest "Cursor is in
            // use" signal — from `SessionService` (#829 review).
        }

        if AgentRegistry.shared.agent(for: .openCode) != nil {
            attempt("OpenCode scaffold") { try OpenCodeScaffolder.scaffold(devRoot: devRoot) }
            // XDG spec: an empty `XDG_CONFIG_HOME` is treated as unset, so fall
            // through to ~/.config/opencode rather than a relative path.
            let configHome = nonEmptyEnv("XDG_CONFIG_HOME")
                .map { ($0 as NSString).appendingPathComponent("opencode") }
                ?? NSString(string: "~/.config/opencode").expandingTildeInPath
            // The state-bridge plugin needs the `crow` binary; the MCP mirror
            // does not — so gate only the former on `crowPath`.
            if let crowPath {
                attempt("OpenCode global config install") {
                    try OpenCodeHookConfigWriter.installGlobalConfig(configHome: configHome, crowPath: crowPath)
                }
            }
            // Mirror the user's Claude `jira` MCP into OpenCode's global config
            // so OpenCode sessions get the same `jira_*` tools (parity with
            // Claude; CROW-831). Never throws — it returns an Outcome — so
            // inspect and log non-success directly rather than through
            // `attempt`, whose catch branch would never fire.
            let mcpOutcome = OpenCodeMCPConfigWriter.installGlobalMCPConfig(configHome: configHome)
            switch mcpOutcome {
            case .registered, .removed, .unchanged, .skippedUserOwned, .noSource:
                CrowDaemon.log("OpenCode Jira MCP registration: \(mcpOutcome)")
            case .skippedUnparseable, .failed:
                CrowDaemon.log("WARNING: OpenCode Jira MCP registration: \(mcpOutcome)")
            }
        }

        if AgentRegistry.shared.agent(for: .antigravity) != nil {
            // Per-worktree `.agents/hooks.json` (with `--session` baked in) is the
            // authority (#860), written by the engine per session via the generic
            // `agent.hookConfigWriter` path. Antigravity may merge global +
            // workspace hooks and run both, so any global config a prior Crow
            // installed under `~/.gemini/config/` would double-fire every event —
            // strip our managed entries there (user entries survive). Doesn't need
            // `crowPath`. No dev-root scaffold and no MCP bridge in Phase A: the
            // launcher prompt uses `acli` for Jira (no MCP writer yet — deferred),
            // and Antigravity reads no shared `AGENTS.md` we own.
            //
            // Empty `GEMINI_CONFIG_HOME=` treated as unset, same reason as
            // `CODEX_HOME`/`CURSOR_CONFIG_DIR` above.
            let geminiConfigHome = nonEmptyEnv("GEMINI_CONFIG_HOME")
                ?? NSString(string: "~/.gemini/config").expandingTildeInPath
            attempt("Antigravity global hook cleanup") {
                AntigravityHookConfigWriter.removeManagedGlobalConfig(geminiConfigHome: geminiConfigHome)
            }
        }

        // Grok Build has no arm here, by design (not omission): it installs no
        // global config a prior Crow could leave behind — its hooks are the
        // per-worktree `.grok/hooks/crow.json` written by the engine's generic
        // `agent.hookConfigWriter` path, its trust store is seeded per-worktree by
        // `GrokTrustSeeder`, and it has no dev-root scaffold or global MCP bridge
        // in Phase A (the launcher prompt uses `acli` for Jira). Nothing to clean
        // up at daemon boot, so there's no `AgentRegistry.shared.agent(for: .grok)`
        // block (#861 review r8).
    }

    /// The value of environment variable `name`, or `nil` when it is unset or
    /// empty. An empty config-home var must never survive to
    /// `appendingPathComponent`, where "" yields a CWD-relative path.
    private static func nonEmptyEnv(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }

    /// Run one optional scaffold step, logging (never propagating) its failure —
    /// none of these are worth aborting daemon boot over.
    private static func attempt(_ label: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            CrowDaemon.log("WARNING: \(label) failed: \(error.localizedDescription)")
        }
    }
}
