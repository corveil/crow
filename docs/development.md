# Development

How to work on Crow itself: the dev loops for `crowd`, the web UI and the desktop shell, adding a package, and running tests. For building and running Crow as a user, see the [README](../README.md) and [Getting Started](getting-started.md). For contribution guidelines, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Daemon and web UI

`make daemon-run` runs `crowd` serving the frozen web UI baked into the compiled bundle — the same asset source as `make run`. Web UI edits (`index.html`/`app.css`/the classic client scripts) need a rebuild to be picked up:

```bash
make daemon-run                      # stable daemon at http://127.0.0.1:8787
bash scripts/daemon-run.sh --watch   # ...and rebuild + restart crowd on Swift or web-asset changes
```

`--watch` restarts the daemon on every change (Swift can't hot-swap), so leave it off when you want a daemon that stays up across edits.

## Desktop shell (Tauri)

The desktop window lives in `crow-desktop/`; see its [README](../crow-desktop/README.md) for how it spawns or reuses `crowd` and how release bundling works.

```bash
make build     # crow CLI + crowd daemon (Swift) AND the Crow desktop app (Tauri)
make run       # build, then open the Crow window
```

Once built, the binary is self-contained — run it directly without `make`:

```bash
crow-desktop/src-tauri/target/debug/Crow
```

> **Toolchain note:** on Apple Silicon, a plain terminal can run under Rosetta (x86_64) and shadow the arm64 Rust with an old x86_64 one. `make app`/`make run` pin the Homebrew + rustup arm64 paths for you; if you invoke `cargo` or `npm` directly, prefix `PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH"`.

### Iterating with the window open

The `make run` window spawns `crowd` as a sidecar that serves the web UI from the compiled bundle (frozen assets), so web/UI edits need a `make daemon` rebuild to show up — the same asset source across every dev path. The rebuild re-copies the assets into the bundle and `crowd` reads them per request, so a plain ⌘R picks them up (no daemon restart needed for web-only edits; a Swift change does need a restart).

Run a standalone `crowd` separately only when you want a daemon that **outlives the window** or is shared by several clients (a browser tab + the window at once). Because the window reuses a crowd already on `:8787` and leaves it running on quit, they compose cleanly:

```bash
# Terminal 1 — a stable daemon, web served from the compiled bundle
make daemon-run

# Terminal 2 — the window attaches to it (reuses :8787, doesn't own its lifecycle)
make run          # or, once built: crow-desktop/src-tauri/target/debug/Crow
```

Quitting the window leaves your `crowd` running. `daemon-run --watch` rebuilds **and restarts** it on Swift *or* web-asset edits — the window keeps its `:8787` target, so just ⌘R once it's back up. (`--watch` always restarts; Swift can't hot-swap, and even a web edit tears the daemon down — the same reason the Tauri dev loop churns.) For a web-only tweak you can skip the churn: a **manual** `make daemon` against the already-running daemon just re-copies the assets, which it serves on the next ⌘R with no restart.

- `CROW_HTTP_PORT=NNNN` — match a crowd started on a non-default port so the window reuses it instead of spawning a second daemon on 8787 (which would contend on the same store + tmux cockpit).
- `CROWD_BIN=/path/to/crowd` — override which `crowd` binary the window spawns when none is already running.

### `npm run tauri dev` (editing the Tauri shell)

When you're changing the **desktop shell itself** (`crow-desktop/src-tauri/`), use Tauri's dev loop, which recompiles and relaunches the Rust on save. It needs Node 18+.

```bash
cd crow-desktop
PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH" npm run tauri dev
```

Handy for Rust/window work, but each relaunch re-runs the launch logic and tears down a `crowd` it spawned — so it churns the daemon. When you're iterating on `crowd` or the web UI (not the Rust shell), prefer plain `make run` (or the `make daemon-run` + `make run` split above).

## Adding a new package

1. Create the package under `Packages/`
2. Add it to the root `Package.swift` dependencies and target (or to a package that a root target already pulls in)
3. Import in the targets that need it

## Testing

```bash
make test     # or: swift test --package-path Packages/<name>
```

Tests use the [Swift Testing](https://developer.apple.com/documentation/testing/) framework (`@Test` macros). Test files live under `Packages/*/Tests/`. Tests must never touch live data — see [ADR 0012](adr/0012-tests-never-touch-live-data.md).

## Regenerating the CLI reference

[`cli.md`](cli.md) is generated from the commands themselves. After changing anything in `Packages/CrowCLI/Sources/CrowCLILib/Commands/`, run:

```bash
make docs
```

and update the hand-written [CLI guide](cli-reference.md) to match.
