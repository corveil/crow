# 0013 — Terminal scroll model: per-surface hybrid (unified scrollback for shells, native alt-screen for agent TUIs)

- **Status:** Proposed
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
- **Agent-TUI surfaces** (Claude Code, Cursor) own their own viewport and scrollback like a naked terminal: the daemon sets `alternate-screen on` **per agent window**, the client stops swallowing that window's mouse modes, and the wheel is forwarded to the app. No frame sediment because repaints stay in the alt buffer, which has no scrollback.

`swallowMouseMode` and `enableWheelScroll` become **conditional on pane state** (`buffer.active.type === 'alternate'` OR active mouse tracking → the app owns the wheel; else xterm scrolls its scrollback) rather than global. This mirrors what `enableTouchScroll`/`sendScrollToPTY` already do for touch on the alt buffer.

This is the **Option B** of the spike. It is chosen over Option A (honor the alt screen everywhere) because A throws away the unified scrollback for *every* surface — regressing the exact behavior CROW-606, #776, and #777 were built to deliver — to fix a problem that only the repainting agent surfaces have.

Status is **Proposed**: the spike delivers the decision + this record; implementation lands under a follow-up ticket, at which point this ADR moves to Accepted.

## Consequences

**Easier / better**
- Agent TUIs behave like a naked terminal: the input box stays pinned, the wheel scrolls the agent's own transcript, and the duplicate-frame sediment is gone.
- Shells, review diffs, and build logs keep the unified 50k scrollback and CROW-606 replay unchanged.
- The scroll model now has a single documented home (this ADR + a scroll-model comment block), instead of being reverse-engineered from three interacting settings.

**Harder / to live with**
- **Two code paths.** The wheel/mouse handling is now conditional; both branches must be kept correct and tested. The `swallowMouseMode` and `enableWheelScroll` conditionals are the crux.
- **Agent-window classification.** The daemon must know which windows are agent TUIs to set `alternate-screen on` at creation (it already names them, e.g. "Claude Code", and launches a known command — a reliable signal).
- **Client alt-buffer detection is the load-bearing open question.** For `app.js` to route by `buffer.active.type === 'alternate'`, the **client** (xterm.js) must also enter the alt buffer for an agent window — which the global `smcup@/rmcup@` strip (layer 2) currently prevents. The follow-up must either (a) scope that strip to non-agent surfaces so agent windows re-gain client smcup, or (b) have crowd signal window-kind to `app.js` over the existing control channel and route on that instead of buffer type. The spike validated the tmux side (per-window `alternate-screen on` coexists with `off` in one server) but flagged this wiring as the real implementation work.
- **Agent-window scrollback boundary.** Inside an agent window, "scroll behind the app" into pre-launch shell history is no longer available (the alt buffer has no scrollback) — same trade a naked terminal makes. CROW-606 replay for an agent window restores only its current frame; the jump-to-bottom pill and copy/paste semantics need a pass for the alt-buffer case.

## Alternatives considered

- **Option A — honor the alt screen everywhere** (`alternate-screen on` globally, drop the smcup strip, stop swallowing mouse modes, forward the wheel to the app). Simplest and fully fixes the sediment (spike-proven: `history_size` 1641→0, 42 copies→1). Rejected because it deletes the unified scrollback for *all* surfaces — plain shells lose native wheel scrollback and CROW-606 replay has nothing to restore (`history_size=0`) — regressing CROW-606/#776/#777 to fix a problem only agent TUIs have. Kept on throwaway branch `spike/822-option-a`.
- **Option C — dedupe repaints in the unified buffer.** Rejected up front: there is no reliable way to recognize and collapse full-frame TUI repaints in a linear text buffer.

## References

- Spike: [#822](https://github.com/corveil/crow/issues/822); findings + prototype details in [`docs/spikes/822-terminal-scroll.md`](../spikes/822-terminal-scroll.md).
- Prototype branches (not merged): `spike/822-option-a`, `spike/822-option-b`.
- Related ADRs: [0001 — tmux as the sole terminal backend](./0001-tmux-only-terminal-backend.md) (this ADR carves the scroll model out of ADR-0001's terminal-backend scope; ADR-0001 is otherwise unchanged).
- Prior art: CROW-606 (replay, #609/#612), #776/#789 (mouse-mode swallow), #777/#786 (iOS touch-scroll ownership), #804/#821 (scrollback heal), epic #783 (replay reflow fidelity).
- Code: `Packages/CrowTerminal/Sources/CrowTerminal/Resources/crow-tmux.conf` (alt-screen, smcup/rmcup, mouse, history-limit); `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/app.js` (`swallowMouseMode`, `enableWheelScroll`, `enableTouchScroll`, `sendScrollToPTY`); `Packages/CrowDaemon/Sources/CrowDaemon/TerminalCockpit.swift` / `TerminalWebSocket.swift` (CROW-606 replay).
