# Changelog

All notable changes to Crow will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Backfill of merged PRs since the 0.1.0 release, grouped by theme.

### Web UI

- #752 — Multi-select "Start Working (N)" on the tickets board now fires a single `batch-work-on-issues` RPC, so the Manager runs one `/crow-batch-workspace url1 url2 …` (parallel setup) instead of N separate `/crow-workspace` submissions.
- #613 — Left pane paints chrome + skeleton (or cached last-known) session rows on first load before `list-sessions` returns, then swaps in real rows without a blank flash.
- #768 — Notifications for automation events are back after the native→web move: auto-workspace created, auto-merge enabled, auto-rebase pushed, auto-rebase conflicts, and config reloaded. The daemon pushes each over the existing `/rpc` socket at the moment the watcher acts; the web UI chimes and posts a browser notification, with per-event Enabled / sound / system toggles under Settings → Notifications. Conflict events use a distinct, harsher tone and are never suppressed by the "you're looking at it" focus rule.

### Automation

- #137 — Session analytics emitted via Claude Code's OpenTelemetry exporter (configure via `CLAUDE_CODE_ENABLE_TELEMETRY` and `OTEL_EXPORTER_OTLP_ENDPOINT`).
- #163 / #165 — Add `remoteControlEnabled` setting; new sessions launch with `--rc` so they can be driven from claude.ai or the mobile app. The `/crow-workspace` skill honors the setting.
- #182 — Auto-complete now requires positive evidence that the session was worked before flipping to Completed; prevents idle sessions being marked done by an unrelated PR merge.
- #189 — Manager terminal launches in `--permission-mode auto` by default so orchestration commands (`crow`, `gh`, `git`) skip per-call approval. Toggle at Settings → Automation → Manager Terminal.
- #209 — Per-workspace opt-in to auto-start review sessions when a PR becomes reviewable.
- #211 — Auto-create a workspace when an issue assigned to you carries the `crow:auto` label.
- #213 — Auto-suggest opening a PR when a session completes its work but no PR is linked yet.
- #214 — Optional auto-respond toggles: when enabled, Crow types an instruction into the session's Claude Code terminal in response to changes-requested reviews and failed CI checks. Off by default.
- #222 — PRs opened from a Crow session are auto-labeled `crow:auto`.
- #228 — Settings split into discrete tabs; every automation toggle lives under Settings → Automation. New `docs/automation.md` covers the full lifecycle.
- #327 — Scheduled Jobs scope to a workspace + repo, where the repo picker is populated from the workspace's provider by expanding its "Always Include Repos" specs (`owner/*` globs or `owner/repo` slugs). Repos not yet checked out are cloned on demand when the job fires.
- #461 — Remove the PR auto-label workflow (reverts #222); `crow:auto` on a PR was a no-op since only assigned issues consume the label. The label itself stays for issue auto-launch.
- #604 — Full job management from the CLI: `crow job list/get/add/edit/enable/disable/run/delete/duplicate`. Mutations route through the running app's live config (picked up by the scheduler and Settings UI without a restart), and `crow job run --id` fires a job immediately regardless of its schedule or enabled flag, returning the launched session/terminal ids.

### Review Board & Sessions

- #153 — Fix PR review status not reflecting the actual review state.
- #174 — Ticket card issue and PR chips are now clickable.
- #188 — "Move to Active" button on completed sessions returns them to active without deletion.
- #205 — PR link reconciliation for sessions that missed reactive detection — `gh pr list` is consulted on the next polling cycle.
- #206 — Rename terminals via the UI and via `crow rename-terminal`.
- #207 — `defaults.excludeReviewRepos` filters repos from the review board, badge counts, and notifications. Wildcards supported.
- #210 — Bulk delete for sessions in the sidebar.
- #212 — Multi-select + batch Start Review on the review board.
- #220 — Filtering for the tickets list.
- #226 — Per-section select all and icon-only cancel button in selection mode.
- #231 — Quick action buttons on the session detail header.
- #520 — PR-link reconcile no longer attaches the wrong PR when the worktree branch carries a repo-name prefix the PR head drops (`feature/max-monorepo-maxx-7035-…` vs `feature/maxx-7035-…`). The ticket key is derived from the worktree branch, key matching ignores body-only mentions, and a PR can attach to at most one session — a session whose ticket has no PR now gets none.

### Terminal Runtime

- #159 — Fix diagonal window resize and content-driven window growth.
- #161 — Fix batch "Work on" sending a malformed `/crow-batch-workspace` line.
- #218 — Recover from failed Ghostty surface creation by retrying.
- #229 — New tmux backend behind the `CROW_TMUX_BACKEND` feature flag (or Settings → Experimental). Off by default; opt in for a headless-PTY runtime that decouples terminal lifecycle from view rendering.
- #301 — The tmux backend is now the default for managed terminals. The Settings → Experimental tab and `AppConfig.experimentalTmuxBackend` key are gone; existing configs containing the key still load (the key is silently dropped on next save). Escape hatch: set `CROW_TMUX_BACKEND=0` (also `false`/`no`/`off`) to fall back to the legacy per-terminal Ghostty backend for a launch — the legacy path will be removed in a follow-up release.
- #303 — Removed the legacy per-terminal Ghostty backend and the `CROW_TMUX_BACKEND` escape hatch. tmux ≥ 3.3 is now required for managed terminals; without it, Crow shows the install alert and managed terminals don't render. `TerminalManager` is gone and `TerminalRouter` no longer branches on backend. Persisted terminals tagged `"backend":"ghostty"` migrate forward to tmux on load.

### GitLab

- #215 — Fix GitLab fetch failing when `GITLAB_HOST` did not match the workspace host; reconcile now silently skips GitLab candidates whose host can't be determined.
- #233 — Fix `glab` fetch failures from a non-repo cwd and slug truncation on nested groups (`big-bang/product/packages/elasticsearch-kibana` is no longer truncated to `big-bang/product`).

### Tooling & Misc

- #805 — `crow edit-link` updates a session link's label, URL, or type in place (`--id`/`--url` selects, `--new-url` sets the new URL, only provided fields change) so a mislabeled link can be corrected without a remove-then-add round trip. Also documents the pre-existing `crow remove-link`, which detaches a link by `--id` or `--url` — it was implemented but missing from the CLI reference, skill, and CLAUDE.md.
- #769 — `crowd` can start at login again (the gap ADR-0010 left when the macOS app was retired). `crow autostart install | uninstall | status` registers a launchd LaunchAgent — idempotent, re-points itself after an upgrade, and never bootstraps a duplicate over a running daemon. Same toggle at Settings → General → Autostart from a local browser. macOS only for now; Linux waits on #645.
- #152 — Replace dock icon with the Corveil Brandmark.
- #155 — Docs refresh: README, `make build` promotion, GitHub project scope wording.
- #162 — Silence noisy console logs from Ghostty and IssueTracker.
- #172 — Log `gh` stderr on IssueTracker shell failures.
- #175 — Consolidate IssueTracker `gh` calls into a single GraphQL query.
- #176 — Open-source readiness: license, code of conduct, CI, doc cleanup.
- #178 — CI warms the Ghostty cache on `main` so PRs share it.
- #180 — Fix IssueTracker duplicate-key crash on PR status refresh.
- #185 — Replace the Corveil Brandmark PNG with an SVG for crisper rendering.
- #208 — Ignore subagent hook events fired after a turn's `Stop` so the sidebar dot doesn't get stuck "working".
- #234 — `crow hook-event` is a silent no-op when the Crow app is not running, so non-Crow `claude` sessions don't log noise.

## [0.1.0] - 2025-04-05

Initial open-source release of Crow.

### Added

- Native macOS application with ticket board, terminal management, and GitHub integration
- Embedded Ghostty terminal with multi-tab support per session
- Session-based workflow management (create, pause, resume, archive)
- Git worktree management with orphan worktree recovery
- GitHub integration with PR status tracking and project board sync
- "In Review" button to update GitHub Project status from the app
- Claude Code hook event system for automatic session activity tracking
- Notification system with configurable sounds and macOS notifications
- "Open in VS Code" and "Open Terminal" buttons for session worktrees
- CLI tool (`crow`) for session, terminal, and metadata management via Unix socket RPC
- `crow setup` command for first-time configuration
- Makefile for build automation (`make build`, `make release`)
- Corveil branding with styled About page showing git commit SHA
- Configurable sidebar with option to hide subtitle lines
- Ticket page redesign with search, sort, and done state filtering
- Claude Code allow list aggregation and promotion across worktrees
- Comprehensive README with setup guide, architecture docs, and CLI reference
- Contributing guide, issue templates, and PR template
- Security audit and open-source readiness documentation

### Fixed

- Ghostty terminal mouse position offset
- UI blocking during GitHub polling and terminal resize on display change
- Merged PR status not detected on app restart
- Crash when reopening About or Settings window
- Disconnected hooks for CLI-created sessions
