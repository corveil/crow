import CrowClaude
import CrowCodex
import CrowCore
import CrowCursor
import CrowEngine
import CrowOpenCode
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

        scaffoldAgents(devRoot: devRoot)
        return warning
    }

    /// Per-agent dev-root files and global hook configs, each gated on the agent
    /// actually being registered (i.e. its binary resolved on PATH or via a
    /// `defaults.binaries.*` override) — so a user without Codex installed never
    /// gets a `~/.codex`. `AGENTS.md` is shared by all three scaffolders; all are
    /// idempotent and preserve the user-edited `## Known Issues / Corrections`
    /// section, so co-existence is safe.
    private static func scaffoldAgents(devRoot: String) {
        let crowPath = ClaudeHookConfigWriter.findCrowBinary(devRoot: devRoot)

        if AgentRegistry.shared.agent(for: .codex) != nil {
            attempt("Codex scaffold") { try CodexScaffolder.scaffold(devRoot: devRoot) }
            if let crowPath {
                // An empty `CODEX_HOME=` is treated as unset — otherwise
                // `appendingPathComponent("hooks.json")` on "" is a relative path
                // and the config writes into the process CWD, matching the empty
                // `XDG_CONFIG_HOME` guard below (#766 review).
                let codexHome = nonEmptyEnv("CODEX_HOME") ?? NSString(string: "~/.codex").expandingTildeInPath
                attempt("Codex global config install") {
                    try CodexHookConfigWriter.installGlobalConfig(codexHome: codexHome, crowPath: crowPath)
                    try CodexHookConfigWriter.installGlobalTomlConfig(codexHome: codexHome, crowPath: crowPath)
                }
            }
        }

        if AgentRegistry.shared.agent(for: .cursor) != nil {
            attempt("Cursor scaffold") { try CursorScaffolder.scaffold(devRoot: devRoot) }
            if let crowPath {
                // Empty `CURSOR_CONFIG_DIR=` treated as unset, same reason as
                // `CODEX_HOME` above.
                let cursorHome = nonEmptyEnv("CURSOR_CONFIG_DIR") ?? NSString(string: "~/.cursor").expandingTildeInPath
                attempt("Cursor global config install") {
                    try CursorHookConfigWriter.installGlobalConfig(cursorHome: cursorHome, crowPath: crowPath)
                }
            }
        }

        if AgentRegistry.shared.agent(for: .openCode) != nil {
            attempt("OpenCode scaffold") { try OpenCodeScaffolder.scaffold(devRoot: devRoot) }
            if let crowPath {
                // XDG spec: an empty `XDG_CONFIG_HOME` is treated as unset, so
                // fall through to ~/.config/opencode rather than a relative path.
                let configHome = nonEmptyEnv("XDG_CONFIG_HOME")
                    .map { ($0 as NSString).appendingPathComponent("opencode") }
                    ?? NSString(string: "~/.config/opencode").expandingTildeInPath
                attempt("OpenCode global config install") {
                    try OpenCodeHookConfigWriter.installGlobalConfig(configHome: configHome, crowPath: crowPath)
                }
                // Mirror the user's Claude `jira` MCP into OpenCode's global
                // config so OpenCode sessions get the same `jira_*` tools
                // (parity with Claude; CROW-831). Never throws — it returns an
                // Outcome — so inspect and log non-success directly rather than
                // through `attempt`, whose catch branch would never fire.
                let mcpOutcome = OpenCodeMCPConfigWriter.installGlobalMCPConfig(configHome: configHome)
                switch mcpOutcome {
                case .registered, .removed, .unchanged, .noSource:
                    CrowDaemon.log("OpenCode Jira MCP registration: \(mcpOutcome)")
                case .skippedUnparseable, .failed:
                    CrowDaemon.log("WARNING: OpenCode Jira MCP registration: \(mcpOutcome)")
                }
            }
        }
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
