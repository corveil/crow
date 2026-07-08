# Crow

Crow manages AI-powered development sessions. It runs as a background daemon (`crowd`) with a **browser-based UI**, orchestrating git worktrees, Claude Code instances, and GitHub/GitLab/Jira issue tracking. Each session pairs a git worktree, a tmux-backed Claude Code terminal (streamed to xterm.js in your browser), and ticket metadata — all tracked in a persistent store.

> **Note:** Crow began as a native macOS (AppKit) app. As of [ADR 0007](docs/adr/0007-crowd-sole-authority-clients-only.md) and [ADR 0008](docs/adr/0008-retire-the-macos-app.md), that app was **retired**: `crowd` is the sole authority and every UI is a pure client. The browser is the primary UI; an optional thin **[desktop window](#desktop-app-native-window-over-crowd)** (Tauri) over the same web UI is available if you prefer a native window. The daemon still runs on a macOS host because it drives `git`, `tmux`, and Claude Code locally.

## Architecture at a glance

```mermaid
flowchart TB
    subgraph clients["Clients (pure, no privileged state)"]
        WEB["Web browser<br/>web UI + xterm.js"]
        DESKTOP["Desktop app (Tauri)<br/>native window over the web UI"]
        CLI["crow CLI"]
    end

    subgraph daemon["crowd — the sole authority"]
        HTTP["HTTP + WebSocket server<br/>/rpc · /terminal · web + login"]
        ENGINE["CrowEngine<br/>SessionService · spawn / lifecycle"]
        BOARDS["IssueTracker · AllowListService<br/>JobScheduler · auto-respond / -review"]
        HUB["EventHub — server push"]
        STORE[("store.json")]
    end

    subgraph host["Host + backends"]
        TMUX["tmux cockpit"]
        AGENTS["Coding agents<br/>Claude Code · OpenCode · Cursor · Codex"]
        GIT["git worktrees"]
        PROV["GitHub · GitLab · Jira · Corveil"]
    end

    WEB -- "WebSocket: /rpc + /terminal" --> HTTP
    DESKTOP -- "WebSocket: /rpc + /terminal" --> HTTP
    CLI -- "Unix socket JSON-RPC" --> ENGINE
    HTTP --> ENGINE
    ENGINE --> STORE
    ENGINE --> TMUX
    ENGINE --> GIT
    TMUX --> AGENTS
    ENGINE --> BOARDS
    BOARDS --> PROV
    BOARDS --> HUB
    HUB -. "push: changed" .-> WEB
    HUB -. "push: changed" .-> DESKTOP
```

`crowd` is the single source of truth — the only store writer, the only spawner, and the owner of terminal + agent lifecycle. Every UI is a **pure client**: it subscribes to `crowd`'s state over the `/rpc` + `/terminal` WebSocket surface, sends JSON-RPC, and renders. Multiple clients (browser tabs, the desktop window, the `crow` CLI, any future UI) attach to one running system at once. Full detail in [docs/architecture.md](docs/architecture.md).

## Prerequisites

### System Requirements

`crowd` is the only process you run, and it drives `git`, `tmux`, and the coding agents on the host — so it needs a Unix-like host:

- **macOS 14.0+** (Sonoma or later), or **Linux** (x86_64 or arm64)
- A **Swift 6 toolchain** — bundled with Xcode Command Line Tools on macOS, or installed from [swift.org/install](https://www.swift.org/install/) on Linux
- A modern **web browser** for the UI

> The optional native [desktop app](#desktop-app-native-window-over-crowd) (Tauri) is macOS-only today; on Linux, use the browser UI. On Linux the terminal is streamed to the browser over a WebSocket (the macOS-native terminal surface compiles away).

### Build Dependencies

| Tool  | Version | Purpose                     | Install                  |
| ----- | ------- | --------------------------- | ------------------------ |
| Swift | 6.0+    | Compiler — Xcode CLT (macOS) or the swift.org toolchain (Linux) | `xcode-select --install` · [swift.org/install](https://www.swift.org/install/) |
| mise  | latest  | Task runner (optional)      | `brew install mise`      |
| Rust  | 1.77+ (arm64) | Compiler for the optional [desktop app](#desktop-app-native-window-over-crowd) (macOS) | [rustup.rs](https://rustup.rs) |
| Node  | 18+     | Only for `npm run tauri dev` (optional) | `brew install node`      |

### Runtime Dependencies

| Tool     | Purpose                                                       | Install                                               |
| -------- | ------------------------------------------------------------- | ----------------------------------------------------- |
| `gh`     | GitHub CLI — issue tracking, PR status, project boards        | `brew install gh`                                     |
| `git`    | Worktree management                                           | Ships with Xcode CLT                                  |
| `claude` | Claude Code — AI coding assistant                             | [claude.ai/download](https://claude.ai/download)      |
| `tmux`   | Terminal backend for managed sessions (≥ 3.3)                 | `brew install tmux`                                   |
| `glab`   | GitLab CLI (optional, for GitLab repos)                       | `brew install glab`                                   |
| `acli`   | Atlassian CLI (optional, for Jira task tracking)              | [developer.atlassian.com/cloud/acli](https://developer.atlassian.com/cloud/acli/guides/install-acli/) |

> Install commands above are macOS/Homebrew; on Linux use your distribution's package manager (e.g. `apt install git tmux`; `gh`/`glab` have their own apt repos). `git` ships with Xcode CLT on macOS. `claude` is the default coding agent — **OpenCode**, **Cursor**, and **Codex** are also supported and selectable per session (Settings → Automation); install whichever agents you use.

## Quick Start

```bash
# 1. Clone
git clone https://github.com/radiusmethod/crow.git
cd crow

# 2. Build the `crow` CLI and the `crowd` daemon (Swift toolchain only).
#    `make build` also builds the optional native desktop app — see "Desktop app" below.
make daemon

# 3. Authenticate GitHub CLI — the write `project` scope is required
gh auth login
gh auth refresh -s project,read:org,repo

# 4. Configure your development root + workspaces
.build/debug/crow setup

# 5. Run the daemon — it serves the web UI
.build/debug/crowd
```

`crowd` prints `HTTP/WS listening on http://127.0.0.1:8787` on startup — open that URL in your browser. The first screen guides you through any remaining setup.

For local daemon development, `make crowd-dev` runs `crowd` with the web UI served live from source — edit `index.html`/`app.css`/`app.js` and just refresh:

```bash
make crowd-dev                      # stable daemon at http://127.0.0.1:8787
bash scripts/crowd-dev.sh --watch   # ...and rebuild + restart crowd on Swift changes
```

`--watch` restarts the daemon on every change (Swift can't hot-swap), so leave it off when you want a daemon that stays up across edits.

> **Note:** The required GitHub scope is the **write** `project` scope — `read:project` is insufficient because Crow updates ticket status via the `updateProjectV2ItemFieldValue` GraphQL mutation. See [docs/getting-started.md](docs/getting-started.md#3-github-authentication) for details.

### Install (put `crow` + `crowd` on your PATH)

The Manager terminal and the `/crow-workspace` skill call bare `crow ...`, so a build you can only launch by full path will break those workflows. Install the binaries so they're invokable from anywhere:

```bash
make install                       # symlinks crow + crowd into ~/.local/bin
```

If `~/.local/bin` isn't already on your `PATH`, add this to `~/.zshrc` (then restart your shell):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Use a different directory with `BINDIR`, e.g. `make install BINDIR=/usr/local/bin`.

`make install` creates **symlinks** into `.build/debug/`, so a later `make build` updates them in place — no need to re-run it. Re-run `make install` only when you switch to a release build (`make build CONFIG=release && make install CONFIG=release`) or after `make clean` (which removes `.build/` and leaves the symlinks dangling until the next build). Remove the symlinks with `make uninstall`.

### Remote access

`crowd` binds `127.0.0.1:8787` by default, so it's reachable only from the machine it runs on. To reach it from another device, front it with an HTTPS reverse proxy (e.g. [`tailscale serve`](https://tailscale.com/kb/1242/tailscale-serve)) and set a **web password** under **Settings → Web Access**. Non-loopback requests are blocked until a password is set and the connection is HTTPS (CROW-593).

## Desktop app (native window over crowd)

Prefer a native window to a browser tab? `crow-desktop/` is a thin **Tauri** shell that opens a "Crow" window pointed at the same web UI. It doesn't reimplement anything — `crowd` stays the sole authority; the window is just another pure client. Requires the **Rust arm64 toolchain** (see [Build Dependencies](#build-dependencies)).

```bash
make build     # crow CLI + crowd daemon (Swift) AND the Crow desktop app (Tauri)
make run       # build, then open the Crow window
```

`make run` is the modern equivalent of the old `make && ./.build/debug/CrowApp`. On launch the window looks for a `crowd` already listening on `127.0.0.1:8787`:

- **Found** (and it identifies as crowd) → it **reuses** that daemon and leaves it running when you quit the window.
- **None** → it spawns its own `crowd` from `.build/debug/crowd` and stops that one on quit.

Once built, the binary is self-contained — run it directly without `make`:

```bash
crow-desktop/src-tauri/target/debug/Crow
```

> **Toolchain note:** a plain terminal can run under Rosetta (x86_64) and shadow the arm64 Rust with an old x86_64 one. `make app`/`make run` pin the Homebrew + rustup arm64 paths for you; if you invoke `cargo` or `npm` directly, prefix `PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"`.

### Iterating with the window open

The `make run` window already spawns `crowd` as a sidecar that serves the web UI **live from source**, so for most web/UI work you don't need anything else — edit `index.html`/`app.css`/`app.js` and hit **⌘R** (View → Reload).

Run a standalone `crowd` separately only when you want a daemon that **outlives the window** or is shared by several clients (a browser tab + the window at once). Because the window reuses a crowd already on `:8787` and leaves it running on quit, they compose cleanly:

```bash
# Terminal 1 — a stable daemon, web served live from source
make crowd-dev

# Terminal 2 — the window attaches to it (reuses :8787, doesn't own its lifecycle)
make run          # or, once built: crow-desktop/src-tauri/target/debug/Crow
```

Quitting the window leaves your `crowd` running. Rebuilding the daemon (`crowd-dev --watch`, or a manual `make daemon` + restart) restarts it — the window keeps its `:8787` target, so just ⌘R once it's back up. Swift can't hot-swap, so any daemon rebuild is a restart; there's no way around that (it's the same reason the Tauri dev loop churns).

- `CROW_HTTP_PORT=NNNN` — match a crowd started on a non-default port so the window reuses it instead of spawning a second daemon on 8787 (which would contend on the same store + tmux cockpit).
- `CROWD_BIN=/path/to/crowd` — override which `crowd` binary the window spawns when none is already running.

### `npm run tauri dev` (editing the Tauri shell)

When you're changing the **desktop shell itself** (`crow-desktop/src-tauri/`), use Tauri's dev loop, which recompiles and relaunches the Rust on save:

```bash
cd crow-desktop
PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH" npm run tauri dev
```

Handy for Rust/window work, but each relaunch re-runs the launch logic and tears down a `crowd` it spawned — so it churns the daemon. When you're iterating on `crowd` or the web UI (not the Rust shell), prefer plain `make run` (or the `make crowd-dev` + `make run` split above).

## Documentation

- [**Getting Started**](docs/getting-started.md) — Clone, build, authenticate, and run
- [**CLI Reference**](docs/cli-reference.md) — Every `crow` subcommand and its flags
- [**Architecture**](docs/architecture.md) — Packages, key components, data flow
- [**Configuration**](docs/configuration.md) — File locations, workspace config, directory layout, session lifecycle
- [**Automation**](docs/automation.md) — Auto-create, auto-respond, auto-complete, and the Settings → Automation tab
- [**Troubleshooting**](docs/troubleshooting.md) — Build and runtime errors

## Usage

### The Web UI

The left rail groups your work:

- **Tickets** — Assigned issues grouped by project board status (Backlog, Ready, In Progress, In Review, Done in last 24h). Click a status to filter.
- **Manager** — A persistent Claude Code terminal for orchestrating work. Use `/crow-workspace` here to create new sessions. Launches in `--permission-mode auto` by default so orchestration commands (`crow`, `gh`, `git`) run without per-call approval; opt out via Settings → Automation → Manager Terminal.
- **Active Sessions** — One per work context. Shows repo, branch, issue/PR badges with pipeline and review status.
- **Completed Sessions** — Sessions whose PRs have been merged or issues closed.

Right-click a session (or **long-press** / tap the **⋮** button on touch devices) for its actions — rename, delete, copy links, and more.

### Creating a Session

In the Manager tab, tell Claude Code what you want to work on:

```
/crow-workspace https://github.com/org/repo/issues/123
```

Or use natural language:

```
/crow-workspace "add authentication to the acme-api API"
```

This will:

1. Create a git worktree with a feature branch
2. Create a session with ticket metadata
3. Launch Claude Code in plan mode with the issue context
4. Auto-assign the issue and set its project status to "In Progress"

## Features

### Ticket Board

- Pipeline view showing issues by project board status
- Click a status to filter the list
- "Start Working" button creates a workspace directly from an issue
- Issues linked to active sessions show a navigation button

### Jira tasks + GitHub code (cross-backend workspaces)

Per [ADR 0005](docs/adr/0005-task-and-code-backend-protocols.md), a workspace's
**Task Backend** (where tickets live) is chosen independently of its **Code
Backend** (where code + PRs live). You can track work in **Jira** while keeping
code and pull requests on **GitHub** — the task side runs through `acli`, the PR
side still runs through `gh`.

**Prerequisite — authenticate `acli`:**

```bash
# Install: https://developer.atlassian.com/cloud/acli/guides/install-acli/
acli jira auth login
acli jira auth status   # should print "✓ Authenticated"
```

**Configure a Jira-task / GitHub-code workspace** (Settings → Workspaces → edit a
workspace):

- **Code Backend** → `GitHub` (code + PRs stay on GitHub).
- **Task Backend** → `Jira` (offered only when `acli` is installed + authenticated;
  an inline hint tells you the fix when it isn't).
- **Atlassian Site** (e.g. `acme.atlassian.net`) — used to build `…/browse/KEY` links.
- **Project Key** (e.g. `PROJ`) — default project for created tickets.
- **My-tickets JQL** (optional) — defaults to
  `assignee = currentUser() AND statusCategory != Done`.

Settings persist to the workspace entry (`~/.claude/workspace-repos.json` keys:
`taskProvider`, `jiraProjectKey`, `jiraJQL`, `jiraSite`). Existing GitHub/GitLab
workspaces are unaffected — when no Task Backend is set, it follows the Code
Backend (GitHub code ⇒ GitHub issues, as before).

### PR Status Tracking

- Pipeline checks (passing/failing/pending)
- Review status (approved/changes requested/needs review)
- Merge readiness (mergeable/conflicting/merged)
- Purple badge with checkmark for merged PRs

### Auto-Complete

- Sessions automatically move to "Completed" when their linked PR is merged or issue is closed
- Checked every 60 seconds during the issue polling cycle
- Requires positive evidence the session was worked, so an unrelated PR merge can't flip an idle session

### Automation Suite

Crow can drive a ticket from assignment to merged with minimal manual steps. Toggles live under **Settings → Automation**; full walkthrough in [docs/automation.md](docs/automation.md).

- **Auto-create workspace** when an issue assigned to you is labeled `crow:auto`
- **Auto-suggest opening a PR** if a session completes with no PR linked
- **Auto-start review sessions** for opted-in workspaces when a PR becomes reviewable
- **Auto-respond** to changes-requested reviews and failed CI checks (off by default)
- **Auto-merge** Crow-authored PRs labeled `crow:merge` via `gh pr merge --auto --squash` (off by default; only acts on PRs whose commits carry a `Crow-Session:` trailer matching a known session). Crow lazily creates the `crow:merge` label on first observation; to pre-seed it manually: `gh label create crow:merge --color 0E8A16 --description "Crow: enable auto-merge once mergeable"`

### Review Board

- Multi-select with batch Start Review
- Bulk delete sessions
- Filter projects out via `excludeReviewRepos`
- Quick action buttons on the session detail header (open PR, mark in review, copy branch)
- Move completed sessions back to active

### Terminals

- xterm.js terminal surface in the browser, streamed from tmux over a WebSocket (`/terminal`)
- tmux-backed managed terminals — each session is a tmux window on a shared server (the "cockpit"), so per-session shells stay alive across UI navigation and across browser reconnects. Requires `tmux ≥ 3.3` (`brew install tmux`); without it, managed terminals don't render. See [docs/architecture.md#terminal-backends](docs/architecture.md#terminal-backends).
- Rename tabs from the UI or via `crow rename-terminal`

### Orphan Recovery

- On startup, scans git worktrees across all repos
- Worktrees not tracked in the store are automatically recovered as sessions
- Fetches ticket metadata and PR links from GitHub for recovered sessions

### Safe Deletion

- Deleting a session on a protected branch (main, master, develop) only removes the session metadata — the repo folder and branch are preserved
- The delete confirmation dialog reflects this, showing "Remove Session" instead of "Delete Everything"

## Development

### Adding a New Package

1. Create the package under `Packages/`
2. Add it to the root `Package.swift` dependencies and target (or to a package that a root target already pulls in)
3. Import in the targets that need it

### Testing

```bash
make test     # or: swift test --package-path Packages/<name>, or: mise test
```

Tests use the [Swift Testing](https://developer.apple.com/documentation/testing/) framework (`@Test` macros). Test files live under `Packages/*/Tests/`.

## Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on reporting bugs, suggesting features, and submitting pull requests.

## License

Apache 2.0 — see [LICENSE](LICENSE) for details.
