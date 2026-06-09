# CROW-466 — SwiftTerm Renderer Spike

**Status:** In progress — measurements pending.
**Ticket:** https://github.com/radiusmethod/crow/issues/466

## Why

1. **OSC 8 hyperlinks don't work.** Ghostty fires `MOUSE_OVER_LINK` and `OPEN_URL` actions but `GhosttyApp.handleAction()` (`Packages/CrowTerminal/Sources/CrowTerminal/GhosttyApp.swift:54-126`) only dispatches `SHOW_CHILD_EXITED`. Every link is silently dropped.
2. **libghostty is oversized for what we use.** ~23 C functions out of hundreds; ~135 MB linked static lib; ~1 GB vendored source.
3. **Tmux-mouse workaround thread** (#445/446/452) shows the embed is awkward to live with.

This spike measures whether SwiftTerm is a viable replacement before committing to a swap.

## What's on this branch

A compile-time flag `CROW_RENDERER_SWIFTTERM` selects the renderer at `swift build` time. Default build is unchanged — Ghostty stays the renderer and everything compiles as before. Opt-in build links SwiftTerm and conditionally compiles the Ghostty path out.

### Files

| Added | Purpose |
|---|---|
| `Packages/CrowTerminal/Sources/CrowTerminal/SwiftTermApp.swift` | Singleton analog of `GhosttyApp` (lifecycle + child-exit callback) |
| `Packages/CrowTerminal/Sources/CrowTerminal/SwiftTermSurfaceView.swift` | `NSView` wrapping `LocalProcessTerminalView`; mirrors `GhosttySurfaceView` API |
| `Packages/CrowTerminal/Sources/CrowTerminal/TerminalRendererTypealias.swift` | `TerminalSurfaceImpl` typealias |
| `Packages/CrowTerminal/Sources/CrowTerminal/Resources/spike-link-test.sh` | OSC 8 link fixture for manual verification |

| Modified | Change |
|---|---|
| `Packages/CrowTerminal/Package.swift` | Reads `CROW_RENDERER_SWIFTTERM`; conditionally drops GhosttyKit binary target + adds SwiftTerm SPM dep |
| `Packages/CrowTerminal/Sources/CrowTerminal/GhosttyApp.swift` | Wrapped in `#if !CROW_RENDERER_SWIFTTERM` |
| `Packages/CrowTerminal/Sources/CrowTerminal/GhosttySurfaceView.swift` | Wrapped in `#if !CROW_RENDERER_SWIFTTERM` |
| `Packages/CrowTerminal/Sources/CrowTerminal/TerminalSurfaceView.swift` | Uses `TerminalSurfaceImpl` instead of `GhosttySurfaceView` |
| `Packages/CrowTerminal/Sources/CrowTerminal/TmuxBackend.swift` | `cockpitSurface()` returns `TerminalSurfaceImpl` |
| `Sources/Crow/App/AppDelegate.swift` | 3 sites: init / child-exited wiring / shutdown |

### Build both variants

```bash
# A — control (Ghostty)
swift build -c release

# B — SwiftTerm
CROW_RENDERER_SWIFTTERM=1 swift build -c release
```

Under Rosetta add `--arch arm64`.

## Verification checklist (per variant)

- [ ] **OSC 8 link click** — run `Packages/CrowTerminal/Sources/CrowTerminal/Resources/spike-link-test.sh` inside a tmux pane. Hover shows pointing-hand cursor. Click opens the URL in default browser.
- [ ] **tmux integration** — open a session, run an agent, exit, reattach. Session restored. `SentinelWaiter` still fires.
- [ ] **Selection + clipboard** — drag-select, `Cmd+C`, paste elsewhere has the right text. Wheel scrolls tmux history.
- [ ] **Programmatic input** — `crow send --session $UUID --terminal $TID "hello world\n"` lands in the pane.
- [ ] **No regressions** — both renderer paths build cleanly. Default build is functionally identical to `main`.

## Measurements

> Filled in once both variants build cleanly on the target machine. Numbers, not adjectives.

### Binary size

| Variant | `du -sh build/release/Crow.app` |
|---|---|
| Ghostty (control) | _TBD_ |
| SwiftTerm | _TBD_ |
| Delta | _TBD_ |

### Cold-start to first terminal ready

`SentinelWaiter` already reports elapsed ms — capture from logs across 5 runs.

| Variant | median (ms) | p95 (ms) |
|---|---|---|
| Ghostty | _TBD_ | _TBD_ |
| SwiftTerm | _TBD_ | _TBD_ |

### Render throughput

`time (seq 1 100000 | cat)` inside one tmux pane, 5 runs each.

| Variant | wall time (s) | observed drops / tear |
|---|---|---|
| Ghostty | _TBD_ | _TBD_ |
| SwiftTerm | _TBD_ | _TBD_ |

### Steady-state (idle 60s)

| Variant | CPU % | RSS (MB) |
|---|---|---|
| Ghostty | _TBD_ | _TBD_ |
| SwiftTerm | _TBD_ | _TBD_ |

### Feature parity

| Feature | Ghostty | SwiftTerm | Notes |
|---|---|---|---|
| Selection (drag) | _TBD_ | _TBD_ | |
| Copy / paste | _TBD_ | _TBD_ | |
| Scrollback wheel | _TBD_ | _TBD_ | |
| 256 / truecolor | _TBD_ | _TBD_ | |
| Alt screen | _TBD_ | _TBD_ | |
| Mouse modes (tmux) | _TBD_ | _TBD_ | |
| OSC 8 hyperlinks | _TBD_ | _TBD_ | core hypothesis |
| IME / marked text | _TBD_ | _TBD_ | |
| Drag-drop file paths | _TBD_ | _TBD_ | |

### Tmux mouse workarounds (#446)

The `copy-pipe-no-clear` bindings in `crow-tmux.conf` exist to keep selections alive across mouse-up under Ghostty. On SwiftTerm: _TBD — still required? unnecessary? different workaround needed?_

### Things lost or noticeably worse on SwiftTerm

- _TBD — CoreText vs Metal perceptible quality?_
- _TBD — missing features Crow secretly depended on?_

## Recommendation

> **Pending measurements.**
>
> If **Go**: file follow-on ticket to remove `vendor/ghostty/`, `Frameworks/GhosttyKit.xcframework/`, and `GhosttyApp.swift` / `GhosttySurfaceView.swift`; update ADR 0001.
>
> If **No-go**: file cheaper follow-on to wire OSC 8 link handling inside `GhosttyApp.handleAction()` (~50 LOC). Record specific rejection reasons here so the question doesn't get re-litigated.

A summary of the final numbers + recommendation will also be posted as a comment on issue #466.
