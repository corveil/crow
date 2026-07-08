# Crow — desktop wrapper (Tauri)

A thin native macOS shell around the Crow web UI, built with **Tauri v2**. The
window loads the running `crowd` daemon; `crowd` stays the sole authority
(see [ADR 0007](../docs/adr/0007-crowd-sole-authority-clients-only.md) /
[ADR 0008](../docs/adr/0008-retire-the-macos-app.md)). There is **no bundled
frontend** — the UI is served by `crowd`, not this project.

## Run (connect mode)

`crowd` must be serving on `http://127.0.0.1:8787` first:

```bash
cd ..                      # repo root
.build/debug/crowd         # or: make crowd-dev
```

Then launch the app. The dev shell runs under Rosetta (x86_64) and would otherwise
grab an old x86_64 Rust; pin PATH to the arm64 Homebrew toolchain:

```bash
PATH="/opt/homebrew/bin:$HOME/.cargo/bin:$PATH" npm run tauri dev
```

Or run the already-built debug binary directly (no rebuild):

```bash
./src-tauri/target/debug/crow-desktop
```

## Config

- `src-tauri/tauri.conf.json` — `devUrl` / `frontendDist` both point at the
  `crowd` URL (`http://127.0.0.1:8787`).

## Status & roadmap

Connect-mode MVP: the window loads a separately-running `crowd`. Planned:

1. **Sidecar-spawn `crowd`** — bundle the release binary so the app launches its
   own daemon → a self-contained `.app` (no separate `crowd` terminal).
2. Native **menu + notifications** (`tauri-plugin-notification`).
3. **`open_in_editor` / `open_terminal`** Rust commands exposed to the web UI via
   a `window.__TAURI__` shim — closes the deferred host-affordance gap.
4. Release build → `.app` / `.dmg`.
