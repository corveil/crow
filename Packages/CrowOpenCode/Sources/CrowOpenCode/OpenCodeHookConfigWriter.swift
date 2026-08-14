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
///   session.created           → SessionStart      (event bus)
///   tool.execute.before       → PreToolUse        (hook)
///   tool.execute.after        → PostToolUse       (hook)
///   session.status {idle}     → Stop              (event bus; "agent finished")
///   session.status {busy}     → UserPromptSubmit  (event bus; "turn started")
///   session.status {retry}    → (none — still busy; see below)
///   session.idle              → Stop              (deprecated fallback only)
///   permission.ask            → PermissionRequest (hook — see below)
///   session.error             → Notification      (event bus)
///
/// **`session.status`, not `session.idle` (CROW-1000).** Upstream deprecated
/// `session.idle` in favor of `session.status`, whose payload is
/// `{ sessionID, status: { type: "idle" | "busy" | "retry" } }`
/// (`packages/schema/src/session-status-event.ts` — `Idle` is literally marked
/// `// deprecated`). Two properties of the upstream publisher
/// (`packages/opencode/src/session/status.ts`) drive the plugin's shape, both
/// confirmed empirically against **opencode 1.18.5** (headless `opencode run`;
/// the events come off the same server bus the TUI uses, but the *interactive
/// TUI* pass is still the human re-check in CROW-1000):
///
///  1. **Both events fire, status first.** `SessionStatus.set` publishes
///     `session.status` and then, only when the type is `idle`, `session.idle`
///     — 246 µs apart in the probe. So a plugin that handles both naively emits
///     `Stop` twice per turn. The plugin therefore latches: once *any*
///     `session.status` arrives, this build speaks the modern event and the
///     deprecated `session.idle` is ignored. Older builds that never emit
///     `session.status` keep the `session.idle` path, so one plugin body works
///     across both eras with no version probe.
///  2. **`session.status` is published on every set, not only on changes** —
///     the probe recorded three consecutive `busy` events in a single turn. The
///     plugin tracks the last status per `sessionID` and acts only on
///     transitions, so one turn costs one `UserPromptSubmit` and one `Stop`
///     rather than a subprocess per internal status write.
///
/// `busy` earns its own mapping: it is the "turn started" edge OpenCode
/// otherwise never gave us. Before this, a session left `.done` only when its
/// first tool ran, so a turn that answered without calling a tool (or thought
/// for a while first) showed a stale `.done` card. `retry` is a *busy*
/// sub-state (a provider retry mid-turn), so it is normalized to `busy` for
/// transition bookkeeping and never mapped to `Stop` — treating it as "done"
/// would park the card on a turn that is still running.
///
/// **Known gap (pre-existing, not CROW-1000).** OpenCode's bus is per-*server*
/// and `session.status` carries no parent link, so a **subagent's** child
/// session is mapped onto this plugin's one Crow session UUID: the child going
/// idle emits a `Stop` while the parent is still working (measured 1.9 s early
/// on 1.18.5). The deprecated `session.idle` behaved identically, so nothing
/// here regresses it; closing it means correlating `session.created`'s
/// `info.parentID` and ignoring non-root sessions. See
/// `docs/agent-harness-matrix.md` → Hook async delivery.
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
        // The plugin embeds the absolute `crow` path and the session UUID and
        // lives inside the user's git worktree, where an agent's `git add -A`
        // could stage it. A self-scoped `.gitignore` keeps our generated files
        // out of the index without touching OpenCode's own `.opencode/.gitignore`
        // (a level up, which upstream manages).
        Self.writeGitignore(inDir: pluginsDir)
    }

    /// Remove the per-project plugin from a worktree's `.opencode/plugins/`,
    /// leaving any user-authored files (plugins *and* a hand-written
    /// `.gitignore`) untouched. Best effort: removes our own `.gitignore` when
    /// it still carries exactly our content, and prunes the `plugins`/`.opencode`
    /// dirs when they're left empty (i.e. Crow created them), so tearing a
    /// session down leaves no trace — but never touches a file or directory that
    /// isn't ours.
    public func removeHookConfig(worktreePath: String) {
        let pluginsDir = Self.worktreePluginsDir(worktreePath)
        let pluginPath = (pluginsDir as NSString).appendingPathComponent(Self.pluginFileName)
        let fm = FileManager.default
        // Remove the plugin if it's still there — but don't early-return when it
        // isn't: a user who took the "safe to delete" header at its word and
        // removed `crow-hooks.js` by hand must not be left with an orphaned,
        // self-ignoring `.gitignore` that `git status` can't even surface.
        try? fm.removeItem(atPath: pluginPath)
        // Drop our `.gitignore` only if it still holds exactly our content — a
        // user may have replaced it with their own rules (same provenance
        // discipline as writeGitignore).
        let gitignorePath = (pluginsDir as NSString).appendingPathComponent(".gitignore")
        if (try? String(contentsOfFile: gitignorePath, encoding: .utf8)) == Self.gitignoreBody {
            try? fm.removeItem(atPath: gitignorePath)
        }
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

    /// The exact body Crow writes to `.opencode/plugins/.gitignore`. A single
    /// source of truth so `writeGitignore` and `removeHookConfig` agree on what
    /// "ours" means when deciding whether it's safe to write/delete.
    static let gitignoreBody = """
    # Crow-generated — safe to delete.
    \(pluginFileName)
    .gitignore
    """

    /// Write a self-scoped `.gitignore` into `dir` that ignores Crow's generated
    /// plugin (and the `.gitignore` itself), so an agent's `git add -A` in the
    /// worktree never stages them. `.opencode/plugins/` is the *user's*
    /// directory (their own plugins live there), so this never clobbers a
    /// pre-existing `.gitignore` — it writes only into an empty slot or over our
    /// own previous body. Idempotent; best effort.
    private static func writeGitignore(inDir dir: String) {
        let path = (dir as NSString).appendingPathComponent(".gitignore")
        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           existing != gitignoreBody {
            // A `.gitignore` we didn't write (user's own rules) — leave it.
            return
        }
        try? gitignoreBody.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
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

        // Does this OpenCode build speak `session.status`? Upstream publishes
        // BOTH `session.status {idle}` and the deprecated `session.idle` on the
        // same turn end (status first, ~246µs earlier on 1.18.5), so handling
        // both unconditionally would emit Stop twice. Latch on the first
        // `session.status` we see and ignore `session.idle` from then on; a
        // build old enough to never emit `session.status` keeps the fallback.
        let sawSessionStatus = false;

        // Last status type per sessionID. `session.status` is published on
        // every internal status write, not only on changes (three consecutive
        // `busy` events in one observed turn), so we act on transitions only.
        // Absent means idle — matching upstream, which deletes the entry when a
        // session goes idle.
        const lastStatus = new Map();

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
                case "session.status": {
                  // Canonical idle/busy signal (`session.idle` is deprecated).
                  sawSessionStatus = true;
                  const props = event.properties || {};
                  const id = props.sessionID || "";
                  const raw = (props.status && props.status.type) || "";
                  // `retry` is a busy sub-state (provider retry mid-turn), NOT a
                  // finished turn — fold it into `busy` so a busy→retry→busy
                  // round trip stays one working stretch and never reads as done.
                  const state = raw === "retry" ? "busy" : raw;
                  // Absent = idle, so the first `busy` of a turn is a transition.
                  const prev = lastStatus.get(id) || "idle";
                  if (prev === state) break;
                  if (state === "idle") {
                    lastStatus.delete(id);
                    // OpenCode has finished the turn and is waiting on the user.
                    await emit($, cwd, "Stop");
                  } else {
                    lastStatus.set(id, state);
                    if (state === "busy") {
                      // Turn started — the only "agent began working" edge
                      // OpenCode gives us. Without it a session stays `.done`
                      // until its first tool call. An unrecognized future state
                      // is recorded but emits nothing.
                      await emit($, cwd, "UserPromptSubmit");
                    }
                  }
                  break;
                }
                case "session.idle":
                  // Deprecated upstream, and emitted alongside
                  // `session.status {idle}` on builds that have it — so only
                  // act on it when this build never spoke `session.status`.
                  if (!sawSessionStatus) await emit($, cwd, "Stop");
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
              // Ordering (#903): permission.ask fires BEFORE tool.execute.before,
              // so PermissionRequest is emitted ahead of PreToolUse. Under the
              // fire-and-forget apply-order caveat (docs/agent-harness-matrix.md)
              // that means an inversion lands on the correct final state and
              // self-heals — OpenCode is not exposed to the non-self-healing
              // permission-badge case Claude is.
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
