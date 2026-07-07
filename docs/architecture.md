# Architecture

Crow is a native macOS app that coordinates AI-assisted development sessions. Each session is a git worktree + a Claude Code terminal + ticket metadata, all tracked in a persistent store and surfaced in a SwiftUI sidebar. A CLI (`crow`) talks to the running app over a Unix socket so that Claude Code can create sessions programmatically.

## Repository Layout

```
crow/
├── Sources/
│   ├── Crow/                  # Main application target
│   │   ├── App/
│   │   │   ├── main.swift           # Entry point
│   │   │   ├── AppDelegate.swift    # Window, IPC server, startup
│   │   │   ├── SessionService.swift # Session CRUD, orphan detection
│   │   │   ├── IssueTracker.swift   # GitHub/GitLab polling (60s)
│   │   │   └── Scaffolder.swift     # First-run dev-root scaffold
│   │   └── Resources/
│   └── CrowCLI/               # crow CLI binary target
│       └── main.swift               # Thin executable that calls CrowCommand.main()
├── Packages/                  # SwiftPM library packages
│   ├── CrowCore/                    # Data models, AppState (observable)
│   ├── CrowCLI/                     # CLI command definitions (CrowCommand + subcommands)
│   ├── CrowClaude/                  # Claude binary resolution
│   ├── CrowGit/                     # Git operations
│   ├── CrowIPC/                     # Unix socket RPC protocol
│   ├── CrowPersistence/             # JSON store, config persistence
│   ├── CrowProvider/                # GitHub/GitLab provider abstraction
│   ├── CrowTerminal/                # xterm.js terminal surface management
│   └── CrowUI/                      # SwiftUI views, Corveil theme
├── scripts/                   # Build/packaging helpers (bundle.sh, sign-and-notarize.sh, …)
└── skills/                    # Bundled Claude Code skills (crow-workspace, etc.)
```

### About `Sources/CrowCLI` vs `Packages/CrowCLI`

There are two `CrowCLI` directories:

- **`Packages/CrowCLI/`** is a library package (`CrowCLILib`) that defines every subcommand as a `ParsableCommand` struct plus the `CrowCommand` root. This is where you add new commands or edit existing ones.
- **`Sources/CrowCLI/main.swift`** is a thin executable target that imports `CrowCLILib` and calls `CrowCommand.main()`. Keeping the command logic in a package lets tests in `Packages/CrowCLI/Tests/` exercise commands directly without building the executable.

## Key Components

| Component                 | Lives in                                           | Description                                                                                                       |
| ------------------------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| **AppDelegate**           | `Sources/Crow/App/AppDelegate.swift`               | Initializes the app, creates the main window, starts the IPC socket server and issue tracker                     |
| **SessionService**        | `Sources/Crow/App/SessionService.swift`            | CRUD for sessions/worktrees/terminals, terminal readiness tracking, orphan recovery on startup                    |
| **IssueTracker**          | `Sources/Crow/App/IssueTracker.swift`              | Polls GitHub/GitLab every 60 seconds for assigned issues, PR status, project board status, auto-completes merged sessions |
| **Scaffolder**            | `Sources/Crow/App/Scaffolder.swift`                | First-run devRoot scaffold: `.claude/` + bundled skills + settings.local.json (never touches the user's own settings.json)  |
| **TmuxBackend**           | `Packages/CrowTerminal/.../TmuxBackend.swift`      | The terminal backend (introduced in #229, defaulted on in #301, the only backend since #303). Owns the tmux server and the shared cockpit `XTermSurfaceView` that renders it |
| **TerminalRouter**        | `Sources/Crow/App/TerminalRouter.swift`            | Thin facade over `TmuxBackend` for per-terminal `send` / `destroy` / `trackReadiness` |
| **AutoRespondCoordinator**| `Sources/Crow/App/AutoRespondCoordinator.swift`    | Watches PR review / CI signals and types follow-up instructions into the linked Claude Code terminal (#214)       |
| **TerminalReadiness**     | `Packages/CrowCore/Sources/CrowCore/Models/Enums.swift:41` | Four-state enum (uninitialized → surfaceCreated → shellReady → claudeLaunched) driving the sidebar status dot |
| **SocketServer**          | `Packages/CrowIPC/`                                | Unix socket server at `~/.local/share/crow/crow.sock` — receives JSON-RPC commands from the `crow` CLI            |
| **CrowCommand**           | `Packages/CrowCLI/.../CrowCommand.swift`           | ArgumentParser root command registering every subcommand                                                          |
| **JSONStore**             | `Packages/CrowPersistence/`                        | NSLock-serialized JSON persistence for sessions, worktrees, links, terminals                                      |

## Data Flow

### Opening a session tab

```
User clicks session tab
  → SwiftUI renders TerminalSurfaceView
  → XTermSurfaceView.createSurface() spawns the shell (via PTYProcess)
  → TerminalManager transitions created → shellReady
  → TerminalReadiness: uninitialized → surfaceCreated → shellReady → claudeLaunched
  → Auto-sends `claude --continue` when shell becomes ready
  → Sidebar status dot turns green
```

### Creating a session from Manager

```
User invokes /crow-workspace in Manager tab
  → Claude Code runs crow CLI commands through the Unix socket
  → crow new-session → crow add-worktree → crow new-terminal --managed
  → App creates session, registers worktree, spawns managed terminal
  → User clicks the new session tab → Claude launches automatically
```

### Issue tracker polling

```
Every 60 seconds:
  → IssueTracker.fetchAssignedIssues (gh search issues --assignee @me)
  → IssueTracker.fetchPRStatus for linked PRs
  → IssueTracker.fetchGitHubProjectStatuses (GraphQL, needs read:project)
  → Auto-complete sessions whose PR is merged or issue is closed
```

### Moving a ticket to "In Progress" / "In Review"

```
User starts a session via /crow-workspace (or clicks "Mark In Review")
  → IssueTracker.markInReview builds a GraphQL query for the Status field
  → Calls updateProjectV2ItemFieldValue mutation
  → Requires the write `project` scope — NOT `read:project`
  → On INSUFFICIENT_SCOPES, logs a hint to run `gh auth refresh -s project`
```

See `Sources/Crow/App/IssueTracker.swift:636-774` for the full `markInReview` implementation.

## Terminal rendering

Crow renders each session's terminal with [xterm.js](https://xtermjs.org) hosted in a `WKWebView` (`XTermSurfaceView`), backed by a native PTY (`PTYProcess`) whose child command is `tmux attach-session`. The vendored xterm.js assets live under `Packages/CrowTerminal/Sources/CrowTerminal/Resources/xterm/`. The surface lifecycle lets Crow track when the shell is ready and auto-launch `claude --continue`. See [ADR 0006](adr/0006-universal-macos-binary.md) for why this replaced the earlier native terminal surface.

## Terminal Backends

PR #229 introduced a tmux backend behind a feature flag; #301 made it the default; #303 removed the legacy per-terminal path and made tmux the only backend. The Manager session runs on tmux like every other session (#324).

- **tmux** — a headless PTY plus a tmux server, driven by `TmuxBackend`. Each session terminal corresponds to a tmux window; rendering is decoupled from the window so terminals can spin up before any view is materialized. All visible tabs share a single embedded `XTermSurfaceView` (the "cockpit") whose child command is `tmux attach-session`, so xterm.js in WKWebView renders the shared surface. Requires `tmux ≥ 3.3` on `PATH` (`brew install tmux`).

Per-terminal dispatch happens in `Sources/Crow/App/TerminalRouter.swift`, a thin facade over `TmuxBackend`. `SessionTerminal` still carries a single-case `backend` discriminator (`.tmux`) so the persisted schema is stable and a future backend can be added without another migration.

If tmux is missing or too old, Crow surfaces an alert at launch with a `brew install tmux` hint; managed terminals do not render until tmux is installed.

The original motivation and full alternative analysis are in [terminal-runtime-research.md](terminal-runtime-research.md).

## Settings

PR #228 split Settings into discrete tabs. Each tab maps to a SwiftUI view in `Packages/CrowUI/Sources/CrowUI/`:

- **General** — devRoot, sidebar density, notifications, sounds.
- **Workspaces** — per-workspace provider, host, branch prefix, and per-workspace auto-review opt-in (#209).
- **Automation** — every automation toggle in one place. See [automation.md](automation.md) for a per-toggle walkthrough. Source: `AutomationSettingsView.swift`.
- **Notifications** — global mute + per-event sound and banner config.

Tab state is persisted in `{devRoot}/.claude/config.json` via `CrowPersistence`.

## Review Board

The review board is the surface for triaging PRs that have been queued for AI review. Recent PRs added these capabilities:

- **Exclude list** (#207) — repos in `defaults.excludeReviewRepos` are filtered from the board, badge counts, and notifications. Wildcards supported.
- **Auto-start** (#209) — per-workspace toggle that auto-creates a review session when a PR becomes reviewable.
- **PR link reconciliation** (#205) — sessions whose hook events missed a PR open are reconciled against `gh pr list` on the next polling cycle so the session detail surface still shows the correct PR.
- **Bulk delete** (#210) — sidebar selection mode that lets you remove multiple sessions at once.
- **Multi-select + batch Start Review** (#212) — review-board selection mode for kicking off several reviews in one click.
- **Filtering** (#220) — inline filter on the tickets list, mirrored across the review board.
- **Per-section select all + icon-only cancel** (#226) — UX polish on selection mode.
- **Quick action buttons on session detail header** (#231) — surface the most-used session actions (open PR, mark in review, copy branch) directly on the detail view.
- **Move to Active** (#188) — return a completed session to active without deleting it.
