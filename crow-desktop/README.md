# Crow — desktop wrapper (Tauri)

A thin native macOS shell around the Crow web UI, built with **Tauri v2**. On
launch it starts the `crowd` daemon as a **sidecar**, waits for it, and points
the window at its web UI; `crowd` stays the sole authority
(see [ADR 0009](../docs/adr/0009-crowd-sole-authority-clients-only.md) /
[ADR 0010](../docs/adr/0010-retire-the-macos-app.md)). There is **no bundled
frontend** — the UI is served by `crowd`, not this project.

## Run

From the repo root the `Makefile` drives everything (see the main
[README → Desktop app](../README.md#desktop-app-native-window-over-crowd)):

```bash
make run        # build crowd + this app, then open the Crow window
```

Or run the prebuilt binary directly (equivalent to the old
`./.build/debug/CrowApp`):

```bash
make app                                    # debug: cargo build → crow-desktop/src-tauri/target/debug/Crow
crow-desktop/src-tauri/target/debug/Crow    # then launch it

make app CONFIG=release                     # tauri build → release-app/Crow.app
open release-app/Crow.app
```

First launch compiles the Rust (~30s), then a **"Crow"** window opens. You do
**not** need to start `crowd` yourself:

- If a `crowd` is already listening on `127.0.0.1:8787`, the app reuses it and
  leaves it running when you quit (great for iterating on a `make daemon-run`
  daemon in another terminal).
- Otherwise it spawns `.build/debug/crowd` (splash → UI once it's up) and stops
  that `crowd` when you quit.

Override the crowd binary with `CROWD_BIN=/path/to/crowd`; match a custom-port
daemon with `CROW_HTTP_PORT=NNNN`.

### Editing this shell (`npm run tauri dev`)

When you're changing the Rust/Tauri code here, use Tauri's dev loop, which
recompiles and relaunches on save:

```bash
PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH" npm run tauri dev
```

The PATH pin is required: the dev shell can run under Rosetta (x86_64) and would
otherwise grab an old x86_64 Rust; this uses the arm64 Homebrew/rustup toolchain.
Because each relaunch re-runs the launch logic (and kills a `crowd` it spawned),
this churns the daemon — for iterating on `crowd` or the web UI, prefer
`make daemon-run` + `make run` instead.

## How it works

- `src-tauri/src/lib.rs` — spawns (or reuses) `crowd`, waits on the port,
  navigates the window to it, and kills the spawned child on `RunEvent::Exit`.
- `ui/index.html` — the "Starting crowd…" splash shown until `crowd` is up
  (`tauri.conf.json` `frontendDist` points here).
- Dev: the crowd binary is resolved relative to the crate
  (`../../.build/debug/crowd`). Override with `CROWD_BIN`.
- **Release:** `make app CONFIG=release` runs `tauri build` with
  `bundle.externalBin` (`crowd` + `crow` sidecars) and copies SwiftPM
  `.bundle` resources into `Contents/Resources`. The window is
  `release-app/Crow.app`.

## Roadmap

1. Native **menu + notifications** (`tauri-plugin-notification`).
2. **`open_in_editor` / `open_terminal`** Rust commands exposed to the web UI via
   a `window.__TAURI__` shim — closes the deferred host-affordance gap.
