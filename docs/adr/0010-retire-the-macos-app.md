# 0010 — Retire the macOS app; the web UI is the only client

- **Status:** Accepted
- **Date:** 2026-07-07
- **Deciders:** @danny, Claude

## Context

[ADR 0009](./0009-crowd-sole-authority-clients-only.md) made `crowd` the sole authority and demoted every UI — including the macOS app — to a pure client. Once the app held zero engine/store/spawner/server, its only remaining value was its *native shell*: the AppKit window, SwiftUI views, WKWebView terminal, menu bar, and host affordances (clipboard, open-in-editor, notifications).

The CROW-593 web-UI-parity work brought the browser client up to that bar. It renders the same sessions/boards, streams the same tmux terminals via xterm.js over `/terminal`, handles its own clipboard and browser notifications, and gained web-access auth for remote use. With two clients drawing the same state, the macOS app became a second UI to build, test, and keep in sync for no capability the web UI lacked — while still forcing an app rebuild for every UI change and carrying the `forwardToApp` hybrid path plus its two-store reconciliation.

## Decision

The macOS app is removed. `crowd` plus the **web UI are the only client**. The `Sources/Crow` AppKit target, the `CrowUI` SwiftUI package, the app tests, and the `.app` packaging/signing scripts are deleted; the daemon's `forwardToApp` / `forwardSocket` / `daemonIsAuthority` machinery is stripped, so `crowd` is unconditionally the authority and every handler runs its local path. The build produces two binaries: `crow` (CLI) and `crowd` (daemon).

## Consequences

**Easier:** one UI to build and test; UI changes are web-asset edits served live (no app rebuild); the hybrid forward path and two-store reconciliation are gone; `crowd`'s handler set has a single code path.

**Harder / must live with:** host affordances only a native process could do are either the browser's job now (clipboard, notifications) or not yet reachable — `openInEditor` / `openTerminalWindow` have no web equivalent and are deferred (a small follow-up: `crowd` runs on the host and can shell out). `crowd` has no autostart yet, so you start it yourself (a terminal, `tmux`, or your own `launchd` plist) until a login-item installer lands. Native, always-on macOS notifications with no tab open are gone; browser notifications require an open tab.

## Alternatives considered

- **Keep the app as a thin native client (the 0007 end-state):** rejected — it kept a second UI to maintain and an app rebuild in the loop for zero capability the web UI lacks.
- **Delete the app only after reimplementing its host affordances in `crowd`:** rejected as a blocker — `openInEditor` / `openTerminalWindow` are a small follow-up, not a reason to keep the whole app alive.

## References

- PR: https://github.com/corveil/crow/pull/594 (CROW-593)
- Related ADRs: [0009](./0009-crowd-sole-authority-clients-only.md) (crowd is the sole authority — this ADR removes its last non-web client), [0006](./0006-universal-macos-binary.md) (xterm.js renderer — still used, now in the browser)
- Code: `Packages/CrowDaemon/` (`crowd`), `Packages/CrowEngine/` (host-agnostic engine + `HostBridge`)
- Follow-up: the "no autostart yet" consequence above is closed by [#769](https://github.com/corveil/crow/issues/769) — `crow autostart install` (and Settings → General → Autostart) registers a launchd LaunchAgent; see `Packages/CrowAutostart/`
