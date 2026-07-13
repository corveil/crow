# 0003 — Worktree-per-task model

- **Status:** Accepted
- **Date:** 2026-05-25
- **Deciders:** Crow maintainers

## Context

Crow's central pattern is running multiple Claude Code sessions in parallel, each working on a different ticket. A single clone of a repo can only have one branch checked out at a time — the working tree, the index, and `HEAD` are shared global state. That makes branch-switching hostile to parallel agents: any two sessions touching the same clone will fight over the working tree, and an agent that runs `git checkout` mid-task can clobber another agent's edits.

We also want the on-disk layout to be self-describing — a path like `/Users/jane/Dev/RadiusMethod/acme-api-197-fix-tab-url-hash` should reveal the repo, the ticket, and the slug at a glance, both for humans and for grep-based agent navigation.

## Decision

Each session gets its **own git worktree** at `{devRoot}/{workspace}/{repo}-{ticket}-{slug}`, on its own branch created with `--no-track origin/main`. Worktrees are **siblings of the main clone**, never nested under a `worktrees/` subdirectory.

The Manager session and other fixed-UUID virtual sessions are exempt from cleanup. Other completed/archived sessions can be auto-cleaned (worktree directory + branch removed) after a configurable retention window; auto-cleanup is opt-in and disabled by default.

## Consequences

**Easier:**

- Parallel sessions are fully isolated — two sessions touching the same repo can run side-by-side without `HEAD` contention.
- The path scheme is grep-able. `ls {devRoot}/{workspace}/` is the session list.
- `--no-track` on branch creation prevents an accidental `git push` from publishing a stray feature branch to `main`'s tracking remote.
- Cleanup is a directory removal plus a branch delete — no orphan state.

**Harder / accepted:**

- Disk usage scales with the number of active sessions (working tree is duplicated, though `.git` objects are shared via the parent clone).
- `git worktree add` setup time per session (typically <1 s for warm repos, longer for cold).
- Tooling has to be worktree-aware: `cd`-into-clone scripts break; everything uses `git -C <path>` instead.

## Alternatives considered

- **Branch-switching in one clone.** Rejected — blocks concurrency; one of the original motivating problems.
- **Per-session full clones.** Rejected — duplicates `.git`, breaks the shared object DB, and slows down `git worktree add`-style operations.
- **Bare-clone hub with task-specific checkouts.** Rejected — a worktree off a normal clone gives us the same benefit without forcing every developer to maintain a separate bare-clone hub.

## References

- PRs: [#261](https://github.com/corveil/crow/pull/261) (auto-cleanup of completed sessions)
- Code:
  - `skills/crow-workspace/setup.sh` (creates the worktree and enforces the naming convention)
  - `Packages/CrowCore/Sources/CrowCore/Models/Worktree.swift`
  - `Packages/CrowCLI/Sources/CrowCLILib/Commands/WorktreeCommands.swift`
- Reference: [`CLAUDE.md`](../../CLAUDE.md) — "Git Worktree Best Practices"
