# Architecture Decision Records

Architectural Decision Records (ADRs) capture decisions that shaped Crow and the reasoning behind them. Each file is one decision. The *what* of a change lives in its PR description; the *why* lives here, where it can be grepped, diffed, and superseded.

## When to write an ADR

Write one when the decision will outlive the PR that implements it. Rules of thumb:

- It establishes a default, contract, or invariant other code relies on.
- It picks one of several reasonable approaches, and a new contributor (or agent) would want to know why.
- You'd be unhappy if someone re-litigated it six months later without finding your reasoning.
- It will be referenced from `CLAUDE.md`, `CONTRIBUTING.md`, or another ADR.

A PR description is enough for changes whose rationale doesn't outlive the diff (bug fixes, small refactors, UI tweaks).

## How to add one

1. Copy [`template.md`](./template.md) to `NNNN-kebab-case-title.md` using the next 4-digit sequence number (next free is shown in the index below).
2. Fill in `Status`, `Date`, `Deciders`, and the four body sections (`Context`, `Decision`, `Consequences`, `Alternatives considered`).
3. Link the PR(s) that implement(ed) the decision.
4. Add a row to the index in this file.

## How to supersede an ADR

Don't delete the old file. Update its `Status` to `Superseded by NNNN` and point to the replacement. The history is the point — a future reader needs to see what we used to do and why we changed.

## Status legend

| Status | Meaning |
|--------|---------|
| `Proposed` | Under discussion; not yet adopted. |
| `Accepted` | Active. Code reflects this decision. |
| `Superseded by NNNN` | Replaced by ADR `NNNN`. File is kept for history. |
| `Deprecated` | No longer applies; not yet replaced. |

## Index

| # | Title | Status | Date |
|---|-------|--------|------|
| 0001 | [tmux as the sole terminal backend](./0001-tmux-only-terminal-backend.md) | Accepted | 2026-05-25 |
| 0002 | [Unix-socket CLI ↔ app architecture](./0002-unix-socket-cli-architecture.md) | Accepted | 2026-05-25 |
| 0003 | [Worktree-per-task model](./0003-worktree-per-task-model.md) | Accepted | 2026-05-25 |
| 0004 | [Manager session launches in auto-permission mode by default](./0004-manager-auto-permission-mode.md) | Accepted | 2026-05-25 |
| 0005 | [TaskBackend and CodeBackend protocols](./0005-task-and-code-backend-protocols.md) | Proposed | 2026-06-03 |
| 0006 | [xterm.js terminal renderer (Intel support)](./0006-universal-macos-binary.md) | Accepted | 2026-07-01 |
| 0007 | [crowd is the sole authority; every UI is a pure client](./0007-crowd-sole-authority-clients-only.md) | Accepted | 2026-07-05 |
| 0008 | [Retire the macOS app; the web UI is the only client](./0008-retire-the-macos-app.md) | Accepted | 2026-07-07 |
| 0009 | [Mid-session agent handoff preserves Crow identity, not chat history](./0009-agent-handoff-preserves-session-not-chat.md) | Accepted | 2026-07-09 |
