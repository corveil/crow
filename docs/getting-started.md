# Getting Started

This guide walks you from a fresh clone to a running Crow daemon (`crowd`) with GitHub (or GitLab) authentication and a scaffolded workspace.

## 1. Clone the Repository

```bash
git clone https://github.com/corveil/crow.git
cd crow
```

## 2. Build

The one-shot build path uses the Makefile:

```bash
make build
```

This runs `setup` (checks Xcode Command Line Tools), generates the CLI version file, and `swift build`. The result is two binaries in `.build/debug/`:

- `crowd` — the daemon that serves the web UI and owns all state
- `crow` — the CLI used by Claude Code sessions

### Makefile Targets

| Target       | Purpose                                                                       |
| ------------ | ----------------------------------------------------------------------------- |
| `build`      | Full build: prerequisites + `swift build` — builds `crow` + `crowd` (default) |
| `setup`      | Verify build prerequisites (Xcode CLT)                                         |
| `check`      | Verify all build and runtime prerequisites (includes `gh`, `claude`, `tmux`)  |
| `crowd-dev`  | Hot-reload dev loop for `crowd` (web served live from source)                 |
| `install`    | Symlink `crow` + `crowd` into `~/.local/bin` (override `BINDIR=`, `CONFIG=`)   |
| `uninstall`  | Remove the `crow` + `crowd` symlinks created by `install`                      |
| `test`       | Run all package tests                                                          |
| `clean`      | Remove `.build/`                                                               |
| `help`       | Print the target list                                                          |

### Advanced / Manual Build

```bash
# Debug build
swift build

# Release build
swift build -c release

# Build just one product
swift build --product crowd
swift build --product crow
```

**Build troubleshooting:**

- Ensure Xcode CLT: `xcode-select -p`
- The `crow` CLI needs a generated `CLIVersion` file. Build via `make build` (which runs `scripts/generate-build-info.sh` first); a bare `swift build` from a clean tree can fail on the missing file. `crowd` has no such dependency.

## 3. GitHub Authentication

Crow uses the `gh` CLI to read issues, PRs, and GitHub Projects (V2) board status, and to **write** project board status (moving tickets to "In Progress" / "In Review") via the `updateProjectV2ItemFieldValue` GraphQL mutation.

```bash
gh auth login
gh auth refresh -s project,read:org,repo
gh auth status   # verify the scopes above are listed
```

### Required Scopes

| Scope          | Why it's needed                                                                                                                           | Used by                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `repo`         | Read/write issues, PRs, branches, commit statuses                                                                                         | `gh issue view/edit`, `gh pr view/create`, `gh search issues`                                   |
| `read:org`     | Resolve org membership so `@me` assignee queries work across org repos                                                                    | `gh search issues --assignee @me`                                                               |
| `project`      | **Read AND write** GitHub Projects V2 board status — required to update Status to "In Progress" / "In Review"                             | `IssueTracker.swift` `updateProjectStatus()`, the `/crow-workspace` skill when starting a session |

> **Important:** `read:project` is **not** sufficient. The in-code error messages will tell you to run `gh auth refresh -s project` — this is the write `project` scope, which is a superset of `read:project`. See `Packages/CrowEngine/Sources/CrowEngine/IssueTracker.swift`.
>
> If you see `[IssueTracker] GitHub token missing 'project' scope` in stderr or `INSUFFICIENT_SCOPES` from a GraphQL call, re-run `gh auth refresh -s project` and retry.

### Runtime CLI Permissions

Crow shells out to several CLIs at runtime. This table consolidates what each one needs:

| Tool     | Auth / Scopes                                                                          | Notes                                                                              |
| -------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `gh`     | `repo`, `read:org`, `project` (see above)                                              | Set via `gh auth login` and `gh auth refresh -s project,read:org,repo`             |
| `glab`   | `api`, `read_user`, `read_repository` (verify for your instance)                       | Only required for GitLab workspaces. Issue/MR reads. Write scopes needed if you expect MR status updates. |
| `git`    | Local only — no external auth                                                          | Ships with Xcode Command Line Tools                                                |
| `claude` | No network auth; binary must be on `PATH`                                              | Install from [claude.ai/download](https://claude.ai/download)                      |

## 4. GitLab Authentication (Optional)

If any of your workspaces use self-hosted GitLab:

```bash
glab auth login --hostname gitlab.example.com
```

Crow will invoke `glab` with `GITLAB_HOST` set from the workspace config. The app does not enforce specific scopes on the GitLab token; check your instance's documentation for what your user account needs.

## 5. First Run

Configure your development root and workspaces with the CLI setup wizard, then start the daemon:

```bash
.build/debug/crow setup            # prompts interactively
.build/debug/crow setup --dev-root ~/Dev   # skip the devRoot prompt

.build/debug/crowd                 # serves the web UI
```

`crowd` prints `HTTP/WS listening on http://127.0.0.1:8787` — open that URL in your browser. (For a hot-reload dev loop with web assets served live from source, use `make crowd-dev` instead.)

The setup wizard asks for:

1. A **development root** directory (e.g. `~/Dev`) — where Crow scaffolds workspaces and stores worktrees.
2. One or more **workspaces** — each is a subdirectory under the dev root with a name, provider (`github` or `gitlab`), and (for GitLab) a host.

Crow scaffolds the following under the dev root (see `Packages/CrowEngine/Sources/CrowEngine/Scaffolder.swift`):

```
{devRoot}/
├── {workspace}/                      # one directory per workspace
├── crow-reviews/                     # temporary clones for PR reviews
└── .claude/
    ├── CLAUDE.md                     # manager-tab context (crow CLI reference)
    ├── settings.local.json           # pre-approved permissions for crow/gh/git (settings.json is yours — untouched)
    ├── config.json                   # workspace config (workspaces + defaults)
    ├── prompts/                      # prompt files for crow-workspace sessions
    └── skills/
        ├── crow-workspace/           # /crow-workspace skill + setup.sh
        ├── crow-review-pr/           # /crow-review-pr skill
        └── crow-batch-workspace/     # /crow-batch-workspace skill
```

## 6. Install (Optional)

Running the binaries by full path (`.build/debug/crowd`, `.build/debug/crow`) works, but the Manager terminal and the `/crow-workspace` skill invoke bare `crow ...` — so for day-to-day use you'll want `crow` (and `crowd`) on your `PATH`.

### Put the binaries on PATH

```bash
make install
```

This symlinks both binaries into `~/.local/bin`:

- `~/.local/bin/crow` → `.build/debug/crow`
- `~/.local/bin/crowd` → `.build/debug/crowd`

If `~/.local/bin` isn't on your `PATH`, `make install` prints a reminder. Add this to your shell rc (e.g. `~/.zshrc`) and restart the shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**Overrides:**

| Variable  | Default          | Example                                  |
| --------- | ---------------- | ---------------------------------------- |
| `BINDIR`  | `~/.local/bin`   | `make install BINDIR=/usr/local/bin`     |
| `CONFIG`  | `debug`          | `make install CONFIG=release`            |

`CONFIG` selects which build directory the symlinks point at — `.build/debug/` (from `make build`) or `.build/release/` (from `make build CONFIG=release`). If the chosen binaries don't exist yet, `make install` errors and tells you to build first.

### Rebuilds and re-pointing

Because `install` creates **symlinks** (not copies), `swift build` overwrites the underlying `.build/debug/` binaries in place and the symlinks keep working — no need to re-run `make install` after a normal `make build`.

Re-run `make install` only when:

- You switch debug ↔ release: `make build CONFIG=release && make install CONFIG=release`.
- You ran `make clean`, which deletes `.build/` and leaves the symlinks dangling until the next build.

Remove the symlinks at any time:

```bash
make uninstall
```

### Running crowd as a background service

Register `crowd` to start at login, so Crow is up after a reboot with no manual command:

```bash
crow autostart install     # writes ~/Library/LaunchAgents/com.corveil.crowd.plist
crow autostart status      # enabled? running? add --json for scripts
crow autostart uninstall   # remove the login item
```

Install is idempotent, and re-running it after a rebuild re-points the login item at the current `crowd` — so an upgrade never leaves a stale plist behind. If a `crowd` is already running, install writes the login item and leaves the running daemon alone (it takes effect at next login) rather than starting a second one. The login-item daemon logs to `~/Library/Logs/crow/crowd.log`. The same toggle lives at Settings → General → Autostart, from a browser on the machine running `crowd`.

Pass the daemon's flags through if you don't run it on the defaults — `crow autostart install --host 0.0.0.0 --port 8080 --dev-root ~/Dev`. Those flags are baked into the login item, so a non-loopback `--host` re-binds beyond loopback on every login; `crowd` still logs its usual unauthenticated-bind warning, so only do this on a trusted network.

macOS only for now (launchd); on Linux, start `crowd` yourself or write a `systemd --user` unit until [#645](https://github.com/corveil/crow/issues/645) lands. `crowd` binds `127.0.0.1:8787` by default; see [Remote access](../README.md#remote-access) to reach it from another device.

## Next Steps

- [CLI reference](cli-reference.md) — every `crow` subcommand and its flags
- [Configuration](configuration.md) — file locations, workspace config schema, directory layout
- [Automation](automation.md) — Settings → Automation toggles for auto-create, auto-respond, and the rest of the auto-flow
- [Architecture](architecture.md) — packages, key components, data flow
- [Troubleshooting](troubleshooting.md) — common errors and fixes
