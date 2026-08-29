# 0013 — Terminal scroll model: per-surface hybrid (unified scrollback for shells, native alt-screen for agent TUIs)

- **Status:** Accepted
- **Date:** 2026-07-23
- **Deciders:** @dhilgaertner

## Context

Crow's web terminal delivers a **single unified xterm.js scrollback**: the browser wheel scrolls a 50k-line buffer and, on (re)connect, the daemon replays the pane's full tmux history back into it (`capture-pane -pe -S -50000`, CROW-606). To get there, Crow deliberately strips a full-screen app's scroll ownership at three layers:

1. `crow-tmux.conf` — `set -gw alternate-screen off` keeps inner apps in the pane's **main** buffer (no alt buffer).
2. `crow-tmux.conf` — `terminal-overrides ',xterm*:smcup@:rmcup@,screen*:smcup@:rmcup@'` cancels the **client's** alt-screen capability too.
3. `web/terminal.js` — `swallowMouseMode` drops the DECSET 1000–1016 mouse-tracking sequences an agent emits to claim the wheel; `enableWheelScroll` owns the wheel and scrolls xterm's buffer.

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

The spike left this open, offering (a) scope the `smcup@/rmcup@` strip to non-agent surfaces, or (b) signal window-kind to the web client. **Option (a) turned out to be unimplementable**, verified against a live server during #824:

- `terminal-overrides` is a **server** option matched on the **client's `TERM`**, not on a window.
- `tmux list-clients` shows **one client serving every tab** — each web surface opens a single grouped `crowd-web-*` session and switches tabs with `select-window`. smcup is emitted once for the whole attachment, so there is no per-window client buffer state to scope.

So `term.buffer.active.type` is **permanently `'normal'`** on the web client, and routing on it cannot work. (The spike's Option B prototype did exactly that and was therefore inert: its `swallowMouseMode` early-return never fired, and its `mouseTrackingMode` fallback was suppressed by the very swallow it was meant to gate — a circular dependency that latched into the plain-shell path.)

**Chosen: (b), carried on the existing `list-terminals` RPC payload.** `crowd` emits a per-terminal `agent_surface` flag beside the existing `scrollback_degraded`, and `terminal.js` routes on it. The flag's source of truth is the `alternate-screen` **window option the daemon actually set**, read back via `#{alternate-screen}` in the same `list-windows` call that feeds degraded-detection — so daemon and client agree by construction, with no window-name matching. The `/terminal` socket was deliberately not used: its server→client direction is binary-only through a single writer task, so adding text frames would mean widening the stream type and racing that writer.

Classification is `SessionTerminal.isAgentSurface(session:)` — a managed work terminal, **or** a Manager session's terminal that carries a launch `command`. Every part is load-bearing, and the simpler alternatives all fail:

- `agentKind` never discriminates: it always resolves to a configured default, so every terminal has one.
- `trackReadiness` is `false` for Manager sessions, precisely because they launch the agent via `command`.
- `isManaged` **alone** under-classifies: `createManagerTerminal` builds its row without that flag, so it takes the memberwise default of `false` — yet the Manager runs a full-frame repainting agent and is one of the windows #822 was reported against.
- Session kind **alone** over-classifies in the other direction: a Manager session can hold additional plain shells (`new-terminal` with just a `session_id`), and those are line-streaming surfaces that must keep the unified scrollback. The `command != nil` test separates the Manager's agent terminal from them.

Boundary accepted: an extra Manager-session terminal created with an explicit `--command` is treated as an agent surface. The alternative is persisting a new per-terminal field; the cost here is only that a hand-launched full-screen program in that one spot gets the naked-terminal scroll model.

The predicate lives in `CrowCore` because the daemon needs it twice — to set the window option at creation/adopt, and as the `list-terminals` fallback before a window exists — and those two must not drift apart.

### Amendment — #850: forward an agent's wheel ONLY while it is mouse-tracking

The original decision forwarded an agent surface's wheel to the app unconditionally, expecting the app to scroll its own transcript "like a naked terminal." In practice Claude Code and Cursor do **not** enable mouse tracking at their idle prompt, so the forward fell to `sendScrollToPTY`'s cursor-key branch — and the agent read those arrow keys as **input-history navigation**, not scrollback (#850). Every wheel notch stepped through past prompts.

`appOwnsScroll` is refined so a **known agent surface forwards only while it is actively mouse-tracking** (the wheel becomes an SGR wheel button it scrolls its transcript with). At a plain prompt (no tracking) the wheel scrolls xterm's local viewport instead — on the scrollback-less alt buffer a harmless no-op, but never history nav. This is the behavior the desktop terminal and `web/terminal.html` already had (neither forwards a non-mouse wheel), so the amendment brings `terminal.js` to parity across surfaces. `enableTouchScroll` shares the predicate, so touch-drag matches. The alt-screen model itself is unchanged; only the wheel/touch *routing* on an agent surface is tightened. The cursor-key branch of `sendScrollToPTY` survives solely as the pre-classification alt-buffer fallback for genuine full-screen apps (less/vim).

### Amendment — #1008: inline-rendering agent surfaces need a second sediment kill

ADR-0013 assumed every agent TUI would *enter* the alt buffer once Crow set `alternate-screen on`. tmux can only *honor* an app's `smcup`; it cannot force an app that never requests it. Live measurement against `crow-tmux.sock` (2026-08-13) showed Claude Code at `alternate_on=1 history_size=0`, and every Cursor window — including a Cursor Manager — at `alternate_on=0` with `history_size` climbing through thousands of lines while `alternate-screen on` sat inert. Cursor's `agent` CLI has no fullscreen / TUI-mode flag. The classifier and the window option were not the bug; the model had no path for an agent surface that paints inline.

Two additions, keyed off a per-agent capability rather than a Cursor special case (ADR-0014):

1. **`CodingAgent.usesAlternateScreen`.** Claude Code is `true`. The protocol default is `false` (inline renderer) so an unverified harness takes the clamp rather than silently accumulating sediment. Opt in with `true` once a live pane shows `alternate_on=1`.
2. **For `usesAlternateScreen == false`, clamp the window's `history-limit` to 0 at birth** (session-option sandwich around `new-window`; the limit is frozen at creation, so a later `setw` does not stick). Crow still sets `alternate-screen on` so `list-terminals` `agent_surface` — sourced from that option — stays the same signal. The client additionally caps the shared xterm's `scrollback` to 0 while an agent surface is attached, because the wheel at a non-mouse-tracking prompt scrolls xterm's *local* viewport (#850) and live attach bytes would otherwise fossilize there even when tmux history is empty. Plain shells keep the unified 50k + CROW-606 replay.

`isScrollbackDegraded` treats an agent window at `history-limit 0` as healthy; a plain shell at 0 is still a CROW-804 casualty. Existing inline-agent windows cannot have their cap retrofitted on adopt — Recreate remains the tmux-side path; the client scrollback cap is the immediate wheel fix without a restart.

### Amendment — #1010: inline agents are a third surface class, not a sediment case

#1008/#1009 treated every `agent_surface` as needing a scrollback-less buffer. That premise is false for Cursor. Live capture against `crow-tmux.sock` (2026-08-13) of a Cursor window's 900+ line history showed each distinctive footer/banner element **exactly once** — a clean transcript, not stacked frames. Cursor neither mouse-tracks at its prompt (`mouse_any=0`) nor enters the alt buffer (`alternate_on=0`). `appOwnsScroll` is therefore `false` and the wheel falls to the #850 local-viewport path. Capping that viewport to 0 (`applySurfaceScrollback` keyed on `agent_surface`) made the wheel a no-op. Claude Code was unaffected: it mouse-tracks and lives in the alt buffer, so its wheel is forwarded as SGR.

There are **three** surface classes, not two:

| Surface | Example | `agent_surface` | `usesAlternateScreen` | Scrollback | Wheel |
|---|---|---|---|---|---|
| Plain shell | `git log`, review diffs | false | n/a | unified 50k + CROW-606 replay | local viewport |
| Alt-buffer agent TUI | Claude Code | true | true | none (alt buffer; client cap 0) | forwarded while mouse-tracking |
| Inline-streaming agent | Cursor | true | false | unified 50k + CROW-606 replay | local viewport (same as a shell) |

`agent_surface` (the `alternate-screen` option read-back) stays the wheel/mouse-swallow axis. Scrollback removal gates on `usesAlternateScreen` / `uses_alternate_screen` instead:

1. **Server.** The CROW-1008 `history-limit 0` sandwich around `new-window` for `usesAlternateScreen == false` is retracted. Inline agent windows are born at the unified 50k. Alt-buffer agents never needed the clamp (the alt buffer has no history). Leftover windows born under the clamp fail the history floor and are badged ⚠ Recreate — the limit is frozen at birth.
2. **Client.** `applySurfaceScrollback` caps xterm `scrollback` to 0 only when `agent_surface && uses_alternate_screen`. An inline agent, a plain shell, or a missing flag (older daemon) keeps `UNIFIED_SCROLLBACK`.
3. **Plumbing.** `list-terminals` grows a sibling `uses_alternate_screen` flag, sourced from `AgentRegistry.usesAlternateScreen(for:)` (the same capability `registerTerminal` already received). `agent_surface` is unchanged.

The `usesAlternateScreen` capability itself stays (ADR-0014): Claude Code is `true`, the protocol default is `false`. Unknown/nil kinds now resolve `false` so an unverified harness keeps the wheel rather than losing it.

### Amendment — #1023: `uses_alternate_screen` is per-window RUNTIME-detected, not a per-kind capability

#1010 sourced `uses_alternate_screen` from the static `CodingAgent.usesAlternateScreen` capability (Claude Code `true`). That assumes a harness's alt-buffer behavior is a property of the *kind*. It isn't — it is a property of the **build**. Live diagnosis on 2026-08-14 across two machines, both on latest crow, found two Claude Code builds that diverge:

| Claude Code build | `alternate_on` | `mouse_any` | Renders | Scroll under #1010 |
|---|:---:|:---:|---|---|
| `2.1.233` | 1 | 1 | alt buffer, full-frame repaint | works — SGR-forwarded wheel |
| the reported build (version TODO — capture `claude --version` on the inline machine) | 0 | 0 | **inline** (main buffer), streams | **dead** — capped-0, wheel no-op, no gutter |

For the inline build, the hardcoded `usesAlternateScreen = true` is simply wrong: `applySurfaceScrollback` caps its xterm scrollback to 0 (nothing to wheel, no reserved gutter → no scrollbar) *and* `appOwnsScroll` never forwards the wheel (not mouse-tracking) → `term.scrollLines()` against a zero-length buffer, a silent no-op. This is the unrestored half of #1009 (which #1014 fixed for inline agents *by kind* — but the kind is `claudeCode`, so an inline Claude was excluded). An inline Claude's transcript is a clean native scrollback — the #1010 Cursor case exactly (confirmed on live data: a `Cursor` Manager window on the `2.1.233` machine sat at `alternate_on=0` with a clean, non-stacked 628-line transcript).

A per-kind value cannot describe both builds. **The `alternate-screen` window OPTION** (which sources `agent_surface`) is always `on` for an agent window and so cannot tell them apart either. Only the **runtime `#{alternate_on}` pane state** — which the daemon *already reads* in `listWindowScrollback` for CROW-804 degraded-detection, then discarded — separates an app that entered the alt buffer from one that never did.

`uses_alternate_screen` therefore moves from the static capability to a **per-window runtime detection, latched sticky**:

1. **Server.** `windowScrollbackClassification` returns a third set, `altBuffer`, maintained by the pure `TmuxBackend.updatedAltBufferLatch`: the union of every window ever observed at `alternate_on=1`, pruned to windows that still exist. **Sticky** so a build that enters the alt screen once keeps the capped-0 model through its transient main-buffer drops (a shell-out, exit) instead of flip-flopping xterm's scrollback every poll; the latch is also cleared per index at (re)registration and kill so a recycled tmux index never inherits a stale observation. No extra tmux round-trip — the value rides the existing `list-windows` read.
2. **Emission.** `list-terminals` reports `uses_alternate_screen = altBuffer.contains(windowIndex)` when tmux answered and the terminal has a window; otherwise (pre-window, or read failure) it falls back to the static `AgentRegistry.usesAlternateScreen` prior — mirroring exactly how `agent_surface` falls back to `isAgentSurface`.
3. **Client — one nudge, else no rewiring.** `applySurfaceScrollback` and `fireScrollbackCapture` already gate on `agent_surface && uses_alternate_screen`, so the inline Claude inherits the Cursor treatment (unified 50k, CROW-606 replay, CROW-934 hydrate, CROW-1020 grabbable bar, #850 local wheel) for free. Because `list-terminals` is not polled, `maybePollAltScreenLatch` re-reads it on a bounded schedule while the attached surface is an unlatched agent, so an alt-buffer build's cap-to-0 isn't stranded behind the first (pre-alt) snapshot. One consistency fix: `verifyScrollbackAfterAttach` (CROW-1027 post-attach one-screen heal) moves off `agent_surface`-alone onto the same `&& uses_alternate_screen` axis, so an inline agent (and Cursor) also gets that heal; a true alt-buffer agent is still skipped.

The static `CodingAgent.usesAlternateScreen` capability is demoted to the **pre-window prior** (keep it matching the *common* build so the brief pre-window window is right); the runtime read is the source of truth once a window exists.

**Consequence — a startup transient + a bounded client re-poll.** An alt-buffer build (`2.1.233`) reports `uses_alternate_screen=false` between its window's creation and its first `alternate_on=1` — often several seconds, because a managed agent launches only at `.shellReady` and enters the alt screen later still. `list-terminals` is **not** polled (`onServerChanged`/`refreshLive` don't re-read it), so the client cannot passively wait for the flip: it would leave xterm at `UNIFIED_SCROLLBACK` and the alt-buffer agent's live frames would fossilize in the local viewport — a #822 regression. The client therefore re-reads `list-terminals` on a short bounded schedule (`maybePollAltScreenLatch`, ~1s × 15) **while the attached surface is an agent that hasn't latched**, stopping the moment it latches (`applySurfaceScrollback` caps to 0 and xterm discards the frames that fossilized meanwhile) or when the budget is spent — at which point it is a genuinely inline build that correctly keeps the 50k. The visible effect is a 14px gutter for the first second or two of a starting alt-buffer tab. The alternative (prior = capped) risks leaving a genuinely inline build capped-0 forever behind an unreliable "is it inline yet?" timeout, so the inline-until-proven-alt default + bounded re-poll is deliberate.

**Residual risk — the inline Claude transcript's cleanliness is inferred, not measured on that build.** The clean-transcript evidence is Cursor (and the mechanism — an app that never enters alt and never mouse-tracks is doing inline in-place repaint, the Cursor/Ink shape). If the inline Claude build full-frame-repaints into the main buffer instead, 50k could show some #1008-style duplication. Bounded: even then a working-but-slightly-duplicated scrollback with a grabbable bar strictly beats a dead wheel and no bar, and it is no worse than what Cursor users accept. Verify on the inline-build machine (`capture-pane -pe -S -2000`, eyeball for stacked frames) before merge; if it sediments, the detection still routes correctly and a bounded-dedup follow-up is the remedy — the fix is not lost.

The surface-class table is unchanged in shape, but the `usesAlternateScreen` column is now a **detected per-window** value; Claude Code appears in *either* the alt-buffer row (a build that enters alt) or the inline row (a build that doesn't), per its runtime `alternate_on`.

### Amendment — #1035 (reopened): in-place agent switch must not `term.reset()` or replay scrollback

#1036 made agent tab/session switches in-place instead of the #673 full reload, which was the right attach path — but it still called `term.reset()` before `select-window`. That nukes parser state (including `mouseTrackingMode`, CROW-1043) that tmux re-sends only as **deltas**, so an alt-buffer Claude's live redraw after reset parks the caret below the TUI input box even though the daemon already skipped the CROW-606 replay for `alternate_on=1`. Inline agents (Cursor) still took the replay on every in-place switch; #1048 stopped mid-session hydrate from doing the same thing, but connect/switch replay remained — a `capture-pane` dump of the idle chrome on top of the live attach is the one-line stack and viewport shift.

**Fix:**

1. **`switchAgentWindow` clears with `ESC[H ESC[2J ESC[3J` instead of `term.reset()`.** Same leading sequence as `replayFrame`, so old window cells/scrollback are dropped without clearing DECSET modes tmux won't re-emit. Shell switches still use `reloadTerminal()` → full reset.
2. **In-place agent switches send `select-window` with `replay: false`.** Connect, reload, CROW-934 hydrate, and CROW-1027 heal keep the default (replay when `alternate_on=0`). The daemon's existing alt-buffer skip remains as a backstop.

Mouse re-arm (CROW-1043) stays on every `select-window`, including `replay: false`.

### Amendment — #1043: `select-window` must re-arm the pane's mouse mode after the in-place switch's reset

#1035 made an agent tab/session switch happen **in place** (`clearTermBuffer()` + `select-window` with `replay: false` on the live socket) instead of the #673 full reload. An earlier pass used `term.reset()`, which also cleared xterm's `mouseTrackingMode` — and for an **alt-buffer** agent that is the surface's *only* scroll path. An alt-buffer Claude has `scrollback` capped to 0 (no local buffer, no bar); its wheel works solely because `appOwnsScroll()` is `agent_surface && mouseTracking` and the tick is forwarded to Claude as an SGR wheel button (#850). Clear `mouseTrackingMode` and `appOwnsScroll()` returns `false`, the wheel falls to a zero-length local viewport, and the surface is **dead to the wheel**.

The redraw that follows `select-window` does **not** reliably put the mode back. tmux emits mouse-mode changes to a client as **deltas**: switching between two agent windows that share the same mouse state (Claude → Claude, or the Manager, both `mouse_any=1 mouse_sgr=1`) repaints the frame but no mouse DECSET, because from tmux's view the client already has that mode — while the client just cleared it. An explicit **Reload** recovers because it is a fresh grouped attach, where tmux emits the full initial state (including `?1000h`/`?1006h`); the next in-place switch clears it again. This was the CROW-1043 "unscrollable after switching, Reload fixes it, switch away and back and it's dead again" report, reproduced live: `mouseTrackingMode` `any → none` and `appOwnsScroll()` `true → false` across one round-trip switch between two Claude sessions.

**Fix: the daemon re-arms the pane's actual mouse mode on every `select-window`.** `TerminalWebSocket` reads `#{mouse_standard_flag}#{mouse_button_flag}#{mouse_any_flag}#{mouse_utf8_flag}#{mouse_sgr_flag}` for the pane and yields the matching DECSET enables (`TerminalCockpit.mouseModeReArmSequence` → e.g. `?1003h?1006h` for a Claude pane) into the same stream as the replay, so the client's mode matches the pane deterministically, independent of tmux's per-client delta. It is:

- **inert where it isn't needed** — a plain shell (or an agent idling without tracking) reports no mouse flag, so nothing is emitted; and on a non-agent surface `swallowMouseMode` drops DECSET 1000–1016 anyway, so a shell running a mouse app is unaffected;
- **idempotent** — re-emitted on the connect select and on the CROW-934/1027 hydrate/heal re-selects with no effect beyond re-asserting the same mode;
- **visually inert** — it sets an input mode only and paints nothing, so unlike a scrollback replay it cannot race the live frame or blank the pane. This is deliberately **orthogonal** to the CROW-606 replay: the replay stays skipped for an alt-buffer pane (`shouldReplayScrollback` unchanged — an alt-buffer Claude has `history_size=0`, so there is no unified scrollback to restore), and the mouse re-arm is what actually rescues that surface's wheel.

Inline/agent surfaces that keep the unified scrollback are unaffected in the case that matters to them: they are `alternate_on=0`, so the replay already runs, and their wheel scrolls the local viewport regardless of mouse mode. The re-arm simply keeps `mouseTrackingMode` truthful for any agent that *is* tracking.

### Amendment — #1048: mid-session hydrate is a shell feature, not an inline-agent one

#1010/#1014 restored the unified 50k on inline agents so the wheel works. #1023 then left Cursor (and an inline Claude) on the same CROW-934/CROW-1026 hydrate axis as a shell: "they CAN thin, so they stay eligible." That premise is the #1014 sediment.

Cursor never issues `smcup`. Its live bytes **are** the transcript — a few lines of chrome after each tool call, not `seq 1 20000`. After that output goes quiet, `hydrateWhenIdle` (400ms) fires `select-window` → `capture-pane` replay onto a TUI that already painted its tip / model line / cwd. The replay's tail is that same chrome; the live attach paints it again. Result: stacked idle chrome in the live view, not only when scrolling history. Arrival-at-top hydrate does the same thing to history. `switchAgentWindow` arming the CROW-1027 heal added a second replay 250ms later on every in-place switch (no PTY resize, so nothing to heal).

**Decision.** Mid-session re-capture is a *shell* feature.

1. **`fireScrollbackCapture` / `maybeHydrateScrollback` skip every `agent_surface`.** Alt-buffer was already out (capture is the live frame). Inline is now out because the replay is harmful, not empty. Connect/reload still restore CROW-606 history; in-place agent switches pass `replay: false` (CROW-1035). xterm stays at `UNIFIED_SCROLLBACK` so the wheel still works. Do **not** re-introduce the #1008 `history-limit 0` / client cap.
2. **`switchAgentWindow` does not arm CROW-1027.** In-place switch has no new PTY and no SIGWINCH. Connect/reload still heal a one-screen attach — that path really does resize first.

Claude's alt-buffer path is unchanged: it already skipped hydrate, still caps xterm to 0, still forwards the wheel while mouse-tracking.

### Amendment — #1047: alt-buffer cap and SGR wheel must not yank mid-scroll

Two paths made wheel-up in Claude Code land on line 1 of the transcript instead of moving a few lines.

1. **Defer the cap-to-0 while mid-history.** CROW-1023's alt latch can flip `uses_alternate_screen` several seconds after launch, while xterm still holds the transitional 50k. Wheel-up through that buffer, then an immediate cap, truncates scrollback and leaves `ydisp` at 0 on the oldest surviving lines — session start. `applySurfaceScrollback` now waits until `viewportY >= baseY` before capping; `maybePollAltScreenLatch` re-calls it on every `refreshTerminals` pass until the cap lands.
2. **One DOM wheel event → one forwarded notch.** Line/page `deltaMode` could emit many notches per event; repeated SGR wheel reports made Claude's mouse-tracking scroll jump to the top. `wheelNotches` magnitude-snaps those modes like pixel mode (CROW-835). `hydrateWhenIdle` also skips every `agent_surface` beside CROW-1048's capture gate.

Inline agents and shells are unchanged except shells inherit the idle-hydrate defense-in-depth. Cursor's local wheel path is untouched.

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
  - **CROW-606 replay is skipped for alt-buffer panes (CROW-1035).** `capture-pane -pe -S -50000` on an alt-buffer pane returns just the current frame, and injecting that line-oriented dump after `select-window` races the live attach redraw: the caret lands below the TUI input box (Claude) and footer chrome stacks (Cursor, from the reload's 24×80→real-size SIGWINCH). `replayData` now returns `nil` when `#{alternate_on}=1`; the live attach already has the frame. In-place agent switches also pass `replay: false` for inline agents. Shells and connect/reload still get the capture + `ESC[H ESC[2J ESC[3J]` rebuild. Tab/session switch to an agent surface is in-place (`clearTermBuffer` + `select-window` on the live socket) rather than the #673 full reload — that reload is what introduced the 24×80 SIGWINCH. Explicit Reload and plain-shell tab switches keep the reload.
  - **Jump-to-bottom pill** keys off `viewportY >= baseY`. On an agent surface tmux repaints in place, the client's scrollback never grows, both stay 0, and the pill correctly stays hidden — there is nothing to jump back to. No change needed.
  - **Copy/paste** is the one real regression: native drag-select and the right-click menu are eaten inside agent windows, because they worked *because* of the mouse-mode swallow. Mitigated by enabling `macOptionClickForcesSelection` so ⌥-drag forces selection (xterm.js defaults that option to `false`, so it must be set explicitly), surfaced as a hint in the terminal context menu. Plain shells are unaffected.
- **A degraded-window blind spot.** `isScrollbackDegraded` now takes `alternateScreenEnabled`, so an agent surface in the alt buffer is healthy rather than badged ⚠ Recreate. The consequence is that an agent window *genuinely* wedged in the alt buffer at the full 50000 limit is no longer distinguishable from the normal state. The `history_limit` floor still catches the real #804/#821 casualties, which measured `history_limit=5000`.
- **The window option is frozen at creation.** tmux applies `alternate-screen` per window, and a `source-file` reload does not retrofit it. Windows adopted from a previous crowd are re-applied on adopt, but a *live* agent keeps its current buffer until it restarts; the ⚠ Recreate affordance remains the immediate manual path. The same freeze applies to `history-limit`: an inline agent window born under the retracted CROW-1008 clamp (`history-limit 0`) stays at 0 until Recreate, and is now badged degraded so that heal is visible (CROW-1010).
- **Three surface classes, but Claude Code is no longer pinned to one.** A Claude Code *build that enters the alt buffer* owns a scrollback-less alt buffer (client xterm cap 0); an *inline-rendering* Claude build, Cursor, and any harness that never reaches `alternate_on=1` keep the unified 50k + CROW-606 replay and scroll like a shell via the local viewport. Which class a Claude tab lands in is now decided per-window from the runtime `alternate_on` (CROW-1023), not the per-kind capability. The CROW-1008 `history-limit 0` clamp + blanket client cap remain retracted. Leftover 0-limit windows Recreate.
- **Runtime detection re-latches without a restart — unlike the frozen window option.** The `agent_surface` option is frozen at window birth (above), but `uses_alternate_screen` is re-derived from `alternate_on` on each `list-terminals` read and latched (CROW-1023), so a build that enters or never enters the alt buffer is classified correctly without a Recreate. Because `list-terminals` is not otherwise polled, the client drives a bounded re-read (`maybePollAltScreenLatch`) while an attached agent surface is still unlatched, so the alt-buffer cap isn't stranded behind the first snapshot. The one transient: an alt-buffer build shows a scrollbar gutter for the first second or two before it latches (history is empty then, so cosmetic only).

## Alternatives considered

- **Option A — honor the alt screen everywhere** (`alternate-screen on` globally, drop the smcup strip, stop swallowing mouse modes, forward the wheel to the app). Simplest and fully fixes the sediment (spike-proven: `history_size` 1641→0, 42 copies→1). Rejected because it deletes the unified scrollback for *all* surfaces — plain shells lose native wheel scrollback and CROW-606 replay has nothing to restore (`history_size=0`) — regressing CROW-606/#776/#777 to fix a problem only agent TUIs have. Kept on throwaway branch `spike/822-option-a`.
- **Option C — dedupe repaints in the unified buffer.** Rejected up front: there is no reliable way to recognize and collapse full-frame TUI repaints in a linear text buffer.

## References

- Spike: [#822](https://github.com/corveil/crow/issues/822); findings + prototype details in [`docs/spikes/822-terminal-scroll.md`](../spikes/822-terminal-scroll.md).
- Prototype branches (not merged): `spike/822-option-a`, `spike/822-option-b`.
- Related ADRs: [0001 — tmux as the sole terminal backend](./0001-tmux-only-terminal-backend.md) (this ADR carves the scroll model out of ADR-0001's terminal-backend scope; ADR-0001 is otherwise unchanged).
- Prior art: CROW-606 (replay, #609/#612), #776/#789 (mouse-mode swallow), #777/#786 (iOS touch-scroll ownership), #804/#821 (scrollback heal), epic #783 (replay reflow fidelity).
- Implementation: [#824](https://github.com/corveil/crow/issues/824); wheel/touch routing [#850](https://github.com/corveil/crow/issues/850); inline-agent sediment [#1008](https://github.com/corveil/crow/issues/1008); Cursor wheel regression [#1010](https://github.com/corveil/crow/issues/1010); per-window alt-buffer detection [#1023](https://github.com/corveil/crow/issues/1023); session-switch cursor jump [#1035](https://github.com/corveil/crow/issues/1035); session-switch dead wheel [#1043](https://github.com/corveil/crow/issues/1043); inline-agent hydrate sediment [#1048](https://github.com/corveil/crow/issues/1048).
- Code: `crow-tmux.conf` (alt-screen default, smcup/rmcup, mouse, history-limit); `TmuxController.setWindowOption` / `setSessionOption` / `listWindowScrollback` (per-window option + the `#{alternate-screen}` and `#{alternate_on}` read-back); `TmuxBackend.registerTerminal(agentSurface:usesAlternateScreen:)`, `enableAlternateScreen`, `isScrollbackDegraded(alternateScreenEnabled:)`, `agentSurfaceWindowIndices`, `updatedAltBufferLatch` / `altBufferWindowIndices` / `observedAltBufferWindows` (CROW-1023 sticky detection); `CodingAgent.usesAlternateScreen` (now the pre-window prior); `EngineRouter` `list-terminals` (`agent_surface`, `uses_alternate_screen` from the detected `altBuffer` set); `web/terminal.js` (`activeSurfaceIsAgent`, `activeSurfaceUsesAltScreen`, `applySurfaceScrollback`, `maybePollAltScreenLatch`, `appOwnsScroll`, `swallowMouseMode`, `enableWheelScroll`, `enableTouchScroll`, `sendScrollToPTY`, `verifyScrollbackAfterAttach`); `TerminalCockpit.swift` (CROW-606 replay + `mouseModeReArmSequence` / `mouseModeReArmData` CROW-1043) / `TerminalWebSocket.swift` (select-window emits the mouse re-arm then the replay).
- Tests: `ScrollbackHealthTests` (kind-aware policy truth table; leftover inline `history-limit 0` is degraded; CROW-1023 `updatedAltBufferLatch` sticky/prune/inline-never-latches truth table); `TmuxControllerTests.agentWindowOptsIntoAlternateScreenWithoutAffectingSiblings` / `sessionHistoryLimitSandwichClampsOnlyTheNewWindow` (real-tmux freeze); `TmuxBackendTests.inlineAgentSurfaceKeepsUnifiedHistoryWithoutAffectingSiblings`; `WebTerminalAssetTests` (client routing shape + alt-buffer-only scrollback cap + CROW-1035 in-place agent switch + CROW-1048 mid-session hydrate skip); `TerminalReplayTests.altBufferPaneSkipsScrollbackReplay` + `.mouseModeReArm*` (CROW-1043 DECSET builder truth table); `web-tests/wheel-scroll.test.js` (jsdom wheel + inline agent keeps `UNIFIED_SCROLLBACK`); `web-tests/terminal-reload.test.js` (CROW-1027/1023 post-attach heal: alt-buffer skips, inline heals on connect/reload); `web-tests/alt-latch-poll.test.js` (CROW-1023 bounded re-read: arms only for an unlatched agent surface, latches then stops, bounded budget for inline builds); `web-tests/session-switch-attach.test.js` (CROW-1035: agent switch is in-place, no CROW-1027 recapture); `web-tests/scrollback-hydrate.test.js` (CROW-1048: inline agent never mid-session re-syncs).
