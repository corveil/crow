# 0028 — Manager cold-start resume is by harness conversation id

- **Status:** Accepted
- **Date:** 2026-09-21
- **Deciders:** @dhilgaertner

## Context

After a machine reboot (or `tmux kill-server`), Manager tabs came back detached from the agent conversation they had been attached to. Which conversation they landed on felt random. Work sessions usually resumed correctly.

Work / job / review sessions relaunch via `autoLaunchCommand` in a **unique worktree cwd**, using cwd-scoped resume (`claude --continue`, `codex resume --last`). Manager sessions relaunch via `managerLaunchCommand` as the terminal's shell `command`. That path had **no resume flag**. Crow never persisted the harness conversation id (Claude session, Cursor `chatId`, Codex thread). Extra Managers typically shared `{devRoot}` as cwd, so even adding `--continue` would make launch order decide who inherited whose transcript — and hydrate rewrote `{devRoot}/.claude/settings.local.json` with `--session <thisManagerUuid>` for each Manager, last writer owning hook routing.

Warm Crow restarts adopt live panes and are fine. This is a cold-start identity bug, not a tmux glitch (CROW-1281).

## Decision

Crow persists a harness-native conversation id on each `Session` when hook payloads carry one, and cold-start Manager relaunch calls **resume-by-id** (`claude --resume <id>`, `cursor-agent --resume <chatId>`, `codex resume <id>`), not cwd-scoped `--continue` / `resume --last`.

Extra Managers whose requested cwd is `{devRoot}` get an isolated project directory `{devRoot}/.crow/managers/<session-uuid>/` so they do not share one session list or one hook file. The primary Manager stays at `{devRoot}`. Claude extra Managers also receive `--add-dir {devRoot}` so orchestration still sees the real tree.

Work session `--continue` / `resume --last` in unique worktrees is unchanged.

## Consequences

- Managers that have emitted at least one hook survive reboot with the same transcript.
- Extra Managers no longer clobber each other's `{devRoot}` hook `--session` routing.
- A Manager that has never hooked (or a legacy row with no stored id) starts a fresh TUI on first cold start after upgrade; the next SessionStart captures the id.
- Agents with no resume-by-id surface (Antigravity `-c` is machine-global; Muse `--session-id` needs-eval) still gain isolated cwd / hook files. Grok uses isolated-cwd `-c` after an id is captured.

## Alternatives considered

- **Only add `--continue` to `managerLaunchCommand`.** Extra Managers sharing `{devRoot}` would shuffle worse. Rejected.
- **Resume-by-id without isolated cwd.** Conversation identity would be correct, but extra Managers would still last-write `{devRoot}/.claude/settings.local.json`. Rejected as incomplete.
- **Look up Claude ids from telemetry `session_map` at relaunch.** Telemetry is optional and Claude-only; hook capture is the durable path. Left as a possible follow-up for the first reboot after upgrade.

## References

- Issue: https://github.com/corveil/crow/issues/1281
- Related ADRs: [0011](./0011-agent-handoff-preserves-session-not-chat.md), [0014](./0014-pluggable-coding-agent-adapter.md)
- Code: `Packages/CrowCore/Sources/CrowCore/Agent/HarnessConversationID.swift`, `Packages/CrowEngine/Sources/CrowEngine/ManagerIdentity.swift`, `CodingAgent.managerLaunchCommand`
