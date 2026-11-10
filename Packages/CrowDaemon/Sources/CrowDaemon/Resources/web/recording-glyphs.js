'use strict';
// Crow web UI — per-session "is Corveil recording this?" glyphs (CROW-1423).
// Two small marks in the row's trailing cluster, fed by `list-sessions` →
// `s.recording`:
//
//   gateway      did this session's traffic reach the AI gateway, under the
//                right org? (Proven from Corveil's request log when it can be;
//                otherwise what the agent was launched with.)
//   transcripts  has the log-sync collector shipped the transcript to Corveil?
//
// Hover shows the detail; a tap (phones have no hover) expands it under the
// row. The payload carries base URLs, key ids/names, org names and fixed text
// only — never a header.
//
// Debug mode only (Settings → About → Debug mode, or
// `crow ui set --debug-mode true`).

// Session ids whose recording detail is expanded under the row.
const recordingExpanded = new Set();

const REC_GATEWAY = {
  // Proven from Corveil's gateway request log (deterministic join on the
  // Claude Code conversation id).
  verified: { color: 'var(--green)', label: 'Verified in the gateway log', check: true },
  mismatch: { color: 'var(--red)', label: 'Requests land under another org/key', bang: true },
  silent: { color: 'var(--orange)', label: 'Active, but no gateway requests seen', bang: true },
  // Launch-time record only: what the agent was started with.
  routed: { color: 'var(--green)', label: 'Launched through gateway (not yet verified)', faint: true },
  drift: { color: 'var(--orange)', label: 'Gateway changed since launch' },
  unverified: { color: 'var(--yellow)', label: 'Gateway configured, launch not recorded', faint: true },
  direct: { color: 'var(--text-muted)', label: 'No gateway (vendor direct)', slash: true },
  off: { color: 'var(--text-muted)', label: 'No gateway', slash: true, faint: true },
  unsupported: { color: 'var(--text-muted)', label: 'Gateway n/a for this agent', faint: true },
};

const REC_TRANSCRIPTS = {
  uploaded: { color: 'var(--green)', label: 'Transcript uploaded' },
  waiting: { color: 'var(--text-secondary)', label: 'Transcript waiting', faint: true },
  retrying: { color: 'var(--orange)', label: 'Transcript upload retrying' },
  rejected: { color: 'var(--red)', label: 'Transcript rejected' },
  not_opted_in: { color: 'var(--text-muted)', label: 'Transcripts not opted in', slash: true, faint: true },
  skipped: { color: 'var(--yellow)', label: 'Transcript not uploading' },
};

// Gateway: a stream passing through a gate. Transcript: a page with an
// up-arrow (upload). Both 16-unit boxes so they share the row's icon grid.
const REC_SVG = {
  gateway: '<path d="M1.5 8h13"/><path d="M11.5 5 14.5 8l-3 3"/><rect x="5" y="3" width="3.2" height="10" rx="1"/>',
  transcripts: '<path d="M4 1.8h5.5L12.5 4.8V14.2H4z"/><path d="M8.2 11.5V6.8"/><path d="M6.4 8.5 8.2 6.7 10 8.5"/>',
};
const REC_SLASH = '<path d="M2.5 13.5 13.5 2.5"/>';
// Small badge marks in the glyph's lower-right corner.
const REC_CHECK = '<path d="M9.8 13.2l1.6 1.5 3-3.4" stroke-width="1.8"/>';
const REC_BANG = '<circle cx="13" cy="13" r="2.6" fill="currentColor" stroke="none"/>';

function recordingMark(kind, info, extraText) {
  const span = el('span', 'rec-mark rec-' + kind + (info.faint ? ' rec-faint' : ''));
  span.style.color = info.color;
  span.innerHTML = '<svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" '
    + 'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">'
    + REC_SVG[kind] + (info.slash ? REC_SLASH : '') + (info.check ? REC_CHECK : '')
    + (info.bang ? REC_BANG : '') + '</svg>';
  if (extraText) span.appendChild(el('span', 'rec-count', extraText));
  return span;
}

function recordingTitles(rec) {
  const g = REC_GATEWAY[rec.gateway && rec.gateway.state] || REC_GATEWAY.unsupported;
  const t = REC_TRANSCRIPTS[rec.transcripts && rec.transcripts.state] || REC_TRANSCRIPTS.not_opted_in;
  return {
    g, t,
    gText: 'Gateway: ' + g.label + (rec.gateway && rec.gateway.detail ? '\n' + rec.gateway.detail : ''),
    tText: 'Transcripts: ' + t.label + (rec.transcripts && rec.transcripts.detail ? '\n' + rec.transcripts.detail : ''),
  };
}

// The two-glyph cluster for a row. A debug-mode feature: null unless debug
// mode is on (Settings → About) and the daemon sent `recording` (it omits it
// while debug mode is off, and an older crowd never sends it).
function recordingGlyphs(s, opts) {
  const rec = s.recording;
  if (!uiConfig.debugMode || !rec) return null;
  const { g, t, gText, tText } = recordingTitles(rec);
  const wrap = el('span', 'rec-glyphs');
  const gm = recordingMark('gateway', g);
  gm.title = gText;
  gm.setAttribute('aria-label', gText.replaceAll('\n', '. '));
  wrap.appendChild(gm);
  let tm = null;
  if (!(opts && opts.gatewayOnly)) {
    const tr = rec.transcripts || {};
    const count = (s.kind === 'manager' && tr.total != null && tr.total > 0)
      ? tr.uploaded + '/' + tr.total : null;
    tm = recordingMark('transcripts', t, count);
    tm.title = tText;
    tm.setAttribute('aria-label', tText.replaceAll('\n', '. '));
    wrap.appendChild(tm);
  }
  // The detail text ("last seen 3m ago") is left out of the sidebar signature
  // so it doesn't force a repaint every minute (recordingSignatureView), so
  // the tooltip is refreshed from the latest poll when it is about to show.
  const refresh = () => {
    const now = (typeof sessions !== 'undefined' && sessions.find((x) => x.id === s.id)) || s;
    if (!now.recording) return;
    const latest = recordingTitles(now.recording);
    gm.title = latest.gText;
    if (tm) tm.title = latest.tText;
  };
  wrap.addEventListener('mouseenter', refresh);
  wrap.addEventListener('focus', refresh);
  wrap.setAttribute('role', 'button');
  wrap.tabIndex = 0;
  const toggle = (e) => {
    e.stopPropagation();
    if (recordingExpanded.has(s.id)) recordingExpanded.delete(s.id);
    else recordingExpanded.add(s.id);
    lastSidebarSig = null;
    renderSidebar();
  };
  wrap.onclick = toggle;
  wrap.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') toggle(e); };
  return wrap;
}

// What of `recording` the sidebar signature watches: states and counts for
// every row, full text only for expanded rows. Keeps the "Nm ago" in the
// detail from repainting the whole sidebar once a minute.
function recordingSignatureView(list) {
  if (!uiConfig.debugMode) return null;
  return (list || []).map((s) => {
    const r = s.recording;
    if (!r) return null;
    if (recordingExpanded.has(s.id)) return [s.id, r];
    const g = r.gateway || {};
    const tr = r.transcripts || {};
    return [s.id, g.state, g.traffic && g.traffic.state, tr.state, tr.uploaded, tr.total];
  });
}

// The tap-to-expand detail block under a row (both indicators, full text).
function recordingDetail(s) {
  if (!uiConfig.debugMode || !s.recording || !recordingExpanded.has(s.id)) return null;
  const { gText, tText } = recordingTitles(s.recording);
  const box = el('div', 'rec-detail');
  box.appendChild(el('div', 'rec-detail-line', gText));
  box.appendChild(el('div', 'rec-detail-line', tText));
  box.onclick = (e) => e.stopPropagation();
  return box;
}
