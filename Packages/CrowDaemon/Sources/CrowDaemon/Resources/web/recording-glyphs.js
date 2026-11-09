'use strict';
// Crow web UI — per-session "is Corveil recording this?" glyphs (spike:
// sidebar recording indicator). Two small marks in the row's trailing
// cluster, fed by `list-sessions` → `s.recording`:
//
//   gateway      did the agent LAUNCH through an AI gateway (not merely: is one
//                configured)?
//   transcripts  has the log-sync collector shipped the transcript to Corveil?
//
// Hover shows the detail; a tap (phones have no hover) expands it under the
// row. The payload carries a base URL and fixed text only — never a header.

// Session ids whose recording detail is expanded under the row.
const recordingExpanded = new Set();

const REC_GATEWAY = {
  routed: { color: 'var(--green)', label: 'Through gateway' },
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

function recordingMark(kind, info, extraText) {
  const span = el('span', 'rec-mark rec-' + kind + (info.faint ? ' rec-faint' : ''));
  span.style.color = info.color;
  span.innerHTML = '<svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" '
    + 'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">'
    + REC_SVG[kind] + (info.slash ? REC_SLASH : '') + '</svg>';
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

// The two-glyph cluster for a row. Returns null when the daemon sent no
// `recording` (an older crowd).
function recordingGlyphs(s, opts) {
  const rec = s.recording;
  if (!rec) return null;
  const { g, t, gText, tText } = recordingTitles(rec);
  const wrap = el('span', 'rec-glyphs');
  const gm = recordingMark('gateway', g);
  gm.title = gText;
  gm.setAttribute('aria-label', gText.replace('\n', '. '));
  wrap.appendChild(gm);
  if (!(opts && opts.gatewayOnly)) {
    const tr = rec.transcripts || {};
    const count = (s.kind === 'manager' && tr.total != null && tr.total > 0)
      ? tr.uploaded + '/' + tr.total : null;
    const tm = recordingMark('transcripts', t, count);
    tm.title = tText;
    tm.setAttribute('aria-label', tText.replace('\n', '. '));
    wrap.appendChild(tm);
  }
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

// The tap-to-expand detail block under a row (both indicators, full text).
function recordingDetail(s) {
  if (!s.recording || !recordingExpanded.has(s.id)) return null;
  const { gText, tText } = recordingTitles(s.recording);
  const box = el('div', 'rec-detail');
  box.appendChild(el('div', 'rec-detail-line', gText));
  box.appendChild(el('div', 'rec-detail-line', tText));
  box.onclick = (e) => e.stopPropagation();
  return box;
}
