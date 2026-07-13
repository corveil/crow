# 0004 — Manager session launches in auto-permission mode by default

- **Status:** Accepted
- **Date:** 2026-05-25
- **Deciders:** Crow maintainers

## Context

The Manager session is the orchestration tab inside Crow. Its job is to run `crow` subcommands, fetch ticket data via `gh` / `glab`, manipulate worktrees with `git`, and spawn worker sessions. In a typical Manager run, it issues dozens of these calls in quick succession.

Claude Code's default permission model prompts the user before each shell command. For a worker session doing user-facing work, that's the right default — the user is the one driving the task and a prompt is a useful checkpoint. For the Manager, it makes the experience unusable: every `crow list-sessions`, every `gh issue view`, every `git worktree add` would block on a prompt.

A purely permission-allowlist approach was tried first. It works for the most common commands but does not generalize — the long tail of `crow` subcommands, `gh api`, `git -C`, and ad-hoc one-liners is too broad to enumerate, and missing rules silently fall back to a prompt.

## Decision

The Manager terminal is launched with `--permission-mode auto` by default. This is governed by `AppConfig.managerAutoPermissionMode`, which defaults to `true`. Worker sessions and any terminal spawned via `crow new-terminal` do **not** get `--permission-mode auto` — they use Claude Code's default mode.

The trust scope is explicit: only the Manager. The user can disable Manager auto-permission via the config field if their threat model requires it.

## Consequences

**Easier:**

- The Manager can orchestrate without per-call friction. Workflows that issue many `crow` / `gh` / `git` calls finish in the time it takes them to run, not the time it takes the user to click "Allow."
- Trust boundary is clear — exactly one tab gets the elevated mode, and it's the one running on a curated `CLAUDE.md` with curated allowlists.

**Harder / accepted:**

- Anything the Manager Claude decides to run, runs. The Manager is implicitly trusted; we accept this as the cost of automation.
- Adding new automation behavior to the Manager requires re-confirming that no command in the workflow is destructive without intent. Manager-context guidance in `CLAUDE.md` (e.g. "use single-clean invocations for ticket fetches") is now load-bearing for both ergonomics *and* safety.

## Alternatives considered

- **Global auto-permission for every session.** Rejected — too broad; a worker session doing actual user-facing work should still prompt.
- **Per-command allowlist only.** Rejected — tried first; the long tail of subcommands and one-liners falls through to prompts and breaks orchestration.
- **Confirm-once-per-session interactive mode.** Rejected — the Manager runs unattended for long stretches; an interactive confirm at the start of every run is just a prompt with extra steps.

## References

- PRs: [#189](https://github.com/corveil/crow/pull/189) (introduce `managerAutoPermissionMode`, default `true`)
- Code:
  - `Packages/CrowCore/Sources/CrowCore/Models/AppConfig.swift`
  - `Packages/CrowCore/Sources/CrowCore/AppState.swift`
  - `Packages/CrowCore/Sources/CrowCore/ClaudeLaunchArgs.swift`
  - `Sources/Crow/App/SessionService.swift`
- Tests:
  - `Packages/CrowCore/Tests/CrowCoreTests/ClaudeLaunchArgsTests.swift`
  - `Packages/CrowCore/Tests/CrowCoreTests/AppConfigTests.swift`
