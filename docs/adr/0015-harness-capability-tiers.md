# 0015 — Harness capability tiers & phased parity

- **Status:** Accepted
- **Date:** 2026-07-23
- **Deciders:** @dgershman

## Context

[ADR 0014](./0014-pluggable-coding-agent-adapter.md) established the
`CodingAgent` adapter and registered four harnesses: Claude Code, Cursor, OpenAI
Codex, OpenCode. They are **not at parity** — Claude Code is the reference
implementation with every capability wired; the other three ship with
deliberate, documented gaps (full grid in the
[capability matrix](../agent-harness-matrix.md)).

> **Amendment (2026-07-26, #860):** a fifth harness — **Antigravity** (Google's
> `agy` CLI) — joined as an explicit **Tier-2 / experimental** target: a real,
> driveable CLI that lands below the self-hostable harnesses and ships with
> honest, documented gaps (closed-source + Google-auth-locked ⇒ a *permanent*
> self-host ❌, hooks-only state detection, no review [closed #902 — see below],
> no MCP bridge, a supply-chain gate on its binary provenance). It is the first
> harness added under the tiering this ADR defines; its gaps live in the same
> [capability matrix](../agent-harness-matrix.md) column and are governed by the
> Tier-2 rationale below.

> **Amendment (2026-07-28, #890):** Cursor's `--trust` — omitted by the original
> gap audit as headless-only (§3a) under the "honest gap over faked capability"
> principle in **Alternatives considered** below — **went interactive in Cursor
> CLI 2026.07.20** ([changelog](https://cursor.com/docs/cli/changelog)), confirmed
> against `agent 2026.07.23` (its `--help` lists `--trust` as a general flag with
> no headless-only qualifier and no `--print` gating). So it is now wired as a
> bounded, per-launch **workspace-trust seed** (`CursorLaunchArgs.trustSuffix`,
> the analogue of `ClaudeTrustSeeder`), applied on auto-launch, the Manager, and
> the handoff one-shot — closing the "fresh worktree may prompt" residual. This
> does **not** relax the honesty principle: the flag is real and verified, so
> emitting it is honest rather than a papered-over gap, and it stays bounded to
> workspace trust — **not** `--yolo`/full-bypass, with auto-permission still
> supplied separately by `--force --approve-mcps`. "Bounded" also means *scoped*:
> workspace trust is the gate that governs whether repo-supplied agent config
> (`.cursor/rules`, MCP entries, repo instructions) is honored, so the seed is
> **withheld from `.review` sessions** — their working tree is an
> attacker-controlled `gh` clone at the PR author's head. This mirrors the
> `session.kind != .review` guard already on `CodexTrustSeeder` and is a
> deliberate **divergence from `ClaudeTrustSeeder`**, which is ungated on kind
> (`SessionService.launchAgent`): Cursor follows the Codex precedent, so review
> clones are not auto-trusted by Crow — the intent is they fall back to Cursor's
> folder-trust dialog rather than launching pre-trusted, though whether `--force`
> (review's default auto-permission) still surfaces that dialog is unverified;
> withholding `--trust` is never worse than emitting it (CROW-890 review, Red 1).
> **[Superseded by the 2026-08-10 amendment below — the `.review` carve-out is
> removed.]** Requires **Cursor CLI ≥
> 2026.07.20**; the seed is emitted on every non-`.review` path, so an older
> binary is out of support. Probed 2026.07.23 that the arg parser silently
> ignores a mode-gated flag used outside its mode (`agent --output-format json
> --version` exits 0, no error), so a pre-floor build recognizing `--trust`
> would no-op it and degrade to the old prompt rather than reject the launch.

> **Amendment (2026-08-10, CROW-954):** the `.review` carve-out in the #890
> amendment above is **removed** — Cursor now seeds `--trust` on every session
> kind, review included. The carve-out rested on one load-bearing claim, that a
> review clone would "fall back to Cursor's folder-trust dialog" as a *human gate*.
> Both halves of that failed in practice:
>
> 1. **The dialog gated nothing.** Review launches already carry `--force
>    --approve-mcps` (`reviewAutoPermissionMode` ships on), so the reviewer's only
>    meaningful choice at the prompt is to trust — after which every tool call runs
>    unapproved. It was a keypress, not a decision.
> 2. **`--force` does not suppress it** — the exact question the #890 amendment
>    left "unverified". Observed on `agent 2026.08.04`: a Crow review session
>    launched with `--force --approve-mcps` stops on "Workspace Trust Required" and
>    waits. So the carve-out's cost was not theoretical — it broke the unattended
>    dispatch that makes review sessions useful, which is precisely the failure the
>    trust seed exists to prevent.
>
> The security property the carve-out was reaching for is preserved, and moved to
> where it actually holds: `SessionService.stripCursorConfigFromReviewClone` removes
> the clone's committed `.cursor/` (`hooks.json`, `mcp.json`) and is now promoted
> from a creation-time + handoff strip to run on **every** launch path via
> `prepareWorktreeForAgentLaunch` (`shouldStripCursorReviewClone`). That promotion
> is load-bearing, not cosmetic: with no dialog behind it, the strip must re-fire
> after the review skill's `gh pr checkout` (or a head-advancing re-review) restores
> the attacker's config, and a warm `crowd` restart or `crow send` reopens the clone
> through neither the creation nor the handoff arm. This is the same
> **strip-not-trust** posture Grok (#861) and Antigravity (#902) reviews already
> rely on, and it re-converges Cursor with `ClaudeTrustSeeder`, which has always
> trusted `.review` (`shouldSeedFolderTrust` returns `true` for Claude on every
> kind) — so the #890 "divergence from Claude, follow the Codex precedent" framing
> is retired for Cursor. **Codex and Grok keep their `!= .review` guards**: they
> write durable global trust records (`~/.codex/config.toml`,
> `~/.grok/trusted_folders.toml`) that outlive the session, a materially larger
> blast radius than Cursor's per-workspace marker under `~/.cursor/projects/`, and
> nothing about this change argues for touching them.
>
> Verified interactively (not just from `--help`) on `agent 2026.08.04`: running
> `agent --trust` under a pty in a fresh repo, with no `--print`, writes
> `~/.cursor/projects/<slug>/.workspace-trusted` containing `"trustMethod":
> "cli-flag"` — the same saved decision the dialog records on accept.

> **Amendment (2026-07-28, #902):** Antigravity's **review** gap — recorded as a
> Tier-2 deferral (its `autoLaunchCommand(.review)` returned `nil`, so a review
> session assigned to it never launched) — **closes**. Review now dispatches the
> **inlined `crow-review-pr` SKILL body** via `agy -p "$(cat …-review-prompt.md)"`,
> exactly the path Cursor/Codex/OpenCode already take (Antigravity has no Crow
> slash-command engine, so the terse `/crow-review-pr <URL>` form was never an
> option). The inlined SKILL runs `gh pr review` itself, so the posted-verdict
> path needs no extra plumbing; the footer names Antigravity via the threaded
> `agentKind`. The security posture that justified deferring — `agy` runs a
> committed `.agents/hooks.json` with **no approval gate** — is handled by the
> same **strip-not-trust** pattern the other review harnesses use: the review
> clone's committed config (`.agents/` **and**, defensively, the Gemini-derived
> `.gemini/` — #902 r7) is removed at creation (`prepareReviewClone`) **and on
> every launch path** (`prepareWorktreeForAgentLaunch` — the one gate `launchAgent`,
> `pasteDeferredLaunch`, `createManagerTerminal`, the `send` RPC, and handoff all
> route through), and review clones are never auto-trusted. The launch-path strip
> is load-bearing, not redundant: `agy` has no trust gate behind the strip, and a
> warm `crowd` restart or an operator `crow send "agy -c"` reopens the clone after
> the review skill's `gh pr checkout` may have restored a committed layer from
> the head — so a creation-only strip would be insufficient (#902 review r2/r3).
> Because the strip is Antigravity's *only* defense, it removes the whole
> plausibly-discovered surface rather than the native dir alone, matching
> `stripGrokConfigFromReviewClone`.
> With review wired, the old **`shouldRefuseReviewHandoff`
> refusal** (which gated both `crow agents set --review antigravity` and the
> review handoff) is retired — the predicate now refuses nothing, kept only as
> the single coupling point for a hypothetical future review-incapable harness.
> Antigravity's **self-host** axis gap remains **permanent** (closed-source,
> Google-auth-locked); this amendment closes only the review deferral, not the
> Tier-2 classification.

> **Amendment (2026-08-15, CROW-1037):** Grok's Crow Auto mapping is
> `--always-approve` + hard `--deny` on `.work` and `.job`, not `--permission-mode
> auto`. The earlier matrix/code posture treated Grok's classifier `auto` as the
> analogue of Claude's `--permission-mode auto` and declined `--yolo` as a full
> bypass. Lived failure: a Grok work session with Crow Auto on still blocked
> `gh pr create` as an "external publish" until the operator typed
> `/always-approve` in the TUI. Claude under the same Crow flag would have
> opened the PR. Deny still wins over always-approve, so the `rm -rf /`
> literals stay. Reviews stay human-gated. Auto off is still bare `grok`.
>
> **Amendment (2026-08-14, #1033):** a seventh harness — **Muse Code** (Meta's
> `muse` CLI) — joined as an explicit **Tier-2 / experimental** target, the
> same class as Antigravity (#860): a real, driveable CLI that lands below the
> self-hostable harnesses and ships with honest, documented gaps (closed-source
> + Meta-auth-locked ⇒ a *permanent* self-host ❌). Its gaps live in the same
> [capability matrix](../agent-harness-matrix.md) column. Bounded auto-permission
> is the documented `--disable-approval` flag (sandbox stays); Crow never emits
> `--yolo` or `--disable-sandbox`. Review is strip-not-trust (withhold
> `--trust-workspace`, strip `.muse/` + `.agents/` on every launch path). The
> adapter was wired against official docs dated 2026-08-14, **not** a local
> `muse --help` — several cells are tagged needs-eval / wire-worthy for a real
> binary pass before Muse is promoted out of Tier-2.

> **Amendment (2026-08-13, CROW-1001):** **Decision item 3's Codex clause was
> not a stale pin — it was never correct**, and that is a failure mode this ADR
> did not anticipate. The recorded reason for `supportsRemoteControl = false`
> ("Codex doesn't do remote control"; elaborated in the matrix as "Codex's TUI
> isn't stdin-drivable the way `crow send` fakes RC for the others") described
> Crow's *own* plumbing, not upstream Codex — and described it wrongly.
> `crow send` does not write stdin: `TerminalRouter.send` → `TmuxBackend.sendText`
> is tmux `load-buffer` → `paste-buffer` → `send-keys Enter`. Codex's composer
> accepts exactly that, verified in a live pane on `codex-cli 0.141.0`. Since the
> flag gates only the badge and `remoteControlActiveTerminals` — never
> `TerminalRouter.send` — Codex sessions had been remotely drivable the whole
> time, with the UI asserting the opposite. Item 3 is corrected below and the
> flag is now `true`.
>
> The re-check discipline this ADR establishes is aimed at claims **with an
> expiry date** ("sync-only as of v0.139.0"). It has no answer for a claim that
> was wrong on the day it was written, because re-probing *upstream* would never
> have caught this one: nothing about Codex changed. What was needed was
> re-reading Crow's own send path. The lesson for future gap entries: when the
> stated reason is about **Crow's** capability to drive a harness rather than the
> harness's capability, cite the Crow code path that makes it true — a reason
> naming `TerminalRouter.send` would have been falsifiable by reading one
> function. Native `codex remote-control` was evaluated in the same pass and
> **declined on its own merits**, unrelated to the flag; the three blockers and
> their version caveats are in the
> [matrix](../agent-harness-matrix.md#remote-control) and gap audit §3b.

Until now, the *why* behind each gap lived only in scattered code comments —
several of them **pinned to a specific upstream version** ("sync-only as of
v0.139.0"). That makes the reasons easy to lose and, worse, easy to leave stale:
a comment saying "Codex can't do async hooks as of v0.139.0" is a claim with an
expiry date, and nobody re-checks a code comment on a release cadence. This ADR
records the gaps and their rationale as a durable decision, and names the
version-pinned reasons as standing re-check targets.

## Decision

Crow ships non-Claude harnesses at a **lower capability tier on purpose**, and
records the rationale for each gap here (verbatim reasons preserved from source):

1. **Codex review is unsupported.** `OpenAICodexAgent.autoLaunchCommand(.review)`
   returns `nil`: *"Review-on-Codex isn't supported in Phase C — the
   `/crow-review-pr` skill is Claude-only."* Cursor and OpenCode instead get the
   skill body inlined into the prompt (they have no slash-command engine);
   Claude uses the terse `/crow-review-pr <URL>` form. *(Observed at authoring;
   since closed — the `.review` branch now inlines the `/crow-review-pr` skill
   body (like Cursor/OpenCode) and runs `gh pr review` itself to post a real
   verdict, human-gated (#830). Live state: `docs/agent-harness-matrix.md`.)*

2. **Cursor & Codex have no resume.** Both `.job` branches note *"no `--continue`
   equivalent in MVP"* — a restart re-enters a bare TUI rather than replaying the
   prompt. OpenCode's `--continue` re-enters the TUI but carries no history.
   *(Observed at authoring; since closed — Cursor resumes with `--continue`
   (#829) and Codex with `codex resume --last` (#830), and OpenCode's
   run-then-`--continue` shipped in #547. Live state:
   `docs/agent-harness-matrix.md`.)*

3. **Remote control is Claude-native; every other harness is faked.** Claude has
   real `--rc --name` flags. Cursor, Codex, OpenCode, Grok, Antigravity and Muse set
   `supportsRemoteControl = true` with **no RC flag** — remote driving is
   `crow send` into the interactive TUI (the `send` RPC handler in
   `EngineRouter.swift` → `TerminalRouter.send`), agent-agnostic, not a
   per-launch flag.

   *Codex was `false` here until CROW-1001, on the recorded reason "Codex doesn't
   do remote control" / "its TUI isn't stdin-drivable the way `crow send` fakes
   RC for the others." Both halves were wrong: `crow send` is a tmux
   `paste-buffer`, not stdin, and Codex's composer accepts it (verified live on
   `codex-cli 0.141.0`). Since `TerminalRouter.send` never consulted the flag,
   Codex sessions were already drivable and only the badge disagreed. Native
   `codex remote-control` remains unwired for reasons unrelated to the flag —
   see the [harness matrix](../agent-harness-matrix.md#remote-control).*

4. **Codex hooks were sync-only.** `CodexHookConfigWriter.asyncEvents` was
   empty: *"Codex's hook runtime is sync-only as of v0.139.0 — declaring
   `async = true` causes the entry to be silently skipped on startup, which
   breaks Crow's session-state detection."* **Closed by CROW-999** — Codex
   `0.148.0` honors `async` for every event but `SessionEnd` (which it
   downgrades rather than skips, and which Crow doesn't register). The gap is
   now a **version gate** rather than a capability gap: `CodexVersionProbe`
   reads `codex --version` once at boot, and `asyncEvents` (`PostToolUse`) is
   emitted only at `>= 0.148.0`. Below the pin the original reason still
   applies verbatim, so the gate is fail-closed and rejects pre-releases of
   `0.148.0` — async landed at `alpha.9`, so an earlier alpha of that release
   would still skip the hooks. `PreToolUse` stays sync deliberately, matching
   Claude, so it is accepted ahead of the `PermissionRequest` that follows it
   (#903).

5. **Auto-permission is Claude + OpenCode only.** Claude emits
   `--permission-mode auto`; OpenCode runtime-probes `opencode --help` for the
   TUI `--auto` flag (no fallback) and `opencode run --help` for the headless
   auto-approve flag (`--auto`, else `--dangerously-skip-permissions`), applying
   them to `.job` sessions with auto-permission only. Cursor and Codex accept and
   ignore the `autoPermissionMode` argument.

6. **MCP is Claude-only.** Claude's prompt fetches Jira via the `jira` MCP
   server (`jira_get_issue`); its MCP config lives in `~/.claude.json`. The other
   three shipped without an MCP bridge — Cursor, Codex, and OpenCode all emitted
   the same `acli jira workitem view <key>` fallback line. The gap is MCP, not
   Jira ticket-fetch: every harness can still fetch the ticket via `acli`.
   *(Observed at authoring; since closed — Cursor bridges `jira` into
   `~/.cursor/mcp.json` (#829), Codex mirrors `~/.claude.json` into `config.toml`
   (#830), and OpenCode mirrors it into `opencode.json`
   ([CROW-831](https://github.com/corveil/crow/issues/831)). Grok / Antigravity /
   Muse still fall back to `acli`. Live state: `docs/agent-harness-matrix.md`.)*

7. **Non-Claude hooks are global-scope, session resolved by `cwd`.** Only Claude
   writes a per-worktree config keyed by `--session <UUID>`. Cursor
   (`~/.cursor/hooks.json`), Codex (`~/.codex/hooks.json` + `config.toml`
   `notify`), and OpenCode (global JS plugin `crow-hooks.js`) all omit
   `--session` and let the server resolve the session by matching `cwd` against
   registered worktree paths. *(Observed at authoring; since closed for Cursor
   (#829), Codex ([CROW-1060](https://github.com/corveil/crow/issues/1060) —
   per-worktree `.codex/hooks.json`, `notify` bridge retired), and OpenCode
   ([CROW-831](https://github.com/corveil/crow/issues/831) — per-worktree
   `.opencode/plugins/crow-hooks.js` with `--session <UUID>` baked in; the
   host-global plugin is a self-suppressing fallback). The live per-harness
   hook-scope state is `docs/agent-harness-matrix.md`.)*

8. **Capability availability is gated on binary registration.** A harness whose
   `findBinary()` misses is registered as *known-but-unavailable* (surfaced-but-
   disabled in the pickers since #879 — see ADR 0014's *Superseded behavior*
   blockquote) and kept out of the launchable `agents` map, so *all* of its
   capabilities remain unavailable — a handoff to it still throws
   `agentNotRegistered`. Claude is always registered and available. Gating is
   uneven across surfaces, though: session
   *creation* (`EngineRouter.swift` new-session) takes `requestedAgentKind ??
   agentKind(for: .work)` with **no** registry check, so a session can be created
   with an unregistered kind and `launchAgent` then silently no-ops on the
   registry lookup. The two Manager-creation surfaces also differ: the **web**
   `create-manager` (`EngineRouter.swift`) validates against the registry (CROW-593
   security gate, falling back to the configured default), but the **daemon's**
   `create-manager` (`RPCHandlers.swift`) passes the requested kind straight through —
   and there the launch degrades differently again, `managerCommand` falling back
   to `AgentRegistry.defaultAgent` rather than no-op'ing. Closing these
   asymmetries is a code follow-up ([#834](https://github.com/corveil/crow/issues/834)),
   not a doc change.

These gaps are **phased parity, not permanent tiers.** Comments mark the phase
that will close them (Cursor/Codex/OpenCode launchers are written but
"not wired into the auto-launch path yet"; Phase D adds harness-flavored
`crow-workspace` skills). Nothing here is a decision to *never* reach parity.

## Consequences

- Users get a **consistent core loop on every harness** (launch → observe state
  → handoff) while advanced affordances (review, MCP, native RC, per-session
  hook scope) remain Claude-first. The [matrix](../agent-harness-matrix.md) is
  the single place that says which is which.
- **Version-pinned reasons are re-check targets, not settled facts.** Each pin
  must be re-verified when the harness ships a new release; a stale pin is a bug.
  These pins are the explicit **seed for a follow-up capability audit** — the
  audit walks each row and confirms (or retires) the reason. **That audit is now
  recorded in [`agent-harness-gap-audit.md`](../agent-harness-gap-audit.md)
  ([#828](https://github.com/corveil/crow/issues/828)):** of the eight gaps above,
  five have gained an upstream flag (resume, auto-permission, MCP, Codex review,
  per-project hook scope) with closure tickets
  [#829](https://github.com/corveil/crow/issues/829)–[#831](https://github.com/corveil/crow/issues/831);
  Codex async hooks (gap 4) closed on the 2026-08-13 re-check and shipped behind
  a version gate in [CROW-999](https://github.com/corveil/crow/issues/999); gap
  3's Codex clause was **retired as incorrect** rather than closed by an upstream
  bump ([CROW-1001](https://github.com/corveil/crow/issues/1001) — see the
  2026-08-13 amendment, and note that an upstream-only re-probe could not have
  caught it). The canonical
  row-set lives in the matrix's
  [Version-pinned reasons — re-check targets](../agent-harness-matrix.md#version-pinned-reasons--re-check-targets)
  table (kept in one place so the two docs can't go stale asymmetrically);
  today it covers the Codex async-hook **minimum** (**≥ 0.148.0**), the
  `codex_hooks`→`hooks`
  rename (**v0.139.0+**), the `ClaudeHooksEngine` reuse (**codex 0.123.0**),
  Claude's recap subagent (**≥ 2.1.108**), OpenCode's `session.status` done
  signal (**opencode 1.18.5**, CROW-1000 — replaces the formerly unpinned
  `session.idle` question), and the one still-unpinned empirical timing
  (Cursor async). Codex's async *timing* is **resolved** (CROW-1065): the
  stable `0.148.0` shipped (2026-08-18), and the timing is safe *by
  construction* — `PostToolUse` is the only async event and touches only a
  persistence-excluded, reader-less field, so no ordering against the sync
  `Stop` is observable on the card — tracked inside its pinned row rather than
  as a separate one.

- The gating rule (8) means a partially-installed environment produces a smaller,
  correct picker rather than broken entries — but "why can't I hand off to X?"
  is answered by binary presence, which is easy to miss.

## Alternatives considered

- **Block non-Claude harnesses until they reach parity.** Rejected — the core
  loop works on all four today; withholding them helps no one and the gaps are
  clearly labeled.
- **Leave the rationale in code comments only** (status quo before this ADR).
  Rejected — version-pinned claims rot silently and there was no single index of
  what's missing or why.
- **Fake the missing capabilities** (e.g. emit `--auto` for Codex regardless).
  Rejected — a flag the harness silently drops (or that breaks state detection,
  as an `async` hook does on a pre-0.148 Codex) is worse than an honest gap.
  Gap 4's closure keeps that rule rather than relaxing it: `async` is emitted
  only once a probe confirms the installed Codex honors it.
- **A `Set<Capability>` per agent** (mirroring 0005's `TaskCapability`).
  Considered — the current design encodes capabilities as typed protocol members
  instead, which the compiler checks. A capability set may still be worth adding
  if the number of "is X supported?" branches grows; deferred.

## References

- Issue: [#827](https://github.com/corveil/crow/issues/827)
- Related ADRs: [0014](./0014-pluggable-coding-agent-adapter.md) (the adapter),
  [0004](./0004-manager-auto-permission-mode.md) (`--permission-mode auto`),
  [0011](./0011-agent-handoff-preserves-session-not-chat.md) (handoff)
- Code:
  - `Packages/CrowCodex/Sources/CrowCodex/{OpenAICodexAgent,CodexHookConfigWriter,CodexSignalSource}.swift`
  - `Packages/CrowCursor/Sources/CrowCursor/{CursorAgent,CursorHookConfigWriter,CursorSignalSource}.swift`
  - `Packages/CrowOpenCode/Sources/CrowOpenCode/{OpenCodeAgent,OpenCodeLaunchArgs,OpenCodeHookConfigWriter}.swift`
  - `Packages/CrowClaude/Sources/CrowClaude/{ClaudeLauncher,ClaudeHookConfigWriter,ClaudeHookSignalSource}.swift`
  - `Packages/CrowEngine/Sources/CrowEngine/SessionService.swift` (`buildReviewPrompt`, `launchAgent`)
- Reference: [Coding-agent harness capability matrix](../agent-harness-matrix.md)
