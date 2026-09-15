'use strict';
// Crow web UI — Session-detail kernel: artifacts, lightbox, grid-Escape, rename/goal/delete.
// Extracted from app.js (CROW-1155); header / tabs / modals split out (CROW-1257).

// ---------------------------------------------------------------------------
// Artifacts — per-session generated images (diagrams/screenshots) the agent
// dropped in the scratch dir. crowd lists them; the browser GETs each from the
// sandboxed /artifacts route. A compact strip under the header; click to zoom.
// ---------------------------------------------------------------------------
const artifactsBySession = {};
let artifactsCollapsed = localStorage.getItem('crow.artifacts.collapsed') === '1';

async function refreshArtifacts(id) {
  try {
    const res = await rpc('list-artifacts', { session_id: id });
    artifactsBySession[id] = res.images || [];
  } catch (_) { artifactsBySession[id] = []; }
  if (id === selectedId) renderArtifactsStrip();
  if (typeof refreshTuiRecordings === 'function') refreshTuiRecordings(id);
}

function renderArtifactsStrip() {
  const root = document.getElementById('detail-artifacts');
  if (!root) return;
  root.innerHTML = '';
  const images = artifactsBySession[selectedId] || [];
  if (!images.length) { root.classList.remove('has-images'); return; }
  root.classList.add('has-images');
  root.classList.toggle('collapsed', artifactsCollapsed);

  // Clickable header — chevron + label + count — toggles the strip.
  const header = el('div', 'artifacts-header');
  header.appendChild(el('span', 'artifacts-chevron', '▸')); // ▸ (CSS rotates when open)
  header.appendChild(el('span', 'artifacts-label', 'Images'));
  header.appendChild(el('span', 'artifacts-count', String(images.length)));
  header.onclick = () => {
    artifactsCollapsed = !artifactsCollapsed;
    localStorage.setItem('crow.artifacts.collapsed', artifactsCollapsed ? '1' : '0');
    root.classList.toggle('collapsed', artifactsCollapsed);
  };
  root.appendChild(header);

  const strip = el('div', 'artifacts-strip');
  for (const img of images) {
    const thumb = el('img', 'artifact-thumb');
    thumb.src = img.url;
    thumb.alt = img.name;
    thumb.title = img.name;
    thumb.loading = 'lazy';
    thumb.onclick = () => openLightbox(img.url, img.name);
    strip.appendChild(thumb);
  }
  root.appendChild(strip);
}

function openLightbox(url, alt) {
  const box = document.getElementById('lightbox');
  const img = document.getElementById('lightbox-img');
  img.src = url;
  img.alt = alt || '';
  box.hidden = false;
}

(function wireLightbox() {
  const box = document.getElementById('lightbox');
  if (box) box.onclick = () => { box.hidden = true; document.getElementById('lightbox-img').src = ''; };
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && box && !box.hidden) { box.hidden = true; document.getElementById('lightbox-img').src = ''; }
  });
})();

// Session-expired scrim Log in (#679): reuses the statusbar login handler (~:820).
(function wireSessionScrim() {
  const btn = document.getElementById('scrim-login');
  if (btn) btn.onclick = () => { location.href = '/login' + (location.hash || ''); };
})();

function shorten(path) {
  return path.replace(/^\/Users\/[^/]+/, '~').replace(/^\/home\/[^/]+/, '~');
}

// The review request matching a review session (by review_session_id), from the
// prefetched reviews board — so the session view can show the PR author.
function reviewForSession(id) {
  const rs = (boardData.reviews && boardData.reviews.reviews) || [];
  return rs.find((r) => r.review_session_id === id) || null;
}

// ---------------------------------------------------------------------------
// Back to grid (CROW-1163)
//
// Escape returns to `#/grid` only when this session view was opened from a
// grid cell (`sessionCameFromGrid`) AND the xterm does not have focus.
// Claude Code (and vim, pagers, …) use Escape to cancel; `handleTerminalKey`
// forwards unhandled keys to the PTY, so a global binding would steal it.
// Capture phase so we see the key *before* the lightbox's bubble listener
// hides itself — otherwise the same Escape would close the overlay *and*
// leave the session. Overlays (Settings, prompts, switcher, context menu)
// get first refusal: we no-op and let their own handlers run. An `esc+tab`
// switcher binding also owns Escape as a prefix (see switcherOwnsEscapePrefix).
// ---------------------------------------------------------------------------
function returnToGridFromSession() {
  if (!sessionCameFromGrid || !selectedId || selectedBoard) return false;
  selectBoard('grid');
  return true;
}

function sessionFromGridEscapeBlocked() {
  if (window.settingsIsOpen && window.settingsIsOpen()) return true;
  const box = document.getElementById('lightbox');
  if (box && !box.hidden) return true;
  if (document.querySelector('.text-prompt-backdrop, .modal-dialog-backdrop')) return true;
  const sw = document.getElementById('session-switcher');
  if (sw && !sw.hidden) return true;
  return false;
}

// The session switcher can bind `esc+tab` (a prefix chord). Both handlers are
// capture-phase on document; the switcher registers first and arms on Escape
// without consuming it, so Tab can still follow. If we then navigate, that
// sequence is cut off. Yield whenever the configured binding uses Escape as a
// prefix — the ‹ Grid header control remains the back path. Default is
// `cmd+/`, which does not own Escape.
function switcherOwnsEscapePrefix() {
  if (!uiConfig.switcherEnabled) return false;
  return parseSwitcherBinding(uiConfig.switcherBinding).prefix === 'Escape';
}

function handleSessionFromGridEscape(e) {
  if (e.type !== 'keydown' || e.key !== 'Escape' || e.defaultPrevented) return;
  if (e.altKey || e.ctrlKey || e.metaKey) return;
  if (e.repeat) return;
  if (!sessionCameFromGrid || !selectedId || selectedBoard) return;
  // Load-bearing: never compete with the agent. xterm's textarea lives inside
  // #terminal; isTerminalFocused is the same check the switcher uses.
  if (isTerminalFocused()) return;
  // A chrome <input> (find, rename prompt is a modal and already blocked
  // above) must keep Escape, not navigate.
  const ae = document.activeElement;
  if (ae && (ae.tagName === 'INPUT' || ae.tagName === 'TEXTAREA' || ae.isContentEditable)) return;
  const menu = document.querySelector('.ctx-menu');
  if (menu) {
    closeContextMenu();
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  if (sessionFromGridEscapeBlocked()) return;
  if (switcherOwnsEscapePrefix()) return;
  e.preventDefault();
  e.stopPropagation();
  returnToGridFromSession();
}

document.addEventListener('keydown', handleSessionFromGridEscape, true);

async function renameSession(id, current) {
  const raw = await textPrompt('Rename session', current, { okLabel: 'Rename' });
  const name = raw == null ? null : raw.trim();
  if (!name || name === current) return;
  try {
    await rpc('rename-session', { session_id: id, name });
    const s = sessions.find((x) => x.id === id);
    if (s) { s.name = name; renderSidebar(); if (id === selectedId) renderHeader(s); }
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] rename failed: ' + (e.message || e) + '\x1b[0m\r\n');
  }
}

// Set or update a session's org-goal tag (#723). Prompts free-text; an empty
// value clears the tag (parity with `crow set-goal --clear`). Updates the local
// session so the sidebar badge + detail header reflect it without a refetch.
async function setSessionGoal(id, current) {
  const raw = await textPrompt(current ? 'Edit org goal' : 'Set org goal', current || '',
    { placeholder: 'e.g. Q3 latency KPI', okLabel: 'Save' });
  if (raw == null) return; // cancelled
  const goal = raw.trim();
  if (goal === (current || '')) return; // unchanged (or empty on an untagged session) — skip the write
  try {
    await applyOrgGoal(id, goal);
  } catch (e) {
    alertModal('Set goal failed: ' + (e.message || e));
  }
}

async function clearSessionGoal(id) {
  try {
    await applyOrgGoal(id, '');
  } catch (e) {
    alertModal('Clear goal failed: ' + (e.message || e));
  }
}

// Shared org-goal mutation: a non-empty `goal` sets it, an empty string clears
// it (RPC gets `{goal}` or `{clear:true}` — never a blank goal, which the
// handler rejects). Reflects the change locally so the sidebar + header update
// without a refetch.
async function applyOrgGoal(id, goal) {
  await rpc('set-goal', goal ? { session_id: id, goal } : { session_id: id, clear: true });
  const s = sessions.find((x) => x.id === id);
  if (s) { s.org_goal = goal || null; renderSidebar(); if (id === selectedId) renderHeader(s); }
}

async function deleteSession(id, name) {
  if (!await confirmModal('Delete session "' + name + '"? This removes its worktree and terminals.', { okLabel: 'Delete', danger: true })) return;
  try {
    await rpc('delete-session', { session_id: id });
    sessions = sessions.filter((x) => x.id !== id);
    if (isGridPinned(id)) {
      gridPinnedIds = gridPinnedIds.filter((x) => x !== id);
      persistGridPins();
    }
    // `replace`: the session is gone, so Back must not offer to return to its
    // not-found card (review).
    if (selectedId === id) { navigate({ view: 'home' }, { replace: true }); showHome(); }
    renderSidebar();
  } catch (e) {
    alertModal('Delete failed: ' + (e.message || e));
  }
}
