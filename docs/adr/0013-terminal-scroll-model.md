# 0013 — Terminal scroll model: per-surface hybrid (unified scrollback for shells, native alt-screen for agent TUIs)

- **Status:** Accepted
- **Date:** 2026-07-23
- **Deciders:** @dhilgaertner

## Context

Crow's web terminal delivers a **single unified xterm.js scrollback**: the browser wheel scrolls a 50k-line buffer and, on (re)connect, the daemon replays the pane's full tmux history back into it (`capture-pane -pe -S -50000`, CROW-606). To get there, Crow deliberately strips a full-screen app's scroll ownership at three layers:

1. `crow-tmux.conf` — `set -gw alternate-screen off` keeps inner apps in the pane's **main** buffer (no alt buffer).
2. `crow-tmux.conf` — `terminal-overrides ',xterm*:smcup@:rmcup@,screen*:smcup@:rmcup@'` cancels the **client's** alt-screen capability too.
3. `web/app.js` — `swallowMouseMode` drops the DECSET 1000–1016 mouse-tracking sequences an agent emits to claim the wheel; `enableWheelScroll` owns the wheel and scrolls xterm's buffer.

This model is a good fit for **line-streaming** output (shells, `git log`, build logs, review diffs — text flows down and never repaints). It is a **bad fit for a continuously repainting full-frame TUI** like Claude Code or Cursor. Issue #822 reported the symptom: scrolling up in the web terminal shows **stacked duplicate copies of the agent's TUI** instead of a clean transcript.

**Root cause, confirmed by spike #822.** Denied a fixed viewport, an agent's full-frame repaints (streaming tokens, spinner, every keystroke) land in a main buffer that is itself scrolling. Each screen-clear-and-redraw deposits the prior frame into the 50k scrollback as sediment. Scrolling up walks the fossil record of past frames.

The spike measured this directly. Against the **live** tmux server, a Claude Code pane sat in the main buffer (`alternate_on=0`) with history accumulating while idle, and `capture-pane` showed the same footer stacked 3× in one pane's scrollback. An isolated-tmux A/B harness (a repainting TUI mimic) made it deterministic:

| Config | `alternate_on` | `history_size` | Stacked footer copies in scrollback |
|--------|:---:|:---:|:---:|
| `alternate-screen off` (current) | 0 | 1641 | **42** |
| `alternate-screen on` | 1 | **0** | **1** (the live frame only) |

Prior work healed a *related* degradation (stale alt-screen / 5000-line windows, #804/#821) but did not address this: the duplicate-frame artifact is a property of the core scroll model, not of degraded windows. The rationale for that model is today scattered across `crow-tmux.conf` comments and ADR-0001 (which is about tmux-as-backend, not scrolling); this ADR gives the scroll model its own record.

## Decision

Crow adopts a **per-surface hybrid** terminal scroll model:

- **Plain shell / review surfaces** keep the unified xterm.js scrollback (the current behavior): `alternate-screen off`, output flows into the 50k history, CROW-606 replay restores it, the browser wheel scrolls xterm.
- **Agent-TUI surfaces** (Claude Code, Cursor, and the Manager, which runs one too) own their own viewport and scrollback like a naked terminal: the daemon sets `alternate-screen on` **per agent window**, the client stops swallowing that window's mouse modes, and the wheel is forwarded to the app. No frame sediment because repaints stay in the alt buffer, which has no scrollback.

`swallowMouseMode` and `enableWheelScroll` become **conditional on surface kind** rather than global, sharing one predicate (`appOwnsScroll`): an agent surface, a real alternate buffer, or an app with active mouse tracking → the app owns the wheel; else xterm scrolls its scrollback. `enableTouchScroll` routes on the same predicate so touch and wheel can't disagree. How "agent surface" is determined is the crux, resolved below — it is *not* `buffer.active.type`.

This is the **Option B** of the spike. It is chosen over Option A (honor the alt screen everywhere) because A throws away the unified scrollback for *every* surface — regressing the exact behavior CROW-606, #776, and #777 were built to deliver — to fix a problem that only the repainting agent surfaces have.

### Resolved: how the client learns a surface is an agent TUI

The spike left this open, offering (a) scope the `smcup@/rmcup@` strip to non-agent surfaces, or (b) signal window-kind to `app.js`. **Option (a) turned out to be unimplementable**, verified against a live server during #824:

- `terminal-overrides` is a **server** option matched on the **client's `TERM`**, not on a window.
- `tmux list-clients` shows **one client serving every tab** — each web surface opens a single grouped `crowd-web-*` session and switches tabs with `select-window`. smcup is emitted once for the whole attachment, so there is no per-window client buffer state to scope.

So `term.buffer.active.type` is **permanently `'normal'`** on the web client, and routing on it cannot work. (The spike's Option B prototype did exactly that and was therefore inert: its `swallowMouseMode` early-return never fired, and its `mouseTrackingMode` fallback was suppressed by the very swallow it was meant to gate — a circular dependency that latched into the plain-shell path.)

**Chosen: (b), carried on the existing `list-terminals` RPC payload.** `crowd` emits a per-terminal `agent_surface` flag beside the existing `scrollback_degraded`, and `app.js` routes on it. The flag's source of truth is the `alternate-screen` **window option the daemon actually set**, read back via `#{alternate-screen}` in the same `list-windows` call that feeds degraded-detection — so daemon and client agree by construction, with no window-name matching. The `/terminal` socket was deliberately not used: its server→client direction is binary-only through a single writer task, so adding text frames would mean widening the stream type and racing that writer.

Classification is the terminal's `isManaged` — **not** `agentKind` (always non-nil; it falls back to a default) and **not** `trackReadiness` (false for Manager sessions, which are agent TUIs too).

## Consequences

**Easier / better**
- Agent TUIs behave like a naked terminal: the input box stays pinned, the wheel scrolls the agent's own transcript, and the duplicate-frame sediment is gone.
- Shells, review diffs, and build logs keep the unified 50k scrollback and CROW-606 replay unchanged.
- The scroll model now has a single documented home (this ADR + a scroll-model comment block), instead of being reverse-engineered from three interacting settings.

**Harder / to live with**
- **Two code paths.** The wheel/mouse handling is now conditional; both branches must be kept correct and tested. The `swallowMouseMode` and `enableWheelScroll` conditionals are the crux.
- **Agent-window classification.** The daemon must know which windows are agent TUIs to set `alternate-screen on` at creation (it already names them, e.g. "Claude Code", and launches a known command — a reliable signal).
- **The client cannot detect the alt buffer itself** — resolved above by signalling `agent_surface` out of band. The cost is that the two layers must stay in sync: if the daemon ever stops setting the window option, the client silently falls back to the shell path.
- **Agent-window scrollback boundary.** Inside an agent window, "scroll behind the app" into pre-launch shell history is no longer available (the alt buffer has no scrollback) — same trade a naked terminal makes. Settled during #824:
  - **CROW-606 replay** is correct by construction. `capture-pane -pe -S -50000` on an alt-buffer pane returns just the current frame, and `replayFrame` prepends `ESC[H ESC[2J ESC[3J`, so reconnects rebuild rather than stack. No change needed.
  - **Jump-to-bottom pill** keys off `viewportY >= baseY`. On an agent surface tmux repaints in place, the client's scrollback never grows, both stay 0, and the pill correctly stays hidden — there is nothing to jump back to. No change needed.
  - **Copy/paste** is the one real regression: native drag-select and the right-click menu are eaten inside agent windows, because they worked *because* of the mouse-mode swallow. Mitigated by enabling `macOptionClickForcesSelection` so ⌥-drag forces selection (xterm.js defaults that option to `false`, so it must be set explicitly), surfaced as a hint in the terminal context menu. Plain shells are unaffected.
- **A degraded-window blind spot.** `isScrollbackDegraded` now takes `alternateScreenEnabled`, so an agent surface in the alt buffer is healthy rather than badged ⚠ Recreate. The consequence is that an agent window *genuinely* wedged in the alt buffer at the full 50000 limit is no longer distinguishable from the normal state. The `history_limit` floor still catches the real #804/#821 casualties, which measured `history_limit=5000`.
- **The window option is frozen at creation.** tmux applies `alternate-screen` per window, and a `source-file` reload does not retrofit it. Windows adopted from a previous crowd are re-applied on adopt, but a *live* agent keeps its current buffer until it restarts; the ⚠ Recreate affordance remains the immediate manual path.

## Alternatives considered

- **Option A — honor the alt screen everywhere** (`alternate-screen on` globally, drop the smcup strip, stop swallowing mouse modes, forward the wheel to the app). Simplest and fully fixes the sediment (spike-proven: `history_size` 1641→0, 42 copies→1). Rejected because it deletes the unified scrollback for *all* surfaces — plain shells lose native wheel scrollback and CROW-606 replay has nothing to restore (`history_size=0`) — regressing CROW-606/#776/#777 to fix a problem only agent TUIs have. Kept on throwaway branch `spike/822-option-a`.
- **Option C — dedupe repaints in the unified buffer.** Rejected up front: there is no reliable way to recognize and collapse full-frame TUI repaints in a linear text buffer.

## References

- Spike: [#822](https://github.com/corveil/crow/issues/822); findings + prototype details in [`docs/spikes/822-terminal-scroll.md`](../spikes/822-terminal-scroll.md).
- Prototype branches (not merged): `spike/822-option-a`, `spike/822-option-b`.
- Related ADRs: [0001 — tmux as the sole terminal backend](./0001-tmux-only-terminal-backend.md) (this ADR carves the scroll model out of ADR-0001's terminal-backend scope; ADR-0001 is otherwise unchanged).
- Prior art: CROW-606 (replay, #609/#612), #776/#789 (mouse-mode swallow), #777/#786 (iOS touch-scroll ownership), #804/#821 (scrollback heal), epic #783 (replay reflow fidelity).
- Implementation: [#824](https://github.com/corveil/crow/issues/824).
- Code: `crow-tmux.conf` (alt-screen default, smcup/rmcup, mouse, history-limit); `TmuxController.setWindowOption` / `listWindowScrollback` (per-window option + the `#{alternate-screen}` read-back); `TmuxBackend.registerTerminal(agentSurface:)`, `enableAlternateScreen`, `isScrollbackDegraded(alternateScreenEnabled:)`, `agentSurfaceWindowIndices`; `EngineRouter` `list-terminals` (`agent_surface`); `web/app.js` (`activeSurfaceIsAgent`, `appOwnsScroll`, `swallowMouseMode`, `enableWheelScroll`, `enableTouchScroll`, `sendScrollToPTY`); `TerminalCockpit.swift` / `TerminalWebSocket.swift` (CROW-606 replay).
- Tests: `ScrollbackHealthTests` (kind-aware policy truth table), `TmuxControllerTests.agentWindowOptsIntoAlternateScreenWithoutAffectingSiblings` (real-tmux per-window coexistence), `WebTerminalAssetTests` (client routing shape), `web-tests/wheel-scroll.test.js` (jsdom wheel + conditional swallow).
