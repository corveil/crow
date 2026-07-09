# 0011 — Mid-session agent handoff preserves Crow identity, not chat history

- **Status:** Accepted
- **Date:** 2026-07-09
- **Deciders:** @dgershman

## Context

Users hit per-agent credit limits mid-task (Claude Code → Cursor, etc.) and need to continue the same Crow session without recreating worktrees or losing ticket context ([#627](https://github.com/radiusmethod/crow/issues/627)). Each coding agent keeps its own conversation store; there is no portable transcript format across Claude Code, Cursor, Codex, and OpenCode. Crow already persists per-session `agentKind` and launches via the `CodingAgent` protocol, but until now that kind was fixed at create time (Manager config reconcile aside).

## Decision

Crow treats agent handoff as **session metadata + managed-terminal replace**:

1. Persist the new `session.agentKind`.
2. Destroy managed agent terminals for that session (unmanaged Shell tabs stay).
3. Recreate one managed terminal and seed it with a **handoff prompt** built from the target agent's `generatePrompt` plus a short resume brief (prior agent, optional note, `git status` orientation).
4. Launch via `launchCommand` + the deferred `#408` paste path — **not** `autoLaunchCommand` / `--continue`, which resume the *previous* agent's local conversation.

Exposed as RPC/CLI `handoff-agent` and a web UI “Switch agent…” control. Manager sessions are out of scope (Settings + restart).

## Consequences

- Same Crow session UUID, worktree, branch, and ticket survive the switch.
- The incoming agent starts a **new** chat with an explicit resume point; prior tool/chat history does not transfer.
- Hook config and Claude-only trust/gateway prep run for the target agent before launch.
- Credit exhaustion is user/Manager-initiated; Crow does not auto-detect quota errors in this ADR.

## Alternatives considered

- **Export/import transcripts across agents** — no shared format; rejected for MVP.
- **Only flip `agentKind` and wait for crash recovery** — leaves the old process running and would relaunch via `--continue`/bare TUI without a handoff brief.
- **Spawn a second Crow session** — duplicates worktrees and breaks ticket/PR linkage.

## References

- Issue: https://github.com/radiusmethod/crow/issues/627
- Code: `Packages/CrowEngine/Sources/CrowEngine/AgentHandoff.swift`, `SessionService.handoffAgent`
- Related ADRs: [0003](./0003-worktree-per-task-model.md), [0007](./0007-crowd-sole-authority-clients-only.md)
