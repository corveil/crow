import Foundation
import CrowCore

/// Installs the Crow ↔ OpenCode state bridge. OpenCode has **no**
/// command-based hook file like Claude Code's `settings.json` or Cursor's
/// `hooks.json`; instead it auto-loads JS/TS **plugins** from
/// `~/.config/opencode/plugins/` (global) and `<project>/.opencode/plugins/`
/// (per-project). Upstream globs `{plugin,plugins}` (`plugin.ts@v1.18.4:21`),
/// so either spelling loads; Crow's writer uses `plugins/`.
///
/// **Two scopes, one plugin body (CROW-831):**
///
///  - **Per-project (primary).** `writeHookConfig` writes
///    `<worktree>/.opencode/plugins/crow-hooks.js` with the Crow **session
///    UUID baked in**, so each worktree emits `crow hook-event --session
///    <uuid> …`. Resolution is exact — no cwd matching — which closes the
///    shared-`cwd` collision two sessions rooted at (or resolving to) the same
///    path could otherwise hit. Every Crow-launched OpenCode session
///    (`.work`/`.job`/`.review`) flows through `AgentLaunch` →
///    `writeHookConfig`, so all of them get a session-scoped plugin.
///
///  - **Global (fallback).** `installGlobalConfig` still writes a single
///    `<configHome>/plugins/crow-hooks.js` with **no** session UUID; it
///    resolves the session by matching the worktree `cwd` against registered
///    worktree paths (the same mechanism Codex's global hooks use). This
///    covers a `opencode` a user starts *by hand* in a terminal Crow didn't
///    auto-launch. To avoid **double emission** — OpenCode dedups plugins by
///    file URL, so the global and per-project files are distinct and *both*
///    load — the global plugin self-suppresses (returns no hooks) whenever a
///    per-project `crow-hooks.js` exists in the cwd. So in a Crow worktree only
///    the session-scoped plugin ever fires.
///
/// Both variants subscribe to OpenCode's `event` bus plus the
/// `tool.execute.before/after` and `permission.ask` hooks and shell out (via
/// Bun's `$`) to `crow hook-event --agent opencode --event <PascalName>`,
/// piping a JSON payload (`{ cwd, … }`) on stdin — the shape the crow server's
/// `hook-event` RPC expects.
///
/// The plugin maps OpenCode's event/hook vocabulary onto Crow's canonical
/// PascalCase names so `OpenCodeSignalSource` can share Claude/Codex/Cursor's
/// vocabulary verbatim. The `event.type` strings below were verified against
/// the `@opencode-ai/sdk` `Event` union and the `Hooks` interface in
/// `@opencode-ai/plugin` (CROW-545 review):
///
///   session.created           → SessionStart     (event bus)
///   tool.execute.before       → PreToolUse        (hook)
///   tool.execute.after        → PostToolUse       (hook)
///   session.idle              → Stop              (event bus; "agent finished")
///   permission.ask            → PermissionRequest (hook — see below)
///   session.error             → Notification      (event bus)
///
/// Permission detection uses the **first-class `permission.ask` hook**, not a
/// bus `event.type`: the SDK `Event` union has no `permission.asked` literal
/// (only `permission.updated` / `permission.replied`), so keying off the bus
/// would silently no-op the "agent is blocked waiting on you" indicator. The
/// `permission.ask` hook fires exactly when OpenCode requests a decision; we
/// only observe it (never set `output.status`), so the user's/agent's choice
/// still stands.
public struct OpenCodeHookConfigWriter: HookConfigWriter {

    public init() {}

    // MARK: - HookConfigWriter Conformance (per-project plugin)

    /// Install `<worktreePath>/.opencode/plugins/crow-hooks.js` with
    /// `sessionID` baked in, so this worktree's OpenCode emits
    /// `crow hook-event --session <sessionID> …`. Idempotent — we own this
    /// single-purpose file and overwrite it wholesale, so there's nothing to
    /// merge. Called from the `AgentLaunch` path on every OpenCode launch.
    public func writeHookConfig(worktreePath: String, sessionID: UUID, crowPath: String) throws {
        let pluginsDir = Self.worktreePluginsDir(worktreePath)
        try FileManager.default.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)
        let pluginPath = (pluginsDir as NSString).appendingPathComponent(Self.pluginFileName)
        let content = Self.pluginSource(crowPath: crowPath, sessionID: sessionID)
        try content.write(to: URL(fileURLWithPath: pluginPath), atomically: true, encoding: .utf8)
    }

    /// Remove the per-project plugin from a worktree's `.opencode/plugins/`,
    /// leaving any user-authored plugins in that directory untouched. Best
    /// effort: also prunes the `plugins`/`.opencode` dirs when they're left
    /// empty (i.e. Crow created them), so tearing a session down leaves no
    /// trace, but never touches a directory that still holds other files.
    public func removeHookConfig(worktreePath: String) {
        let pluginsDir = Self.worktreePluginsDir(worktreePath)
        let pluginPath = (pluginsDir as NSString).appendingPathComponent(Self.pluginFileName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: pluginPath) else { return }
        try? fm.removeItem(atPath: pluginPath)
        Self.removeIfEmpty(pluginsDir)
        Self.removeIfEmpty((worktreePath as NSString).appendingPathComponent(".opencode"))
    }

    // MARK: - Global Configuration (fallback)

    /// Install or refresh `<configHome>/plugins/crow-hooks.js`. `configHome`
    /// is OpenCode's config dir (default `~/.config/opencode`, honoring
    /// `XDG_CONFIG_HOME`). Idempotent — we own this single-purpose file and
    /// overwrite it wholesale on every launch. The global plugin carries no
    /// session UUID and self-suppresses when a per-project plugin is present
    /// (see the type doc), so it only ever fires for hand-started sessions.
    public static func installGlobalConfig(configHome: String, crowPath: String) throws {
        let pluginsDir = globalPluginsDir(configHome)
        try FileManager.default.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)
        let pluginPath = (pluginsDir as NSString).appendingPathComponent(pluginFileName)
        let content = pluginSource(crowPath: crowPath, sessionID: nil)
        try content.write(to: URL(fileURLWithPath: pluginPath), atomically: true, encoding: .utf8)
    }

    // MARK: - Plugin Source

    static let pluginFileName = "crow-hooks.js"

    /// `<configHome>/plugins` — the global config home already ends at
    /// `…/opencode`, so no `.opencode` segment is added.
    private static func globalPluginsDir(_ configHome: String) -> String {
        (configHome as NSString).appendingPathComponent("plugins")
    }

    /// `<worktree>/.opencode/plugins` — per-project scope adds the `.opencode`
    /// segment OpenCode discovers project config/plugins under.
    private static func worktreePluginsDir(_ worktree: String) -> String {
        let opencodeDir = (worktree as NSString).appendingPathComponent(".opencode")
        return (opencodeDir as NSString).appendingPathComponent("plugins")
    }

    private static func removeIfEmpty(_ dir: String) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir), contents.isEmpty else { return }
        try? fm.removeItem(atPath: dir)
    }

    /// The JS plugin body, with `crowPath` baked in as a string literal
    /// (mirrors how Cursor bakes `crowPath` into its `hooks.json` commands).
    /// Written as plain `.js` so it needs no `@opencode-ai/plugin` types or a
    /// build step — OpenCode runs it directly on Bun.
    ///
    /// When `sessionID` is non-nil the emit carries `--session <uuid>` (exact
    /// resolution, per-project scope). When nil the emit omits it and the
    /// server resolves by cwd match (global fallback scope), and the plugin
    /// self-suppresses if a per-project plugin exists in the cwd.
    static func pluginSource(crowPath: String, sessionID: UUID? = nil) -> String {
        let crow = jsStringLiteral(crowPath)
        let session = jsStringLiteral(sessionID?.uuidString ?? "")
        let scopeNote = sessionID != nil
            ? "session-scoped (UUID baked in below)"
            : "global fallback (resolves by cwd; defers to a per-project plugin)"
        return """
        // Crow ↔ OpenCode hook bridge — auto-generated by Crow (safe to delete).
        // Scope: \(scopeNote).
        // Forwards OpenCode lifecycle events to the running Crow app so session
        // cards reflect agent state. Regenerated on every Crow launch.
        //
        // Each emit pipes a JSON payload ({ cwd, ... }) to `crow hook-event`.
        // With a session UUID we pass `--session <uuid>` so the crow server
        // resolves the session exactly; without one it matches `cwd` against
        // registered worktree paths.
        const CROW = \(crow);
        const SESSION = \(session);

        async function emit($, cwd, event, extra) {
          try {
            const payload = JSON.stringify(Object.assign({ cwd }, extra || {}));
            if (SESSION) {
              await $`echo ${payload} | ${CROW} hook-event --session ${SESSION} --agent opencode --event ${event}`.quiet();
            } else {
              await $`echo ${payload} | ${CROW} hook-event --agent opencode --event ${event}`.quiet();
            }
          } catch (_) {
            // Fire-and-forget: a hook failure (e.g. Crow not running) must
            // never disrupt OpenCode.
          }
        }

        export const CrowHooks = async ({ directory, worktree, $ }) => {
          // Prefer the git worktree path — that's what Crow registers and
          // matches on. Fall back to the process cwd.
          const cwd = worktree || directory;
          // Global fallback only: if this worktree has a session-scoped Crow
          // plugin, defer to it. OpenCode loads both (they are distinct file
          // URLs), so without this guard the same event would emit twice.
          if (!SESSION) {
            try {
              if (await Bun.file(cwd + "/.opencode/plugins/crow-hooks.js").exists()) {
                return {};
              }
            } catch (_) {
              // Bun.file unavailable / unreadable — fall through and emit.
            }
          }
          return {
            event: async ({ event }) => {
              switch (event.type) {
                case "session.created":
                  await emit($, cwd, "SessionStart", { source: "startup" });
                  break;
                case "session.idle":
                  // OpenCode has finished the turn and is waiting on the user.
                  await emit($, cwd, "Stop");
                  break;
                case "session.error":
                  await emit($, cwd, "Notification", { message: "Session error" });
                  break;
              }
            },
            "permission.ask": async (_input, _output) => {
              // First-class permission hook — the SDK Event union has no
              // matching bus type, so keying off `event.type` would silently
              // no-op. This fires when OpenCode asks for a decision (agent is
              // now blocked). Observe only: we never set `_output.status`, so
              // the user's/agent's choice stands.
              await emit($, cwd, "PermissionRequest");
            },
            "tool.execute.before": async (input) => {
              await emit($, cwd, "PreToolUse", { tool_name: (input && input.tool) || "unknown" });
            },
            "tool.execute.after": async (input) => {
              await emit($, cwd, "PostToolUse", { tool_name: (input && input.tool) || "unknown" });
            },
          };
        };

        """
    }

    /// Escape a path for embedding inside a JS double-quoted string literal.
    /// Paths won't normally contain quotes/backslashes, but escape defensively.
    private static func jsStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
