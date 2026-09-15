'use strict';
// Crow web UI — Terminal tab bar: refresh/render/switch/add/close/recreate.
// Extracted from session.js (CROW-1257).

async function refreshTerminals() {
  try {
    const res = await rpc('list-terminals', { session_id: selectedId });
    terminals = res.terminals || [];
  } catch (_) {
    terminals = [];
  }
  // Rebind to the FRESH row, don't just check the old one is still present.
  // `activeTerminal` is not merely a selection marker: `agent_surface` drives
  // the wheel/mouse routing (ADR-0013) and `window` drives attachWindow, and
  // both can change under a stable id — `agent_surface` starts as the
  // pre-binding fallback and becomes authoritative once the tmux window exists
  // or an adopt re-applies the option. Keeping the stale object left routing on
  // the old value until the user happened to switch tabs.
  //
  // A terminal id from the URL (CROW-936) wins for exactly one pass, so a cold
  // #/sessions/<id>/t/<tid> load restores that tab instead of terminals[0].
  activeTerminal = (pendingTerminalId && terminals.find((t) => t.id === pendingTerminalId))
    || terminals.find((t) => t.id === (activeTerminal && activeTerminal.id))
    || terminals[0] || null;
  pendingTerminalId = null;
  applySurfaceScrollback();
  // CROW-1023: keep re-reading list-terminals while the attached surface is an
  // agent that hasn't latched into the alt buffer yet, so an alt-buffer build's
  // cap-to-0 isn't stranded behind the un-polled first snapshot (review).
  maybePollAltScreenLatch();
  // Whenever the URL names a terminal this session no longer has — a dead id
  // from the link, or a tab that has since been closed — point it at whatever
  // we actually landed on. Running on every pass rather than only the routed one
  // is what covers the second case; note refreshTerminals is not polled, so a
  // tab closed from *another* client is corrected on this client's next action
  // rather than live (review).
  const shown = currentRoute();
  if (selectedId && shown && shown.view === 'session' && shown.sessionId === selectedId
    && shown.terminalId && !terminals.some((t) => t.id === shown.terminalId)) {
    navigate({
      view: 'session',
      sessionId: selectedId,
      terminalId: activeTerminal ? activeTerminal.id : null,
    }, { replace: true });
  }
  renderTabs();
  // CROW-979: this call is what binds `activeTerminal`, and the header's ↻ Reload
  // is disabled until there is one. selectSession renders the header *before*
  // awaiting this, so without a nudge the button would sit disabled until the next
  // 4s refreshLive tick.
  syncTerminalReloadEnabled();
  // Session/tab switches funnel through here too (selectSession → refreshTerminals),
  // changing which window this shared socket shows. attachWindow is a no-op when
  // the window didn't change, so a same-session background refresh stays put.
  // Agent surfaces switch in place (CROW-1035); shells still take the #673 reload.
  if (activeTerminal) attachWindow(activeTerminal.window);
}

function renderTabs() {
  const bar = document.getElementById('tabbar');
  bar.innerHTML = '';
  // #680: managers are a single terminal — no tabs, no "+", no "×". The bar
  // stays empty so there is no stale tab label, but CROW-1162 keeps the 34px
  // slot (`#tabbar:empty { display:flex }`) so Manager ↔ work switches don't
  // SIGWINCH the agent by collapsing/expanding the tab strip.
  const sel = sessions.find((x) => x.id === selectedId);
  if (sel && sel.kind === 'manager') {
    // #680: managers have no tabs. But the Manager window is a common CROW-804
    // "stuck alt-screen / 5000-line" case, and with no tab there'd be no ⚠ or
    // Recreate. Surface a slim warning strip with a Recreate action when the
    // Manager terminal is degraded; otherwise leave #tabbar empty (the slot
    // still reserves 34px). Recreate routes through restartManager (SessionService).
    const degraded = terminals.find((t) => t.scrollback_degraded);
    if (degraded) {
      const strip = el('div', 'degraded-strip');
      strip.appendChild(el('span', 'tab-degraded', '⚠'));
      strip.appendChild(el('span', 'degraded-msg', 'Scrollback degraded — this Manager window can\'t show full history.'));
      const btn = el('span', 'degraded-recreate', 'Recreate');
      btn.title = 'Rebuild this Manager terminal to restore full scroll-up history (restarts the agent).';
      btn.onclick = () => recreateTerminal(degraded);
      strip.appendChild(btn);
      bar.appendChild(strip);
    }
    return;
  }
  for (const t of terminals) {
    const tab = el('div', 'tab' + (activeTerminal && t.id === activeTerminal.id ? ' active' : ''));
    const label = el('span', null, t.name);
    label.onclick = () => switchTerminal(t);
    tab.appendChild(label);
    // CROW-804: this terminal's tmux window is stuck with degraded scrollback
    // (alternate-screen buffer and/or the old 5000-line history-limit) that
    // tmux can't fix in place. Badge it and offer a one-click recreate.
    if (t.scrollback_degraded) {
      const warn = el('span', 'tab-degraded', '⚠');
      warn.title = 'Scrollback degraded — this window can\'t show full history (created before the current config). Click to recreate it and restore scroll-up.';
      warn.onclick = (e) => { e.stopPropagation(); recreateTerminal(t); };
      tab.appendChild(warn);
    }
    const close = el('span', 'tab-close', '×');
    close.onclick = (e) => { e.stopPropagation(); closeTerminal(t); };
    tab.appendChild(close);
    bar.appendChild(tab);
  }
  const add = el('div', 'tab add', '+');
  add.onclick = addTerminal;
  add.title = 'New terminal';
  bar.appendChild(add);
}

function switchTerminal(t) {
  // The terminal segment is written here and nowhere else: opening a session
  // leaves the URL at #/sessions/<id>, which reloads onto terminals[0] — the
  // same tab — so nothing is lost and clicking a session doesn't bury the
  // history under an id the user never chose. Guarded on selectedId because
  // routeToHash falls through to '#/' without one, which would navigate a tab
  // switch to home.
  if (selectedId) navigate({ view: 'session', sessionId: selectedId, terminalId: t.id });
  activeTerminal = t;
  applySurfaceScrollback();
  // CROW-1023: a tab switch is a bind of `activeTerminal` just like a
  // refreshTerminals pass, so it must (dis)arm the alt-buffer latch poll too —
  // otherwise switching away from a still-starting Claude tab and back (e.g.
  // opening a shell while it launches) reapplies the stale `false` row and never
  // re-reads, re-stranding the cap-to-0 (review). Leaving disarms; returning to
  // a still-unlatched tab gets a fresh budget (disarm nulls the tracked id).
  maybePollAltScreenLatch();
  renderTabs();
  // Window change is attachWindow's job. Shells still take the #673 full
  // reload (reset + fresh socket) so a surface another client reshaped
  // self-heals. Agent TUIs switch in place — the reload's new PTY (24×80
  // then SIGWINCH) is what jumps Claude's caret and doubles Cursor chrome
  // (CROW-1035). Re-clicking the active tab is a no-op (win === attachedWindow).
  attachWindow(t.window);
  if (term) term.focus();
}

async function addTerminal() {
  if (!selectedId) return;
  try {
    const res = await rpc('new-terminal', { session_id: selectedId });
    await refreshTerminals();
    const created = terminals.find((t) => t.id === res.terminal_id);
    if (created) switchTerminal(created);
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] new-terminal failed: ' + (e.message || e) + '\x1b[0m\r\n');
  }
}

async function closeTerminal(t) {
  try { await rpc('close-terminal', { session_id: selectedId, terminal_id: t.id }); } catch (_) {}
  if (activeTerminal && activeTerminal.id === t.id) activeTerminal = null;
  await refreshTerminals();
}

// CROW-804: heal a terminal whose tmux window has degraded scrollback. Recreate
// kills the window and rebuilds it under the current config, relaunching the
// agent (`claude --continue`) — so confirm first, since it interrupts whatever
// is running in the pane.
async function recreateTerminal(t) {
  const ok = await confirmModal(
    'This rebuilds “' + (t.name || 'terminal') + '” to restore full scroll-up history. '
    + 'The agent running in it will be restarted (and resumed where the agent supports it).',
    { title: 'Recreate terminal', okLabel: 'Recreate', danger: true });
  if (!ok) return;
  try {
    await rpc('recreate-terminal', { session_id: selectedId, terminal_id: t.id });
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] recreate-terminal failed: ' + (e.message || e) + '\x1b[0m\r\n');
    // Register-then-kill means a failed heal leaves the old window live and
    // still degraded — refresh so the ⚠ / Recreate affordance re-renders for a
    // retry instead of vanishing on a half-applied state.
    await refreshTerminals();
    return;
  }
  await refreshTerminals();
  // Recreate binds a FRESH tmux window, but `new-window` (no -a) reuses the
  // index just freed by killWindow — so the new index usually EQUALS the old
  // one. Even after re-pointing at the refreshed row, attachWindow's
  // `win === attachedWindow` guard would then skip the reload and leave the
  // surface on the dead pane (the stale-*index* case; the stale-*object* case
  // was fixed earlier). Clear attachedWindow so the reattach can't short-circuit,
  // then switch onto the refreshed row — for the primary Manager its id changes,
  // so fall back to the activeTerminal refreshTerminals already swapped in.
  const refreshed = terminals.find((x) => x.id === t.id) || activeTerminal;
  attachedWindow = null;
  if (refreshed) switchTerminal(refreshed);
}
