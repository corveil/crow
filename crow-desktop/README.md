# Crow — desktop wrapper (Tauri)

A thin native macOS shell around the Crow web UI, built with **Tauri v2**. On
launch it starts the `crowd` daemon as a **sidecar**, waits for it, and points
the window at its web UI; `crowd` stays the sole authority
(see [ADR 0007](../docs/adr/0007-crowd-sole-authority-clients-only.md) /
[ADR 0008](../docs/adr/0008-retire-the-macos-app.md)). There is **no bundled
frontend** — the UI is served by `crowd`, not this project.

## Run

```bash
PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH" npm run tauri dev
```

The PATH pin is required: the dev shell runs under Rosetta (x86_64) and would
otherwise grab an old x86_64 Rust; this uses the arm64 Homebrew toolchain.

First launch compiles the Rust (~30s), then a **"Crow"** window opens. You do
**not** need to start `crowd` yourself:

- If a `crowd` is already listening on `127.0.0.1:8787`, the app reuses it.
- Otherwise it spawns `.build/debug/crowd` (splash → UI once it's up) and kills
  that `crowd` when you quit.

Override the crowd binary with `CROWD_BIN=/path/to/crowd`.

## How it works

- `src-tauri/src/lib.rs` — spawns (or reuses) `crowd`, waits on the port,
  navigates the window to it, and kills the spawned child on `RunEvent::Exit`.
- `ui/index.html` — the "Starting crowd…" splash shown until `crowd` is up
  (`tauri.conf.json` `frontendDist` points here).
- **Dev only:** the crowd binary is resolved relative to the crate
  (`../../.build/debug/crowd`). A release build will bundle `crowd` as a proper
  Tauri sidecar instead.

## Roadmap

1. Native **menu + notifications** (`tauri-plugin-notification`).
2. **`open_in_editor` / `open_terminal`** Rust commands exposed to the web UI via
   a `window.__TAURI__` shim — closes the deferred host-affordance gap.
3. Release build → bundle `crowd` as a Tauri sidecar → `.app` / `.dmg`.
