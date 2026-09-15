'use strict';
// Crow web UI — In-page confirm/alert/prompt dialogs (CROW-593).
// Extracted from session.js (CROW-1257).

// In-page single-line text prompt. Replaces window.prompt(), which many browsers
// silently no-op — returning null — over the web: after a "prevent additional
// dialogs" opt-out, on assorted mobile browsers, and in some remote/secure
// contexts. window.prompt failing that way meant the rename rpc was never sent
// (CROW-593). Returns the entered string, or null on cancel/Escape/backdrop.
// In-page confirm/alert modal → Promise<boolean> (true = OK/confirm). Replaces
// window.confirm/alert, which render as native chrome (and are jarring inside the
// desktop wrapper). cancelLabel:null makes it an alert (single OK). (CROW-593)
function modalDialog({ title, body, okLabel = 'OK', cancelLabel = 'Cancel', danger = false, token = null } = {}) {
  return new Promise((resolve) => {
    let done = false;
    const backdrop = el('div', 'text-prompt-backdrop modal-dialog-backdrop');
    const card = el('div', 'text-prompt-card');
    if (title) card.appendChild(el('div', 'text-prompt-title', title));
    if (body) card.appendChild(el('div', 'text-prompt-body', body));
    const actions = el('div', 'text-prompt-actions');
    const ok = el('button', 'text-prompt-btn primary' + (danger ? ' danger' : ''), okLabel);
    function finish(v) {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKey, true);
      backdrop.remove();
      resolve(v);
    }
    backdrop.__finish = finish;
    // Identity for `dismissModalDialog` — lets an async caller retract *its own*
    // dialog and only its own, never one the user opened afterwards (#931).
    backdrop.__token = token;
    function onKey(e) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(false); }
      else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); finish(true); }
    }
    if (cancelLabel != null) {
      const cancel = el('button', 'text-prompt-btn', cancelLabel);
      cancel.onclick = () => finish(false);
      actions.appendChild(cancel);
    }
    ok.onclick = () => finish(true);
    actions.appendChild(ok);
    card.appendChild(actions);
    backdrop.appendChild(card);
    backdrop.addEventListener('mousedown', (e) => { if (e.target === backdrop) finish(false); });
    // One dialog at a time: supersede any stray *modalDialog* backdrop still on
    // screen so a double-fired error can't stack two overlapping cards whose text
    // abuts into one concatenated message (CROW-665). Finish (resolve as cancel)
    // each superseded dialog rather than bare-removing it, so its Promise settles
    // and its capture-phase keydown listener detaches — a plain .remove() orphans
    // both (review Yellow). Runs before this backdrop is in the DOM, so it only
    // matches prior dialogs. Scoped to modalDialog's marker class, so a live
    // `textPrompt` (shares `.text-prompt-backdrop`, resolves only via its own
    // handlers) is never touched.
    document.querySelectorAll('.modal-dialog-backdrop')
      .forEach((b) => (b.__finish ? b.__finish(false) : b.remove()));
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(backdrop);
    ok.focus();
  });
}
function confirmModal(body, { title = 'Confirm', okLabel = 'OK', danger = false } = {}) {
  return modalDialog({ title, body, okLabel, cancelLabel: 'Cancel', danger });
}
function alertModal(body, { title = 'Crow', token = null } = {}) {
  return modalDialog({ title, body, okLabel: 'OK', cancelLabel: null, token });
}

// Take down the on-screen modalDialog iff it is the one created with `token`.
// Returns whether it dismissed anything. A no-op when the dialog was already
// dismissed by the user, or superseded by a later one — an async retraction must
// never yank a modal someone is mid-read of. Only ever one modalDialog is
// mounted (modalDialog supersedes its predecessors), so one query suffices.
function dismissModalDialog(token) {
  if (!token) return false;
  const backdrop = document.querySelector('.modal-dialog-backdrop');
  if (!backdrop || backdrop.__token !== token) return false;
  if (backdrop.__finish) backdrop.__finish(false); else backdrop.remove();
  return true;
}

function textPrompt(title, current, { placeholder = '', okLabel = 'Save' } = {}) {
  return new Promise((resolve) => {
    let done = false;
    const backdrop = el('div', 'text-prompt-backdrop');
    const card = el('div', 'text-prompt-card');
    const heading = el('div', 'text-prompt-title', title);
    const input = el('input', 'text-prompt-input');
    input.type = 'text';
    input.value = current || '';
    if (placeholder) input.placeholder = placeholder;
    const actions = el('div', 'text-prompt-actions');
    const cancel = el('button', 'text-prompt-btn', 'Cancel');
    const ok = el('button', 'text-prompt-btn primary', okLabel);
    actions.append(cancel, ok);
    card.append(heading, input, actions);
    backdrop.appendChild(card);

    function finish(value) {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKey, true);
      backdrop.remove();
      resolve(value);
    }
    function onKey(e) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(null); }
      else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); finish(input.value); }
    }
    cancel.onclick = () => finish(null);
    ok.onclick = () => finish(input.value);
    backdrop.addEventListener('mousedown', (e) => { if (e.target === backdrop) finish(null); });
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(backdrop);
    input.focus();
    input.select();
  });
}
