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
   Claude uses the terse `/crow-review-pr <URL>` form.

2. **Cursor & Codex have no resume.** Both `.job` branches note *"no `--continue`
   equivalent in MVP"* — a restart re-enters a bare TUI rather than replaying the
   prompt. OpenCode's `--continue` re-enters the TUI but carries no history.

3. **Remote control is Claude-native; others are faked or absent.** Codex sets
   `supportsRemoteControl = false` ("Codex doesn't do remote control", no `--rc`
   flag). Cursor and OpenCode set it `true` but have **no RC flag** — remote
   driving is `crow send` typing into the interactive TUI
   (`SessionService.send`), agent-agnostic, not a per-launch flag.

4. **Codex hooks are sync-only.** `CodexHookConfigWriter.asyncEvents` is empty:
   *"Codex's hook runtime is sync-only as of v0.139.0 — declaring `async = true`
   causes the entry to be silently skipped on startup, which breaks Crow's
   session-state detection."*

5. **Auto-permission is Claude + OpenCode only.** Claude emits
   `--permission-mode auto`; OpenCode runtime-probes `opencode --help` for
   `--auto` (falling back to `--dangerously-skip-permissions`) and applies it to
   `.job` sessions with auto-permission only. Cursor and Codex accept and ignore
   the `autoPermissionMode` argument.

6. **MCP is Claude-only.** Claude's prompt fetches Jira via the `jira` MCP
   server (`jira_get_issue`); its MCP config lives in `~/.claude.json`. Cursor
   falls back to `acli jira workitem view`; Codex and OpenCode have no MCP wiring.

7. **Non-Claude hooks are global-scope, session resolved by `cwd`.** Only Claude
   writes a per-worktree config keyed by `--session <UUID>`. Cursor
   (`~/.cursor/hooks.json`), Codex (`~/.codex/hooks.json` + `config.toml`
   `notify`), and OpenCode (global JS plugin `crow-hooks.js`) all omit
   `--session` and let the server resolve the session by matching `cwd` against
   registered worktree paths.

8. **Capability availability is gated on binary registration.** A harness whose
   `findBinary()` misses is never registered ([ADR 0014](./0014-pluggable-coding-agent-adapter.md)),
   so *all* of its capabilities are unavailable — the picker and `handoff-agent`
   act as if it doesn't exist. Claude is always registered.

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
  below must be re-verified when the harness ships a new release; a stale pin is
  a bug in this ADR. This table is the explicit **seed for a follow-up capability
  audit** — the audit walks each row and confirms (or retires) the reason.

  | Gap | Pin | Source of truth |
  |---|---|---|
  | Codex hooks sync-only | Codex **v0.139.0** | `CodexHookConfigWriter.asyncEvents` |
  | Codex `config.toml` key `codex_hooks` → `hooks` | Codex **v0.139.0+** | `CodexHookConfigWriter.installGlobalTomlConfig` |
  | Codex reuses `ClaudeHooksEngine` (schemas byte-compatible) | **codex 0.123.0** | `CodexSignalSource` |
  | Claude recap subagent must not elevate state | Claude Code **≥ 2.1.108** (`awaySummaryEnabled`) | `ClaudeHookSignalSource` |
  | Cursor `PostToolUse`/`Notification` async timing | empirical (unpinned) | `CursorSignalSource` |
  | OpenCode `session.idle` "done" semantics | CROW-545 (empirical) | `OpenCodeHookConfigWriter` |

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
  as async Codex hooks do) is worse than an honest gap.
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
  - `Packages/CrowCodex/Sources/CrowCodex/{OpenAICodexAgent,CodexHookConfigWriter,CodexSignalSource,CodexNotifyPayload}.swift`
  - `Packages/CrowCursor/Sources/CrowCursor/{CursorAgent,CursorHookConfigWriter,CursorSignalSource}.swift`
  - `Packages/CrowOpenCode/Sources/CrowOpenCode/{OpenCodeAgent,OpenCodeLaunchArgs,OpenCodeHookConfigWriter}.swift`
  - `Packages/CrowClaude/Sources/CrowClaude/{ClaudeLauncher,ClaudeHookConfigWriter,ClaudeHookSignalSource}.swift`
  - `Packages/CrowEngine/Sources/CrowEngine/SessionService.swift` (`buildReviewPrompt`, `launchAgent`)
- Reference: [Coding-agent harness capability matrix](../agent-harness-matrix.md)
