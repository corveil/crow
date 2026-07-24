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
   driving is `crow send` typing into the interactive TUI (the `send` RPC handler
   in `EngineRouter.swift` → `TerminalRouter.send`), agent-agnostic, not a per-launch
   flag.

4. **Codex hooks are sync-only.** `CodexHookConfigWriter.asyncEvents` is empty:
   *"Codex's hook runtime is sync-only as of v0.139.0 — declaring `async = true`
   causes the entry to be silently skipped on startup, which breaks Crow's
   session-state detection."*

5. **Auto-permission is Claude + OpenCode only.** Claude emits
   `--permission-mode auto`; OpenCode runtime-probes `opencode --help` for the
   TUI `--auto` flag (no fallback) and `opencode run --help` for the headless
   auto-approve flag (`--auto`, else `--dangerously-skip-permissions`), applying
   them to `.job` sessions with auto-permission only. Cursor and Codex accept and
   ignore the `autoPermissionMode` argument.

6. **MCP is Claude-only.** Claude's prompt fetches Jira via the `jira` MCP
   server (`jira_get_issue`); its MCP config lives in `~/.claude.json`. The other
   three have no MCP wiring — Cursor, Codex, and OpenCode all emit the same
   `acli jira workitem view <key>` fallback line. The gap is MCP, not Jira
   ticket-fetch: every harness can still fetch the ticket via `acli`.

7. **Non-Claude hooks are global-scope, session resolved by `cwd`.** Only Claude
   writes a per-worktree config keyed by `--session <UUID>`. Cursor
   (`~/.cursor/hooks.json`), Codex (`~/.codex/hooks.json` + `config.toml`
   `notify`), and OpenCode (global JS plugin `crow-hooks.js`) all omit
   `--session` and let the server resolve the session by matching `cwd` against
   registered worktree paths.

8. **Capability availability is gated on binary registration.** A harness whose
   `findBinary()` misses is never registered ([ADR 0014](./0014-pluggable-coding-agent-adapter.md)),
   so *all* of its capabilities are unavailable — the picker and `handoff-agent`
   act as if it doesn't exist (a handoff to it throws `agentNotRegistered`).
   Claude is always registered. Gating is uneven across surfaces, though: session
   *creation* (`EngineRouter.swift` new-session) takes `requestedAgentKind ??
   agentKind(for: .work)` with **no** registry check, so a session can be created
   with an unregistered kind and `launchAgent` then silently no-ops on the
   registry lookup. The two Manager-creation surfaces also differ: the **web**
   `create-manager` (`EngineRouter.swift`) validates against the registry (CROW-593
   security gate, falling back to the configured default), but the **daemon's**
   `create-manager` (`RPCHandlers.swift`) passes the requested kind straight through —
   and there the launch degrades differently again, `managerCommand` falling back
   to `AgentRegistry.defaultAgent` rather than no-op'ing. Closing these
   asymmetries is a code follow-up, not a doc change.

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
  audit walks each row and confirms (or retires) the reason. The canonical
  row-set lives in the matrix's
  [Version-pinned reasons — re-check targets](../agent-harness-matrix.md#version-pinned-reasons--re-check-targets)
  table (kept in one place so the two docs can't go stale asymmetrically);
  today it covers Codex sync-only (**v0.139.0**), the `codex_hooks`→`hooks`
  rename (**v0.139.0+**), the `ClaudeHooksEngine` reuse (**codex 0.123.0**),
  Claude's recap subagent (**≥ 2.1.108**), and the two unpinned empirical
  timings (Cursor async, OpenCode `session.idle` / CROW-545).

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
