# 0022 — Session grid cells are read-only capture-pane snapshots

- **Status:** Accepted
- **Date:** 2026-08-28
- **Deciders:** @danny, Cursor

## Context

[CROW-1153](https://github.com/corveil/crow/issues/1153) adds a single-pane-of-glass
watch wall: up to 16 session cells, each showing that session's primary terminal,
reachable as a top-level board (`#/grid`). The ticket left several implementation
choices open, and two of them collide with how Crow's terminal backend actually
works.

Every browser `/terminal` connection is a grouped tmux session off `crow-cockpit`
([ADR 0001](./0001-tmux-only-terminal-backend.md), [ADR 0010](./0010-retire-the-macos-app.md)).
Window *identity* is per client (`select-window` is private), but window *size* is
shared. `crow-tmux.conf` sets `window-size latest` with `aggressive-resize on`, so
the most recent client to view a window owns its cols×rows. A 4×4 cell is tens of
columns wide. Attaching 16 live PTYs and fitting them would SIGWINCH every agent
TUI down to the cell, including the focused session the user is actually typing in.

The daemon also bounds concurrent `/terminal` upgrades at 16
(`TerminalConnectionLimiter`). A 16-cell wall of live sockets would exhaust that
ceiling on its own, before counting the focused session or a second browser tab.

The existing session-switcher already captures a pane without attaching
(`get-session-terminal-preview` → `capture-pane`). That is the pattern a watch
wall can scale.

## Decision

Grid cells are **read-only snapshots**, not live PTY mirrors.

- The wall polls `list-session-terminal-snapshots` (~800ms) for the visible page
  (capped at 16 session ids). Each row is `capture-pane -pe` of the **visible**
  frame, already framed for xterm.js (`replayFrame`), plus `#{pane_width}` /
  `#{pane_height}` so the cell can `term.resize` locally without telling tmux.
- Each cell paints that blob into a small xterm.js instance (`disableStdin`,
  `scrollback: 0`, no WebGL) and CSS-scales it to the cell. Clicking the cell
  (or its name) calls `selectSession` and the existing full terminal takes over.
- Pin state is a per-browser ordered id list in `localStorage` (`crow.grid.pins`),
  not an `AppConfig` field and not a per-session flag. Pinned sessions lead the
  roster in pin order; remaining slots auto-fill with `active` / `inReview`
  sessions sorted by activity. Overflow paginates rather than shrinking cells.
- The managed agent terminal is the watched pane; Managers (no `isManaged` flag)
  fall through to the switcher's window picker.
- v1 is web-only. The Tauri desktop shell loads the same UI ([ADR 0010](./0010-retire-the-macos-app.md));
  there is no fourth renderer and no native grid.

## Consequences

**Easier:** 16 cells cannot resize or type into the shared cockpit; the connection
limiter is untouched; the grid is a layout around the existing xterm component
rather than a fork of `terminal.html` / `app.js`'s interactive surface; pin state
is per browser user, which is the right grain for remote web access.

**Harder / must live with:** cells update on the poll, not per PTY byte, so a
fast-moving TUI can look stepped. Alt-buffer frames are still capturable (tmux
returns the current screen) but will not be *interactive*. A live, typeable wall
would need a tmux `window-size` model that ignores unfocused clients — a different
ADR, not a grid-cell flag.

## Alternatives considered

- **16 live `/terminal` sockets, read-only stdin:** rejected — even without
  `resize` frames, the initial PTY winsize on attach still participates in
  `window-size latest`, and 16 extra `tmux attach` clients hit the connection
  limiter and the fd budget.
- **iframes of `/terminal.html`:** rejected — that page is a debug surface that
  already drifts from `app.js` (mouse-mode swallow, no `agent_surface`), and it
  would still attach 16 PTYs.
- **Pins in `AppConfig`:** rejected for v1 — the daemon config is per-machine,
  not per remote web user; `localStorage` matches "persists per user" under
  shared-daemon remote access. Promotable later if a CLI pin verb appears.
- **Pinned-only wall (no auto-fill):** rejected — first visit would be empty;
  auto-fill makes the fleet visible immediately, and pinning only overrides order.

## References

- Ticket: https://github.com/corveil/crow/issues/1153
- Related ADRs: [0001](./0001-tmux-only-terminal-backend.md), [0010](./0010-retire-the-macos-app.md), [0018](./0018-web-client-hash-routing.md)
- Code: `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/app.js` (`renderSessionGrid`),
  `SessionRPCHandlers.swift` (`list-session-terminal-snapshots`),
  `TerminalCockpit.snapshotPane`
