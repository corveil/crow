import Foundation
import CrowClaude
import CrowCore
import CrowCursor

// MARK: - Review-clone strips (CROW-1302)
//
// The hostile-head security boundary, split out of `ReviewSessionController`.
// Predicates (`shouldStrip*` / `shouldRefuseReviewHandoff`), the per-agent
// `strip*ConfigFromReviewClone` wipes, the Grok-handoff compat-hook prune, and
// `removeReviewCloneConfig`. Creation-time calls stay inside `prepareReviewClone`;
// launch-path re-strips stay in `prepareWorktreeForAgentLaunch`. Codex's
// `.codex` removal stays a `try? FileManager.removeItem` in the clone prep and
// does not go through `removeReviewCloneConfig`.
extension ReviewSessionController {
    /// Whether Cursor is about to open a `.review` clone and must therefore strip
    /// its committed `.cursor/` first — the launch-path gate, as opposed to the
    /// creation-time (`prepareReviewClone`) arm.
    ///
    /// This subsumes the former `shouldStripCursorReviewCloneOnHandoff`, retired in
    /// the CROW-954 review (Green 1): `handoffAgent` routes through
    /// `prepareWorktreeForAgentLaunch` with the *target* kind, so the handoff case
    /// — flipping a review created under another agent onto Cursor, in a clone
    /// `prepareReviewClone` never stripped for Cursor (#829 review round 10, Red 1)
    /// — is covered here, leaving one strip path per agent as with Antigravity.
    ///
    /// Added with CROW-954, which made Cursor seed `--trust` on `.review`. Before
    /// that, a review clone launched untrusted and Cursor's folder-trust dialog
    /// stood between a restored `.cursor/hooks.json` and execution, so stripping at
    /// creation was enough. Now the clone launches pre-trusted, so the strip is the
    /// **only** thing between a hostile committed hook and the reviewer's machine —
    /// exactly the position Antigravity is in (`shouldStripAntigravityReviewClone`,
    /// #902 review Red), and for the same reason it must re-fire on every launch,
    /// not just at creation: the review skill's `gh pr checkout` (or a
    /// head-advancing re-review) restores the attacker's `.cursor/` from the PR
    /// head, and a warm `crowd` restart or `crow send` reopens the clone through
    /// neither the creation nor the handoff arm.
    nonisolated static func shouldStripCursorReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        agentKind == .cursor && sessionKind == .review
    }

    /// Gate for refusing a review-session handoff (and `crow agents set
    /// --review <kind>`) to an agent that can't perform reviews. **No agent is
    /// review-incapable today** — Antigravity was the last one and its review
    /// dispatch landed in #902 (`autoLaunchCommand(.review)` inlines the SKILL
    /// body; `prepareReviewClone` **and every launch path**
    /// (`prepareWorktreeForAgentLaunch`) strip its `.agents/`, not just at
    /// creation — a warm `crowd` restart / `crow send "agy -c"` reopens the clone
    /// through neither creation nor a handoff arm). The predicate is retained as
    /// the single coupling point both surfaces share (`handoffAgent` and
    /// `AgentsRPCSupport.validateRoleSupportsAgent`) so a future review-incapable
    /// harness can be gated in one place without the two drifting. Extracted as a
    /// pure predicate so the gate stays unit-testable without the full
    /// `handoffAgent` machinery (mirrors `shouldStripCursorReviewClone`).
    nonisolated static func shouldRefuseReviewHandoff(
        targetKind: AgentKind, sessionKind: SessionKind) -> Bool {
        // Intentionally always `false`: every registered harness now supports
        // review. Add a `targetKind == X && sessionKind == .review` clause here
        // if a future agent ships without review dispatch.
        false
    }

    /// Whether Antigravity is about to open a `.review` clone and must therefore
    /// strip its committed `.agents/` first. This is only the pure *predicate*;
    /// the anti-drift guarantee comes from routing — every launch path calls
    /// `prepareWorktreeForAgentLaunch` (grep its call sites), and creation-time
    /// `prepareReviewClone` strips directly — not from any enumeration here (#902
    /// review, Red; mirrors `shouldStripGrokReviewClone`). Only a `.review`
    /// session on Antigravity strips: `.work`/`.job` branch off a trusted base,
    /// and a `.review` on any other agent must not strip a surface that agent
    /// doesn't load. Antigravity has no trust gate (`agy` runs `.agents/hooks.json`
    /// unapproved and seeds no folder trust), so unlike Cursor — whose bespoke
    /// handoff strip is defense-in-depth behind its `.review` trust carve-out —
    /// the strip is Antigravity's *only* defense and must re-fire on every launch,
    /// which is why this routes through the shared gate rather than a handoff arm.
    nonisolated static func shouldStripAntigravityReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        agentKind == .antigravity && sessionKind == .review
    }

    /// Whether Muse is about to open a `.review` clone and must therefore strip
    /// its committed config layers first. Only a `.review` session on Muse
    /// strips: `.work`/`.job` branch off a trusted base, and a `.review` on any
    /// other agent must not strip a surface that agent doesn't load. Muse
    /// withholds `--trust-workspace` from review (so project hooks/skills/rules
    /// do not load) but **project memory under `.agents/memory/` is injected
    /// even in an untrusted workspace** (official configuration docs,
    /// 2026-08-14), so the strip is load-bearing for that layer and must
    /// re-fire on every launch via `prepareWorktreeForAgentLaunch`.
    nonisolated static func shouldStripMuseReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        agentKind == .muse && sessionKind == .review
    }

    /// Neutralize a review clone's committed Muse config layers. A hostile PR
    /// head can commit:
    ///  - `.muse/hooks.json` — project hooks that `--trust-workspace` (or a
    ///    later `muse hooks trust`) would run outside the sandbox.
    ///  - `.agents/` — project skills (`<repo>/.agents/skills/`) plus
    ///    **project memory** (`<repo>/.agents/memory/`), which Muse injects
    ///    even in an untrusted workspace. Prompt injection, and the one
    ///    layer withholding `--trust-workspace` does not cover.
    /// Crow's user-scope Jira bridge writes `~/.config/muse/settings.json`
    /// (`MuseMCPConfigWriter`, CROW-1209), not a project MCP file — official
    /// Muse docs put `mcp_servers` only in that user settings file. This strip
    /// stays `.muse/` + `.agents/` (no extra project MCP path to remove).
    /// Working-tree removal only (the git index entry survives). Shared by
    /// `prepareReviewClone` and `prepareWorktreeForAgentLaunch`. Idempotent;
    /// each layer no-ops when absent. A genuine removal failure is audible.
    nonisolated static func stripMuseConfigFromReviewClone(clonePath: String) {
        let base = clonePath as NSString
        removeReviewCloneConfig(
            base.appendingPathComponent(".muse"),
            label: ".muse/", clonePath: clonePath)
        removeReviewCloneConfig(
            base.appendingPathComponent(".agents"),
            label: ".agents/", clonePath: clonePath)
    }

    /// Neutralize a review clone's committed Antigravity config layers by removing
    /// the working-tree config dirs `agy` may discover. A hostile PR head can
    /// commit `.agents/hooks.json` with arbitrary command hooks that `agy` runs
    /// with no approval gate, so once Antigravity loads the clone as its project
    /// root the hooks fire unsandboxed on the reviewer's machine. Because this is
    /// Antigravity's **only** defense (no trust gate behind it), it strips the
    /// whole plausibly-discovered surface rather than the native dir alone —
    /// mirroring `stripGrokConfigFromReviewClone`, which strips `.grok/` **plus**
    /// `.cursor/`/`.claude/`/`.mcp.json` for the same reason (#861 r12, Red):
    ///  - `.agents/` — Antigravity's native project hooks, plus workspace-local
    ///    `.agents/mcp_config.json` (attacker-controlled MCP). Crow's user-scope
    ///    Jira bridge writes `~/.gemini/config/mcp_config.json`
    ///    (`AntigravityMCPConfigWriter`, CROW-1207), not this project file.
    ///  - `.gemini/` — `agy` is Gemini-derived (`GEMINI_CONFIG_HOME`, default
    ///    `~/.gemini/config`, `LaunchScaffold`), so a project-scope
    ///    `.gemini/settings.json` can carry `mcpServers` (a `{command,args}` server
    ///    spawned at startup) or an `always-proceed` approval mode that would
    ///    disarm the gate the review otherwise leans on. Stripped **defensively**
    ///    (#902 review r7, Red): removing a path `agy` turns out not to read
    ///    costs nothing on a throwaway review clone, and a miss here is
    ///    unsandboxed RCE with no second layer. User-scope MCP is a different
    ///    surface from this attacker-controlled project layer.
    /// Working-tree removal only (the git index entry survives), same as
    /// `stripCursorConfigFromReviewClone` — so a *committed* `.agents/hooks.json`
    /// still trips `AntigravityHookConfigWriter`'s git-tracked guard and Crow's
    /// own state-detection hooks aren't written for that clone; that is expected,
    /// not a regression. Shared by `prepareReviewClone` (creation-time) and
    /// `prepareWorktreeForAgentLaunch` (every launch path — where the review
    /// skill's `gh pr checkout` may have restored a committed layer from the head)
    /// so the gate can't drift. Idempotent; each layer no-ops when absent.
    /// Delegates to `removeReviewCloneConfig` so a genuine removal failure is
    /// **audible** (`CrowLog.error`, not `info`): the strip is Antigravity's only
    /// defense, so a swallowed failure would leave live attacker config in place
    /// with nothing to show for it (#902 review r3, Yellow 1).
    nonisolated static func stripAntigravityConfigFromReviewClone(clonePath: String) {
        let base = clonePath as NSString
        removeReviewCloneConfig(
            base.appendingPathComponent(".agents"),
            label: ".agents/", clonePath: clonePath)
        removeReviewCloneConfig(
            base.appendingPathComponent(".gemini"),
            label: ".gemini/", clonePath: clonePath)
    }

    /// Neutralize a review clone's committed Cursor config layer by removing the
    /// working-tree `.cursor/` directory. A hostile PR head can commit
    /// `.cursor/hooks.json` (arbitrary `beforeShellExecution` commands, with no
    /// approval gate at all) or `.cursor/mcp.json` (a project-scope
    /// `{command,args,env}` MCP server that this PR's `--approve-mcps` would
    /// auto-trust), either of which would run unsandboxed on the reviewer's
    /// machine once Cursor loads the clone as its project root. Stripping the
    /// whole directory removes both surfaces.
    ///
    /// Shared rather than inlined so the gate can't drift (#829 review round 10):
    /// `prepareReviewClone` strips at creation time,
    /// `prepareWorktreeForAgentLaunch` on every launch path (via
    /// `shouldStripCursorReviewClone` — CROW-954), and
    /// `stripGrokConfigFromReviewClone` reuses it for the `.cursor/` layer Grok
    /// also discovers. `rg stripCursorConfigFromReviewClone` is the authority on
    /// that set — never a hand-maintained count here, which is what went stale
    /// four rounds running on the sibling helpers. Working-tree removal only: the
    /// git index entry survives (`removeItem` doesn't stage a deletion), so
    /// `CursorHookConfigWriter.writeHookConfig` still correctly declines to
    /// overwrite a *committed* hooks file and the review runs without Crow's
    /// hook-based state signals — a bounded, pre-existing limitation for repos
    /// that commit their own `.cursor/`, independent of this security strip.
    /// Idempotent; no-ops when the clone ships no `.cursor/`.
    ///
    /// Delegates to `removeReviewCloneConfig` so a genuine removal failure is
    /// **audible** (`CrowLog.error`, not `info`). That matters as of CROW-954:
    /// Cursor review clones now launch pre-trusted (`--trust`) with `--force
    /// --approve-mcps`, so this strip is the *only* thing standing between a
    /// committed `.cursor/hooks.json` and unsandboxed execution. A swallowed
    /// failure would leave live attacker config in place with nothing to show for
    /// it — the same rationale already spelled out on
    /// `stripAntigravityConfigFromReviewClone` (#902 review r3, Yellow 1), which
    /// this now matches. Before CROW-954 an `info` line was tolerable because
    /// Cursor's folder-trust dialog stood behind the strip; this PR removed that
    /// backstop (CROW-954 review, Yellow 1).
    nonisolated static func stripCursorConfigFromReviewClone(clonePath: String) {
        removeReviewCloneConfig(
            (clonePath as NSString).appendingPathComponent(".cursor"),
            label: ".cursor/", clonePath: clonePath)
    }

    /// Whether Grok is about to open a `.review` clone and must therefore strip
    /// its committed config layers first. This is only the pure *predicate*; the
    /// anti-drift guarantee comes from routing — every launch path calls
    /// `prepareWorktreeForAgentLaunch` (grep its call sites), and creation-time
    /// `prepareReviewClone` strips directly — not from any enumeration here (#861
    /// review, Red; mirrors `shouldStripCursorReviewClone`). Only a
    /// `.review` session on Grok strips: `.work`/`.job` branch off a trusted base,
    /// and a `.review` on any other agent must not strip a surface that agent
    /// doesn't load.
    nonisolated static func shouldStripGrokReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        agentKind == .grok && sessionKind == .review
    }

    /// Neutralize a review clone's committed config layers that **Grok
    /// discovers and merges** — not just `.grok/`. With `compat.*.hooks = true`
    /// (on by default), Grok loads project hooks from `.grok/hooks/*.json`,
    /// `.claude/settings.json` **and** `.claude/settings.local.json`, and
    /// `.cursor/hooks.json`; and it loads project MCP servers from
    /// `.cursor/mcp.json`, `.grok/config.toml [mcp_servers]`, **and repo-root
    /// `.mcp.json`** (verified against `xai-org/grok-build`: `10-hooks.md`,
    /// `07-mcp-servers.md`, and `xai-grok-workspace/src/{folder_trust,servers}.rs`,
    /// where `.mcp.json` is scanned from repo root down to cwd). On an
    /// attacker-controlled review-clone head every one is arbitrary-command RCE
    /// once the folder is trusted — and on a local/dev Grok build folder-trust is
    /// inert (everything trusted), or on a release build trust cascades from a
    /// trusted parent — so the strip is the durable defense (#861 review rounds
    /// 2-3, Red).
    ///
    /// So this neutralizes the whole discovered surface:
    /// - `.grok/` — Grok's native project hooks, plus `.grok/config.toml`
    ///   `[mcp_servers]` and `.grok/lsp.json` (all removed by the dir wipe).
    /// - `.cursor/` — `hooks.json` + `mcp.json` Grok loads via Cursor compat.
    ///   Reuses `stripCursorConfigFromReviewClone` so both agents share one
    ///   primitive.
    /// - `.claude/settings.local.json` **and** `.claude/settings.json` — both
    ///   loaded via Claude compat (their `hooks` + `env` spawn subprocesses).
    ///   Removing `settings.json` here is safe at creation: this strip runs
    ///   *before* `prepareReviewClone` rewrites it with bundled-safe content
    ///   (`Scaffolder.bundledSettings()`), so the clone still ends Crow-owned. On
    ///   the re-strip paths (`launchAgent`/handoff) it removes a hostile
    ///   `settings.json` that `git restore`/`gh pr checkout` brought back — which
    ///   the one-shot creation overwrite can't reach (#861 review r12, Red).
    ///   `.claude/skills/` is untouched (the Grok review inlines the skill into
    ///   its prompt, so it isn't read as a file).
    /// - `.mcp.json` (repo root) — a project MCP source independent of
    ///   `.cursor/mcp.json`; a `{mcpServers:{…command}}` there auto-spawns.
    ///
    /// Idempotent; no-ops for any layer the clone doesn't ship. Two kinds of
    /// caller: creation-time `prepareReviewClone` (strip only — the clone isn't a
    /// launch target yet), and every *launch* path via the shared
    /// `prepareWorktreeForAgentLaunch` gate (grep its call sites) — so no path can
    /// open Grok in a review clone without stripping first. A real removal failure
    /// is audible (`CrowLog.error`).
    nonisolated static func stripGrokConfigFromReviewClone(clonePath: String) {
        let base = clonePath as NSString
        removeReviewCloneConfig(
            base.appendingPathComponent(".grok"), label: ".grok/", clonePath: clonePath)
        // .cursor/ (hooks.json + mcp.json) — same primitive Cursor reviews use.
        stripCursorConfigFromReviewClone(clonePath: clonePath)
        // `.claude/settings.local.json` + `.claude/settings.json` — both loaded
        // via Claude compat. See the doc above for why removing `settings.json`
        // is safe at creation (strip precedes the bundled rewrite) yet essential
        // on the re-strip paths (a restored hostile one, #861 review r12, Red).
        removeReviewCloneConfig(
            base.appendingPathComponent(".claude/settings.local.json"),
            label: ".claude/settings.local.json", clonePath: clonePath)
        removeReviewCloneConfig(
            base.appendingPathComponent(".claude/settings.json"),
            label: ".claude/settings.json", clonePath: clonePath)
        // Repo-root `.mcp.json` — a project MCP source Grok loads independently
        // of `.cursor/mcp.json`. For a review clone cwd == clone root, so the
        // repo-root file is the only one in Grok's root→cwd scan chain.
        removeReviewCloneConfig(
            base.appendingPathComponent(".mcp.json"),
            label: ".mcp.json", clonePath: clonePath)
    }

    /// Strip the PRIOR agent's Crow-managed hook config from the two project
    /// compat sources Grok also loads — `.claude/settings.local.json` (Claude)
    /// and `.cursor/hooks.json` (Cursor) — on a `.work`/`.job` handoff to Grok.
    ///
    /// Distinct from `stripGrokConfigFromReviewClone` in both scope and method:
    /// that wholesale-wipes attacker config *files* off a hostile *review* clone;
    /// this runs on a *trusted* work worktree and calls each writer's
    /// `removeHookConfig`, which touches only the hook config — never the file's
    /// other settings (Claude's `permissions` block, the gateway `env`, Cursor's
    /// non-hook keys) nor a user's own `.grok/hooks/*.json`.
    ///
    /// ⚠️ The two writers differ in granularity, and the Claude arm is **not**
    /// marker-scoped: `CursorHookConfigWriter.removeHookConfig` prunes only Crow's
    /// own groups (a user's hooks under the same event name survive), but
    /// `ClaudeHookConfigWriter.removeHookConfig` drops each managed event key
    /// *wholesale* — so a user's hand-authored `Stop`/`PreToolUse`/… hook in the
    /// worktree's `.claude/settings.local.json` is removed with it (the same caveat
    /// spelled out at `writeManagerHookConfig`). An accepted trade for closing the
    /// double-fire: hand-authored hooks in a per-session `.work` worktree are rare,
    /// and leaving the double-fire is worse.
    ///
    /// Why it's needed: nothing else on the worker path removes a prior agent's
    /// hooks — `launchAgent` / the deferred-paste only *write* the incoming
    /// agent's, and the cross-agent loop in `writeManagerHookConfig` is
    /// Manager-only. So a Claude→Grok (or Cursor→Grok) handoff leaves the prior
    /// `.claude/settings.local.json` / `.cursor/hooks.json` — same session UUID,
    /// same PascalCase event names Grok registers — on disk, and Grok (compat on
    /// by default) loads BOTH it and its own `.grok/hooks/crow.json`. Every hook
    /// event then fires twice: doubled `taskComplete`/`agentWaiting` notifications
    /// and a doubled `crow hook-event` subprocess for the session's life, because
    /// `EngineRouter.presentHookNotification` is per-event, not state-gated
    /// (#861 review r8).
    ///
    /// Idempotent and no-op when the file/keys are absent, so it's called
    /// unconditionally (prior Codex/OpenCode → nothing to strip) and never
    /// touches the incoming `.grok/hooks/crow.json` (a separate file, written
    /// later on the deferred paste).
    nonisolated static func stripPriorCompatHooksForGrokHandoff(worktreePath: String) {
        ClaudeHookConfigWriter().removeHookConfig(worktreePath: worktreePath)
        CursorHookConfigWriter().removeHookConfig(worktreePath: worktreePath)
    }

    /// Remove one review-clone config path, quiet when it isn't present (the
    /// common case) but **audible** on a real removal failure — a swallowed
    /// error would leave an attacker-controlled config layer in place. Shared by
    /// **all three** review-clone strips — Grok's several layers, Antigravity's
    /// `.agents/`+`.gemini/`, and Cursor's `.cursor/` (CROW-954) — so every strip
    /// reports a failure at one log level. Internal (not `private`) so
    /// `prepareReviewClone` in `ReviewSessionController+Clone` can call it
    /// — Swift `private` is file-scoped (CROW-1302).
    internal nonisolated static func removeReviewCloneConfig(
        _ path: String, label: String, clonePath: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // Not shipped — the common, expected case. Stay quiet.
        } catch {
            CrowLog.error("[SessionService] Failed to strip \(label) from review clone \(clonePath): \(error.localizedDescription)")
        }
    }
}
