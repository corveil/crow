# Getting Started

This guide walks you from a fresh clone to a running Crow app with GitHub (or GitLab) authentication and a scaffolded workspace.

## 1. Clone the Repository

```bash
git clone --recurse-submodules https://github.com/radiusmethod/crow.git
cd crow
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init vendor/ghostty
```

## 2. Build

The one-shot build path uses the Makefile:

```bash
make build
```

This runs `setup` (initializes submodules and checks prerequisites), `ghostty` (builds the `GhosttyKit` XCFramework with Zig), and `app` (runs `swift build`). The result is two binaries in `.build/debug/`:

- `CrowApp` — the main macOS application
- `crow` — the CLI used by Claude Code sessions

### Makefile Targets

| Target       | Purpose                                                                       |
| ------------ | ----------------------------------------------------------------------------- |
| `build`      | Full build: submodules + ghostty + `swift build` (default)                    |
| `setup`      | Init submodules and verify build prerequisites (Zig 0.15.2, Metal toolchain)  |
| `check`      | Verify all build and runtime prerequisites (includes `gh`, `claude`)          |
| `ghostty`    | Build the `GhosttyKit.xcframework` only                                       |
| `app`        | Run `swift build` (debug) without touching ghostty                            |
| `release`    | Release build + `.app` bundle via `scripts/bundle.sh`                         |
| `sign`       | Sign, create DMG, and notarize (requires `DEVELOPER_ID_APPLICATION`)          |
| `install`    | Symlink `crow` + `CrowApp` into `~/.local/bin` (override `BINDIR=`, `CONFIG=`) |
| `install-app`| Copy `Crow.app` into `/Applications` (run `make release` first)               |
| `uninstall`  | Remove the `crow` + `CrowApp` symlinks created by `install`                   |
| `test`       | Run all package tests                                                         |
| `clean`      | Remove `.build/` (keeps the ghostty framework)                                |
| `clean-all`  | Remove `.build/` and `Frameworks/` (full rebuild)                             |
| `help`       | Print the target list                                                         |

### Advanced / Manual Build

If you need finer-grained control, you can run the individual steps that `make build` orchestrates:

```bash
# Build the Ghostty framework only (writes Frameworks/GhosttyKit.xcframework)
./scripts/build-ghostty.sh

# Debug build
swift build

# Release build
swift build -c release

# Create the .app bundle from a release build
./scripts/bundle.sh

# Sign and notarize the bundled .app
./scripts/sign-and-notarize.sh
```

**Build troubleshooting:**

- Check Zig: `zig version` must show `0.15.2`
- Check Metal toolchain: `xcrun -sdk macosx metal --version`
- Install the Metal toolchain if missing: `xcodebuild -downloadComponent MetalToolchain`
- If `swift build` fails with linker errors, run `./scripts/build-ghostty.sh` first (or just `make build`)

### Using mise (Optional)

If you have [`mise`](https://mise.jdx.dev) installed, the predefined tasks in `mise.toml` wrap the same operations:

| Task                  | Runs                                       |
| --------------------- | ------------------------------------------ |
| `mise dev`            | `swift run CrowApp`                        |
| `mise build`          | `make build` (full build)                  |
| `mise build:release`  | `swift build -c release`                   |
| `mise build:ghostty`  | `bash scripts/build-ghostty.sh`            |
| `mise test`           | `swift test`                               |
| `mise bundle`         | `bash scripts/bundle.sh`                   |
| `mise sign`           | Depends on `bundle`, then sign + notarize  |
| `mise clean`          | `rm -rf .build .derived-data Crow.app`     |
| `mise xcode:generate` | `swift package generate-xcodeproj`         |

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

> **Important:** `read:project` is **not** sufficient. The in-code error messages will tell you to run `gh auth refresh -s project` — this is the write `project` scope, which is a superset of `read:project`. See `Sources/Crow/App/IssueTracker.swift:691-692` and `:768-769`.
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

## 5. First Launch

```bash
.build/debug/CrowApp
```

On first launch, the setup wizard asks for:

1. A **development root** directory (e.g. `~/Dev`) — where Crow scaffolds workspaces and stores worktrees.
2. One or more **workspaces** — each is a subdirectory under the dev root with a name, provider (`github` or `gitlab`), and (for GitLab) a host.

When you finish the wizard, Crow scaffolds the following under the dev root (see `Sources/Crow/App/Scaffolder.swift`):

```
{devRoot}/
├── {workspace}/                      # one directory per workspace
├── crow-reviews/                     # temporary clones for PR reviews
└── .claude/
    ├── CLAUDE.md                     # manager-tab context (crow CLI reference)
    ├── settings.json                 # pre-approved permissions for crow/gh/git
    ├── config.json                   # workspace config (workspaces + defaults)
    ├── prompts/                      # prompt files for crow-workspace sessions
    └── skills/
        ├── crow-workspace/           # /crow-workspace skill + setup.sh
        ├── crow-review-pr/           # /crow-review-pr skill
        └── crow-batch-workspace/     # /crow-batch-workspace skill
```

Alternatively, you can scaffold without launching the GUI by running the CLI setup wizard:

```bash
.build/debug/crow setup            # prompts interactively
.build/debug/crow setup --dev-root ~/Dev   # skip the devRoot prompt
```

## 6. Install (Optional)

Running the binaries by full path (`.build/debug/CrowApp`, `.build/debug/crow`) works, but the Manager terminal and the `/crow-workspace` skill invoke bare `crow ...` — so for day-to-day use you'll want `crow` (and optionally `CrowApp`) on your `PATH`.

### Put the binaries on PATH

```bash
make install
```

This symlinks both binaries into `~/.local/bin`:

- `~/.local/bin/crow` → `.build/debug/crow`
- `~/.local/bin/CrowApp` → `.build/debug/CrowApp`

If `~/.local/bin` isn't on your `PATH`, `make install` prints a reminder. Add this to your shell rc (e.g. `~/.zshrc`) and restart the shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**Overrides:**

| Variable  | Default          | Example                                  |
| --------- | ---------------- | ---------------------------------------- |
| `BINDIR`  | `~/.local/bin`   | `make install BINDIR=/usr/local/bin`     |
| `CONFIG`  | `debug`          | `make install CONFIG=release`            |

`CONFIG` selects which build directory the symlinks point at — `.build/debug/` (from `make build`) or `.build/release/` (from `make release`). If the chosen binaries don't exist yet, `make install` errors and tells you to build first.

### Rebuilds and re-pointing

Because `install` creates **symlinks** (not copies), `swift build` overwrites the underlying `.build/debug/` binaries in place and the symlinks keep working — no need to re-run `make install` after a normal `make build`.

Re-run `make install` only when:

- You switch debug ↔ release: `make release && make install CONFIG=release`.
- You ran `make clean` (or `mise clean`), which deletes `.build/` and leaves the symlinks dangling until the next build.

Remove the symlinks at any time:

```bash
make uninstall
```

### GUI install (`/Applications`)

For a proper `.app` bundle you can launch from Spotlight or the Dock:

```bash
make release        # produces ./Crow.app
make install-app    # copies Crow.app into /Applications
```

Builds from source are unsigned. If macOS quarantines the bundle on first launch, clear the attribute:

```bash
xattr -cr /Applications/Crow.app
```

Official signed/notarized builds are available on the [Releases](https://github.com/radiusmethod/crow/releases) page and install without Gatekeeper warnings.

## Next Steps

- [CLI reference](cli-reference.md) — every `crow` subcommand and its flags
- [Configuration](configuration.md) — file locations, workspace config schema, directory layout
- [Automation](automation.md) — Settings → Automation toggles for auto-create, auto-respond, and the rest of the auto-flow
- [Architecture](architecture.md) — packages, key components, data flow
- [Troubleshooting](troubleshooting.md) — common errors and fixes
