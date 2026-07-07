# Troubleshooting

## Build Issues

| Problem                                                  | Solution                                                                 |
| -------------------------------------------------------- | ------------------------------------------------------------------------ |
| `swift build` fails on missing `BuildInfo`               | Use `make build` — it generates build info before compiling. Bare `swift build` only works after an initial `make build`. |
| `make build` fails partway through                       | Run `make clean-all && make build` to force a clean rebuild. |

## Runtime Issues

| Problem                                                  | Solution                                                                 |
| -------------------------------------------------------- | ------------------------------------------------------------------------ |
| `crow` CLI: "Connection refused"                         | A server must be listening on `~/.local/share/crow/crow.sock`. By default that's the `crowd` daemon (`make crowd-dev`, or run `crowd` with defaults); a legacy app with `CROW_LOCAL_ENGINE=1` binds it instead. A "connection refused" (vs "no such file") means the socket file is stale — start `crowd` and it reclaims it. As of #234, `crow hook-event` is a silent no-op when nothing is listening, so non-Crow `claude` sessions no longer log noise. |
| GitHub API errors / empty issue list                     | Check auth: `gh auth status`. Ensure scopes include `repo`, `read:org`, `project`. If missing, run `gh auth refresh -s project,read:org,repo`. |
| `INSUFFICIENT_SCOPES` in `[IssueTracker]` stderr         | Run `gh auth refresh -s project`. **`read:project` is NOT sufficient** — the write `project` scope is required to update ticket status via `updateProjectV2ItemFieldValue`. See `Sources/Crow/App/IssueTracker.swift:691-692,768-769`. |
| Ticket stays "Backlog" when starting a session           | Same as above — the `markInReview` code path requires the write `project` scope |
| Terminal not starting                                    | Check stderr for `[TmuxBackend]` or `[XTermSurfaceView]` messages. Managed terminals run on tmux; if one is stuck, close and reopen it from the session detail header, or use the on-terminal Retry affordance after a readiness timeout. |
| tmux backend not starting                                | tmux is required for managed terminals (#303). If tmux is missing or < 3.3, Crow surfaces a launch alert with a `brew install tmux` hint and managed terminals won't render until tmux is installed. Verify with `tmux -V`, then relaunch Crow. |
| Issue tracker shows no tickets                           | Verify `gh auth status` shows `repo`, `read:org`, `project` scopes       |
| GitLab tickets missing                                   | Run `glab auth status --hostname <your-host>`; ensure `GITLAB_HOST` matches what's in `{devRoot}/.claude/config.json`. After #215, Crow silently skips GitLab candidates whose host can't be determined instead of failing the whole reconcile pass — check the workspace's `host` field if a repo isn't being polled. |
| GitLab nested-group repo fails to fetch                  | Slug parsing was widened in #233 to preserve nested paths like `big-bang/product/packages/elasticsearch-kibana`. If a fetch still fails, run `glab repo view <full-path>` from inside the worktree to confirm the slug, and check `glab auth status --hostname <host>`. |
| Sidebar status dot stuck gray                            | Terminal never initialized — click the session tab to trigger `createSurface()` |
| Sidebar status dot stuck yellow                          | Shell is spawning but the probe file never appeared. Check `[TerminalManager]` logs for shell-startup errors |
| Auto-respond didn't fire on a failed CI run              | Toggle is at **Settings → Automation → Auto-respond**, off by default. The session must have an active Claude Code terminal that `TerminalRouter.canSend` accepts; a torn-down terminal won't receive the prompt. See [automation.md](automation.md) for full coverage. |
| Sidebar shows "working" forever after a `※ recap:` line  | The Claude Code session recap (`awaySummaryEnabled`, on by default in v2.1.108+) fires hook events after a turn's `Stop`. Crow now ignores those — if you're on an older build, disable the recap by setting `"awaySummaryEnabled": false` in `~/.claude/settings.json`, toggling "Session recap" off via `/config` inside Claude Code, or exporting `CLAUDE_CODE_ENABLE_AWAY_SUMMARY=0`. |

## Debugging

The app logs diagnostic information to stderr with component tags:

- `[TerminalManager]` — Surface creation, shell readiness transitions
- `[SessionService]` — Orphan detection, session lifecycle changes
- `[IssueTracker]` — GitHub/GitLab API errors, scope issues, project status queries
- `[JSONStore]` — Decode failures (store data loss prevention)
- `[XTermSurfaceView]` — Surface creation success/failure
- `[TerminalRouter]` — tmux send/destroy errors when the tmux backend is enabled (#229)
- `[AppSupportDirectory]` — One-time `rm-ai-ide` → `crow` migration events
- `[Scaffolder]` — Template file loading (development builds)
- `[hook-event]` — Claude Code hook event arrivals and `ClaudeState` transitions. Off by default. Set `CROW_HOOK_DEBUG=1` before launching to enable; useful when diagnosing why the sidebar status dot is in the wrong state.

Run with log filtering to focus on a subsystem:

```bash
.build/debug/CrowApp 2>&1 | grep '\[TerminalManager\]\|\[SessionService\]'
```

Filter for scope / auth errors while you're iterating on `gh` permissions:

```bash
.build/debug/CrowApp 2>&1 | grep '\[IssueTracker\]'
```

## Quarantine Warnings on an Unsigned Build

Developers building from source do not need a signing certificate — `make build` and `make release` produce unsigned but fully functional binaries. If macOS quarantines an unsigned `.app`, remove the quarantine attribute:

```bash
xattr -cr Crow.app
```
