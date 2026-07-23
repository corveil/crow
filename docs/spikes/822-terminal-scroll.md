# Spike #822 — Web terminal duplicate Claude Code TUI frames on scroll-up

**Issue:** [#822](https://github.com/corveil/crow/issues/822) · **Date:** 2026-07-23 · **Author:** @dhilgaertner
**Decision:** Option B (per-surface hybrid) — see [ADR-0013](../adr/0013-terminal-scroll-model.md).
**Prototype branches (not merged):** `spike/822-option-a`, `spike/822-option-b`.

This spike characterizes why scrolling up in the web terminal shows stacked duplicate copies of the Claude Code TUI, prototypes two fixes, and picks one. Per the ticket's "Out of scope", it does **not** implement the fix — that's a follow-up ticket.

## 1. Root cause — frame sediment

Claude Code is a **full-frame repainting TUI**: in a capable terminal it keeps itself in a fixed viewport (alternate screen + its own mouse-wheel reporting) and manages its own scrollback. Crow deliberately strips that ownership at three layers so it can deliver one unified xterm.js scrollback (browser wheel scrolls a 50k buffer; `capture-pane` replays history on reconnect, CROW-606):

1. `crow-tmux.conf` — `set -gw alternate-screen off` (inner apps stay in the pane's **main** buffer).
2. `crow-tmux.conf` — `terminal-overrides ',xterm*:smcup@:rmcup@,screen*:smcup@:rmcup@'` (cancels the **client's** alt-screen too).
3. `web/app.js` — `swallowMouseMode` drops DECSET 1000–1016; `enableWheelScroll` owns the wheel and scrolls xterm's buffer.

**Mechanism:** denied a fixed viewport, the agent's constant full-frame repaints land in a main buffer that is itself scrolling. Each clear-and-redraw deposits the prior frame into the 50k scrollback as sediment. Scrolling up walks hundreds of past frames — "Claude Code multiple times."

## 2. Live reproduction (read-only)

Against the running shared tmux server (`$TMPDIR/crow-tmux.sock`, grouped session `crowd-web-*`):

- Claude Code panes sit in the **main buffer** (`alternate_on=0`) with history growing while idle (`hist=181`, `239` lines).
- `capture-pane -p` of one pane showed the same footer (`⏵⏵ auto mode on … PR #1785`) stacked **3×** at scrollback lines 120 / 239 / 307 — ~119 lines apart, i.e. one full-frame repaint per copy.
- Global options confirmed: `mouse off`, `alternate-screen off`, `history-limit 50000`.
- Nuance: `mouse_any=1`/`mouse_all=1` on those panes — tmux *does* register the agent's mouse tracking; the swallow is purely client-side. Some stale panes still showed `alternate_on=1` + `hist=…/5000` (the #804/#821 heal case), so alt-screen suppression is not absolute.

## 3. Deterministic A/B measurement (isolated tmux)

To avoid disturbing the live instance, all prototype validation ran on a **throwaway** tmux server (`tmux -S $TMPDIR/spike822*.sock -f <conf>`) with a repaint harness that mimics a full-frame TUI (enter alt screen → clear+redraw a full frame with a per-frame marker + a fixed "input box" footer → repeat → leave alt screen). No crowd rebuild; live instance untouched.

**Option A vs baseline** (pane 100×40, sampled mid-run while repainting):

| Config | `alternate_on` | `history_size` | Footer copies | Input-box copies |
|--------|:---:|:---:|:---:|:---:|
| Baseline (`alternate-screen off`, current) | 0 | **1641** | **42** | **43** |
| Option A (`alternate-screen on`) | 1 | **0** | **1** | **1** |

The baseline scrollback dump showed the input box + footer repeated once per frame, every 40 lines (= pane height) — the same pattern as the live capture:

```
38:╭ INPUT BOX top (frame 1)
40:╰ auto mode on · FOOTER MARKER
78:╭ INPUT BOX top (frame 2)
80:╰ auto mode on · FOOTER MARKER
118:╭ INPUT BOX top (frame 3)
120:╰ auto mode on · FOOTER MARKER
… (one copy per repaint)
```

**Takeaways:** the sediment is real and mechanical, and moving the app into the alt buffer eliminates it completely (`history_size` 1641 → 0; 42 stacked copies → 1 live frame). It also shows Option A's cost concretely: `history_size=0` means CROW-606 replay has nothing to restore for that window.

## 4. Prototype Option A — `spike/822-option-a`

Honor the alt screen everywhere. Changes:
- `crow-tmux.conf`: `alternate-screen on`; drop the `smcup@/rmcup@` override.
- `app.js`: stop swallowing mouse modes; `enableWheelScroll` forwards the wheel to the app unconditionally (via `sendScrollToPTY`).

**Result:** input box stays pinned, duplicates vanish (alt buffer owns the viewport). **What breaks:**
- **Unified browser scrollback** dies for *every* surface — the alt buffer has no history, so `capture-pane -pe -S -50000` replays only the current frame (`history_size=0` measured).
- **Plain shells** lose native wheel scrollback too (everything routes to the PTY).
- **Mobile touch, copy/paste across history, jump-to-bottom pill** all assume a scrollable local buffer that no longer exists on agent surfaces.

Fully fixes the reported bug, but by deleting the behavior CROW-606/#776/#777 were built to deliver, for all surfaces.

## 5. Prototype Option B — `spike/822-option-b`

Per-surface hybrid. Changes:
- `crow-tmux.conf`: global default stays `alternate-screen off` (plain shells keep unified scrollback); document that the daemon sets `alternate-screen on` **per agent window** at creation.
- `app.js`: `swallowMouseMode` and `enableWheelScroll` become **conditional** — alt buffer / active mouse tracking → forward the wheel to the app; else scroll xterm's 50k scrollback (mirrors what `enableTouchScroll`/`sendScrollToPTY` already do for touch).

**Validation** — two windows in one isolated server, sampled mid-run:

| Window | `alternate-screen` | `alternate_on` | `history_size` | Footer copies | Shell-log lines |
|--------|:---:|:---:|:---:|:---:|:---:|
| agent (repaint TUI) | on | 1 | **0** | 1 | 0 |
| shell (streaming) | off (default) | 0 | **761** | 0 | **800** |

Per-window `alternate-screen on` coexists with the global `off` in the same server: the agent window owns the alt buffer (no sediment) while the plain shell keeps its growing unified scrollback.

**Open question surfaced (the real implementation work):** for `app.js` to route by `buffer.active.type === 'alternate'`, the **client** (xterm.js) must also enter the alt buffer for an agent window — which the global `smcup@/rmcup@` strip currently prevents. The follow-up must either (a) scope that strip to non-agent surfaces, or (b) have crowd signal window-kind to `app.js` and route on that instead of buffer type. The spike proved the tmux side; this wiring is the follow-up's crux.

## 6. Decision: Option B

Option A is simpler and fully fixes the sediment, but it regresses unified scrollback for every surface to fix a problem only the repainting agent TUIs have. Option B keeps the unified model where it fits (line-streaming shells, review diffs) and gives agent TUIs native ownership where they need it. Chosen. Recorded in [ADR-0013](../adr/0013-terminal-scroll-model.md). Cost: two code paths + the client alt-buffer-detection wiring above.

## 7. Follow-up

Implementation is tracked in a separate ticket (filed from this spike): per-agent-window `alternate-screen on` + agent-window classification in the daemon, conditional `swallowMouseMode`/`enableWheelScroll` in `app.js`, the client alt-buffer-detection wiring (scope the smcup strip or signal window-kind), and an alt-buffer pass over CROW-606 replay / jump-to-bottom / copy-paste. Prototype branches `spike/822-option-a` and `spike/822-option-b` are reference only — not for merge.
