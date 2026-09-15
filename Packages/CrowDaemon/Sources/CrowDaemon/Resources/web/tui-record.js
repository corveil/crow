'use strict';
// Crow web UI — TUI form-factor recording (CROW-1255). Start/Stop/Mark/HUD live
// here (needs /rpc + session identity). The sampler addon never opens sockets.
// HUD-on without a bind is local-only: collectTuiSample paints the overlay and
// does not termWs.send.

const TUI_STORAGE_KEY = 'crow.tui.recording';
const TUI_HUD_STORAGE = 'crow.tui.hud';

let tuiTrace = null;
let tuiBound = false;
let tuiRecordingId = null;
let tuiHudOn = sessionStorage.getItem(TUI_HUD_STORAGE) === '1';
let tuiPlaybackTerm = null;

function tuiStored() {
  try { return JSON.parse(sessionStorage.getItem(TUI_STORAGE_KEY) || 'null'); }
  catch (_) { return null; }
}
function tuiStore(rec) {
  if (!rec) sessionStorage.removeItem(TUI_STORAGE_KEY);
  else sessionStorage.setItem(TUI_STORAGE_KEY, JSON.stringify(rec));
}

function ensureTuiTrace() {
  if (tuiTrace || typeof CrowTuiTraceAddon === 'undefined' || !term) return tuiTrace;
  tuiTrace = new CrowTuiTraceAddon.CrowTuiTraceAddon({
    onSample: function (sample, force) { sendTuiSample(sample, force); },
  });
  try { term.loadAddon(tuiTrace); } catch (_) {}
  return tuiTrace;
}

function sendTuiSample(sample, force) {
  paintTuiHud(sample);
  if (!tuiBound || !tuiRecordingId) return;
  if (!termWs || termWs.readyState !== (window.WebSocket && WebSocket.OPEN)) return;
  sample.modes.agent_surface = typeof activeSurfaceIsAgent === 'function' && activeSurfaceIsAgent();
  sample.modes.app_owns_scroll = typeof appOwnsScroll === 'function' && appOwnsScroll();
  try {
    termWs.send(JSON.stringify({ type: 'tui-sample', recording_id: tuiRecordingId, sample: sample }));
  } catch (_) {}
}

function tuiBindOnOpen() {
  const stored = tuiStored();
  if (!stored || !stored.recording_id) return;
  if (!termWs || termWs.readyState !== WebSocket.OPEN) return;
  tuiRecordingId = stored.recording_id;
  try { termWs.send(JSON.stringify({ type: 'tui-bind', recording_id: stored.recording_id })); } catch (_) {}
  tuiBound = true;
  ensureTuiTrace();
  if (tuiTrace) tuiTrace.start();
  renderTuiHudChrome();
}

function tuiClearBind() {
  tuiBound = false;
  tuiRecordingId = null;
  tuiStore(null);
  if (tuiTrace) tuiTrace.stop();
  renderTuiHudChrome();
}

async function tuiStartRecording() {
  if (!selectedId || !activeTerminal) return;
  try {
    const res = await rpc('tui-record-start', {
      session_id: selectedId,
      terminal_id: activeTerminal.id,
      expect_bind: true,
    });
    tuiStore({ recording_id: res.recording_id, session_id: selectedId, terminal_id: activeTerminal.id });
    tuiRecordingId = res.recording_id;
    if (termWs && termWs.readyState === WebSocket.OPEN) {
      termWs.send(JSON.stringify({ type: 'tui-bind', recording_id: res.recording_id }));
      tuiBound = true;
    }
    ensureTuiTrace();
    if (tuiTrace) tuiTrace.start();
    tuiHudOn = true;
    sessionStorage.setItem(TUI_HUD_STORAGE, '1');
    renderTuiHudChrome();
  } catch (e) {
    if (typeof alertModal === 'function') alertModal(e.message || 'Could not start recording');
  }
}

async function tuiStopRecording() {
  const stored = tuiStored();
  const id = (stored && stored.recording_id) || tuiRecordingId;
  if (!id) return;
  try { await rpc('tui-record-stop', { recording_id: id }); } catch (_) {}
  tuiClearBind();
}

function tuiMark(note) {
  if (!tuiBound || !tuiTrace) return;
  tuiTrace.noteEvent({ kind: 'mark', at_client: Date.now() });
  if (termWs && termWs.readyState === WebSocket.OPEN) {
    try { termWs.send(JSON.stringify({ type: 'tui-mark', recording_id: tuiRecordingId, note: note || '' })); } catch (_) {}
  }
}

function tuiToggleHud() {
  tuiHudOn = !tuiHudOn;
  sessionStorage.setItem(TUI_HUD_STORAGE, tuiHudOn ? '1' : '0');
  renderTuiHudChrome();
  if (tuiHudOn) {
    ensureTuiTrace();
    const sample = tuiTrace ? tuiTrace.collect() : (CrowTuiTraceAddon && CrowTuiTraceAddon.collectTuiSample(term, {}));
    paintTuiHud(sample);
    if (!tuiBound && tuiTrace) {
      // Local-only: paint, do not send.
      tuiTrace.start();
    }
  } else if (!tuiBound && tuiTrace) {
    tuiTrace.stop();
  }
}

function renderTuiHudChrome() {
  let hud = document.getElementById('tui-hud');
  const wrap = document.getElementById('terminal-wrap');
  if (!wrap) return;
  if (!hud) {
    hud = document.createElement('div');
    hud.id = 'tui-hud';
    hud.innerHTML = '<div id="tui-hud-readout"></div><div id="tui-hud-chip">'
      + '<button type="button" id="tui-hud-record"></button>'
      + '<button type="button" id="tui-hud-mark">Mark</button>'
      + '<button type="button" id="tui-hud-toggle">HUD</button></div>';
    wrap.appendChild(hud);
    document.getElementById('tui-hud-record').onclick = function (e) {
      e.stopPropagation();
      if (tuiBound || tuiStored()) tuiStopRecording(); else tuiStartRecording();
    };
    document.getElementById('tui-hud-mark').onclick = function (e) { e.stopPropagation(); tuiMark(); };
    document.getElementById('tui-hud-toggle').onclick = function (e) { e.stopPropagation(); tuiToggleHud(); };
  }
  hud.hidden = !tuiHudOn && !tuiBound && !tuiStored();
  const recBtn = document.getElementById('tui-hud-record');
  if (recBtn) recBtn.textContent = (tuiBound || tuiStored()) ? 'Stop' : 'Record';
  wrap.classList.toggle('tui-recording', !!(tuiBound || tuiStored()));
}

function paintTuiHud(sample) {
  if (!tuiHudOn && !tuiBound) return;
  const el = document.getElementById('tui-hud-readout');
  if (!el || !sample) return;
  const vv = sample.viewport || {};
  const cur = sample.cursor || {};
  el.textContent = (sample.form_factor || '?')
    + '  ' + (vv.css_cols || 0) + '×' + (vv.css_rows || 0)
    + '  inset ' + (vv.keyboard_inset_px || 0) + 'px'
    + '  cur ' + (cur.xterm_x || 0) + ',' + (cur.xterm_y || 0);
}

function onTuiRecordEvent(params) {
  if (!params) return;
  if (params.kind === 'not_active' && tuiStored() && tuiStored().recording_id === params.recording_id) {
    tuiClearBind();
    return;
  }
  if ((params.kind === 'hud_on' || params.kind === 'hud_off') && params.session_id === selectedId) {
    tuiHudOn = params.kind === 'hud_on';
    sessionStorage.setItem(TUI_HUD_STORAGE, tuiHudOn ? '1' : '0');
    renderTuiHudChrome();
    return;
  }
  const route = typeof currentRoute === 'function' ? currentRoute() : null;
  if (route && route.view === 'tui-recording' && route.recordingId === params.recording_id) {
    appendTuiPlaybackObs(params);
  }
}

function appendTuiMenuItems(items) {
  const rec = tuiStored() || tuiBound;
  items.push({ label: rec ? 'Stop recording' : 'Start recording',
    action: rec ? tuiStopRecording : tuiStartRecording });
  items.push({ label: tuiHudOn ? 'Hide diagnostics HUD' : 'Diagnostics HUD', action: tuiToggleHud });
  if (rec) items.push({ label: 'Mark', action: function () { tuiMark('cursor jumped'); } });
}

// ---- Playback (`#/tui-recordings/:id`) — detached xterm, no /terminal attach.

async function openTuiPlayback(recordingId) {
  const app = document.getElementById('app');
  if (app) {
    app.classList.add('tui-playback-active');
    app.classList.remove('has-selection', 'board-active');
  }
  let pane = document.getElementById('tui-playback');
  if (!pane) {
    pane = document.createElement('div');
    pane.id = 'tui-playback';
    const detail = document.getElementById('detail');
    if (detail) detail.appendChild(pane);
    else document.body.appendChild(pane);
  }
  pane.hidden = false;
  pane.innerHTML = '<div class="tui-playback-head"></div><div id="tui-playback-term"></div><aside id="tui-playback-obs"></aside>';
  const head = pane.querySelector('.tui-playback-head');
  head.textContent = 'TUI recording ' + recordingId + ' — this captures keystrokes and screen contents. Never uploaded.';
  if (tuiPlaybackTerm) { try { tuiPlaybackTerm.dispose(); } catch (_) {} tuiPlaybackTerm = null; }
  if (typeof Terminal === 'function') {
    tuiPlaybackTerm = new Terminal({ convertEol: true, fontFamily: 'Menlo, Monaco, monospace', fontSize: 13, theme: { background: '#1e1e1e' } });
    tuiPlaybackTerm.open(document.getElementById('tui-playback-term'));
  }
  streamTuiPlayback(recordingId, tuiPlaybackTerm);
}

function closeTuiPlayback() {
  const app = document.getElementById('app');
  if (app) app.classList.remove('tui-playback-active');
  const pane = document.getElementById('tui-playback');
  if (pane) pane.hidden = true;
  if (tuiPlaybackTerm) { try { tuiPlaybackTerm.dispose(); } catch (_) {} tuiPlaybackTerm = null; }
}

async function streamTuiPlayback(id, term) {
  // Sliding window over a streamed GET — never slurp the whole file into a string.
  const res = await fetch('/tui-recordings/' + encodeURIComponent(id) + '/pty');
  if (!res.ok || !res.body || !res.body.getReader) return;
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  const windowBytes = [];
  let windowSize = 0;
  const MAX = 2 * 1024 * 1024;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (!line) continue;
      let ev;
      try { ev = JSON.parse(line); } catch (_) { continue; }
      if (ev.type === 'o' && ev.data && term) {
        let bytes;
        try {
          const bin = atob(ev.data);
          bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        } catch (_) { continue; }
        term.write(bytes);
        windowBytes.push(bytes);
        windowSize += bytes.length;
        while (windowSize > MAX && windowBytes.length) windowSize -= windowBytes.shift().length;
      }
    }
  }
}

function appendTuiPlaybackObs(params) {
  const side = document.getElementById('tui-playback-obs');
  if (!side) return;
  const row = document.createElement('div');
  row.className = 'tui-obs ' + (params.severity || '');
  row.textContent = (params.t || 0) + '  ' + (params.kind || '') + '  ' + (params.signature || '');
  side.appendChild(row);
}

async function refreshTuiRecordings(sessionId) {
  const root = document.getElementById('detail-recordings');
  if (!root) return;
  let rows = [];
  try {
    const res = await rpc('tui-record-list', { session_id: sessionId });
    rows = res.recordings || [];
  } catch (_) { rows = []; }
  root.innerHTML = '';
  if (!rows.length) { root.classList.remove('has-recordings'); return; }
  root.classList.add('has-recordings');
  const header = document.createElement('div');
  header.className = 'artifacts-header';
  header.textContent = 'Recordings (' + rows.length + ')';
  root.appendChild(header);
  const strip = document.createElement('div');
  strip.className = 'recordings-strip';
  for (const rec of rows) {
    const a = document.createElement('a');
    a.className = 'recording-chip';
    a.href = '#/tui-recordings/' + encodeURIComponent(rec.recording_id);
    a.textContent = (rec.form_factor || rec.status || 'rec') + ' · ' + (rec.recording_id || '').slice(0, 8);
    strip.appendChild(a);
  }
  root.appendChild(strip);
}

window.openTuiPlayback = openTuiPlayback;
window.closeTuiPlayback = closeTuiPlayback;
window.onTuiRecordEvent = onTuiRecordEvent;
window.tuiBindOnOpen = tuiBindOnOpen;
window.appendTuiMenuItems = appendTuiMenuItems;
window.ensureTuiTrace = ensureTuiTrace;
window.refreshTuiRecordings = refreshTuiRecordings;
window.tuiNoteTouchmove = function (preventDefault, delta) {
  if (tuiTrace) tuiTrace.noteEvent({ kind: 'touchmove', prevent_default: preventDefault, delta: delta, at_client: Date.now() });
};
window.tuiNoteEvent = function (kind) {
  if (tuiTrace) tuiTrace.noteEvent({ kind: kind, at_client: Date.now() });
};
