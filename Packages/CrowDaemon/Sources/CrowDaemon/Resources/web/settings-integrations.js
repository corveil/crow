'use strict';
// Crow web UI — Settings → Integrations (CROW-1160).
// Corveil Connect / org provisioning / org-picker gateway control.
(function () {
  const T = window.CrowSettingsTabs = window.CrowSettingsTabs || {};
  const S = new Proxy({}, {
    get(_, k) { return window.CrowSettings[k]; },
    set(_, k, v) { window.CrowSettings[k] = v; return true; },
  });

  // ---- Integrations (CROW-1122) ------------------------------------------
  //
  // The Corveil integration card. The connection is authored ONLY through the
  // local-only OAuth Connect flow (POST /integrations/corveil/connect) and cleared
  // through the local-only POST /config/corveil-connection {clear:true} — never
  // set-config, because the block holds OAuth tokens (SettingsSecrets). So the
  // browser reads connection state from the stripped get-config (cfg.corveilConnection:
  // OAuth token strings blanked, identity / base URL / org metadata kept) and mutates
  // it through those two dedicated endpoints, exactly like the AI gateways and the
  // web password. A proxied/remote session sees it read-only.

  // Connect-flow UI state, module-level so a re-render (Refresh, tab switch,
  // close/reopen) reconstructs the SAME disconnected card instead of dropping a
  // fresh, enabled Connect over a poll that is still in flight (round-2 review).
  // renderCorveilDisconnected derives the button's disabled state and the status
  // copy from these, and the poller drives every change through render() — the
  // card is a pure function of state, so nothing can desync from a stale closure.
  let corveilPolling = false;      // a connect poll is in flight
  let corveilConnectNote = '';     // status line under Connect (opened / timed-out / error)
  let corveilAuthorizeURL = '';    // fallback sign-in link, when Connect returned one
  // Reset the connect-flow state — called when Settings (re)opens so a new modal
  // never inherits a prior attempt's polling flag or copy.
  function resetCorveilConnectState() {
    corveilPolling = false;
    corveilConnectNote = '';
    corveilAuthorizeURL = '';
    resetCorveilOrgState();
  }

  // Org-dropdown state for the gateway editors (corveil/crow#1123), shared by the
  // Manager (Automation tab) and per-workspace (Workspaces tab) pickers — both bind
  // the same connection's memberships. Lazily loaded once through the local-only
  // `corveil-list-orgs` RPC (which caches server-side), then reused across renders.
  // `corveilOrgs === null` means "not fetched yet"; an array (possibly empty) means
  // "fetched". Reset when Settings (re)opens, exactly like the connect-flow state.
  let corveilOrgs = null;          // [{org_id, org_name, provisioned, is_active, role}] | null
  let corveilOrgsLoading = false;  // a list fetch is in flight
  let corveilOrgsError = '';       // last fetch error, shown inline
  function resetCorveilOrgState() {
    corveilOrgs = null;
    corveilOrgsLoading = false;
    corveilOrgsError = '';
  }

  // Fetch the user's Corveil orgs through the local-only provisioning RPC and
  // re-render when done. Guarded so overlapping renders can't stack fetches; the
  // finally-render lets the picker repaint from `corveilOrgs`/`corveilOrgsError`.
  // `force` re-fetches past the server-side cache (the explicit Refresh).
  async function loadCorveilOrgs(force) {
    if (corveilOrgsLoading) return;
    corveilOrgsLoading = true;
    corveilOrgsError = '';
    if (force) S.render();
    try {
      const res = await rpc('corveil-list-orgs', force ? { refresh: true } : {});
      corveilOrgs = (res && res.orgs) || [];
    } catch (e) {
      corveilOrgs = corveilOrgs || [];
      corveilOrgsError = (e && (e.message || String(e))) || 'could not load organizations';
    } finally {
      corveilOrgsLoading = false;
      S.render();
    }
  }

  // The org-picker gateway control (corveil/crow#1123). Replaces the raw
  // base-URL+headers editor when a Corveil connection exists: pick an org and Crow
  // provisions its one gateway key (corveil-select-org) and writes the DERIVED
  // gateway — base URL + x-citadel-api-key — through the same local-only POST the
  // manual editor uses, but with { orgId } so the daemon fills in the key secret it
  // never hands the browser. The manual editor stays reachable under "Advanced".
  //
  //   opts.current      — the stored gateway ({baseURL, customHeaders}) or null.
  //   opts.postOrg(id)  — POST the derived gateway ({ orgId: id }); returns a Promise.
  //   opts.setGateway(g)— set the local gateway (cfg.managerGateway / draft.gateway).
  //   opts.manual       — the manual gatewayEditor node (the Advanced fallback).
  function orgGatewayEditor(opts) {
    const wrap = el('div');
    const conn = S.cfg.corveilConnection || null;

    // Whether the stored gateway looks derived from this connection (its base URL
    // matches and it carries the x-citadel-api-key header). We can't tell WHICH org
    // it came from — the key value is stripped in transport and every org shares the
    // base URL — so we note "set from Corveil" without claiming an org (honest).
    const current = opts.current;
    const derived = !!(current && conn
      && (current.baseURL || '') === (conn.baseURL || '')
      && current.customHeaders
      && Object.keys(current.customHeaders).some((k) => k.toLowerCase() === 'x-citadel-api-key'));
    if (current && current.baseURL) {
      wrap.appendChild(el('div', 'st-perm-status', derived
        ? 'Gateway set from your Corveil connection (' + current.baseURL + ').'
        : 'A manually-entered gateway is set (' + current.baseURL + ').'));
    }

    // Kick the lazy load on first paint; the finally-render repaints with options.
    if (corveilOrgs === null && !corveilOrgsLoading) loadCorveilOrgs(false);

    const msg = el('div', 'st-perm-status', '');
    const sel = el('select', 'st-select');
    const placeholder = el('option', null,
      corveilOrgsLoading ? 'Loading organizations…' : 'Choose an organization…');
    placeholder.value = '';
    sel.appendChild(placeholder);
    for (const org of (corveilOrgs || [])) {
      const bits = [];
      if (org.provisioned) bits.push('key ready');
      if (org.is_active === false) bits.push('inactive');
      const o = el('option', null,
        (org.org_name || org.org_id || '(unnamed org)') + (bits.length ? ' · ' + bits.join(' · ') : ''));
      o.value = org.org_id;
      sel.appendChild(o);
    }
    sel.disabled = corveilOrgsLoading;
    sel.onchange = async () => {
      const orgId = sel.value;
      if (!orgId) return;
      const org = (corveilOrgs || []).find((x) => x.org_id === orgId) || null;
      const label = (org && org.org_name) || orgId;
      sel.disabled = true;
      msg.textContent = 'Provisioning gateway for ' + label + '…';
      try {
        // Mint or reuse the org's one gateway key, then write the derived gateway.
        await rpc('corveil-select-org', { org_id: orgId });
        await opts.postOrg(orgId);
      } catch (e) {
        // The pick itself failed — nothing was stored. Reset the select back to the
        // placeholder so re-picking the SAME org fires `change` again: HTML `change`
        // does not re-fire for an unchanged value, which would otherwise strand this
        // ticket's primary control on the org that just failed.
        msg.textContent = 'Failed: ' + (e && (e.message || e));
        sel.value = '';
        sel.disabled = false;
        return;
      }
      // The gateway is written. Everything past this point is success bookkeeping, so
      // a throw here must NOT report the pick as failed. Mark the org provisioned in
      // place so its "key ready" badge is right on the next paint without a refetch,
      // then show the derived gateway locally — the header value is a secret we don't
      // hold, so blank it, exactly how a stored gateway reads back after stripping.
      if (org) org.provisioned = true;
      opts.setGateway({ baseURL: (conn && conn.baseURL) || '',
        customHeaders: { 'x-citadel-api-key': '' } });
      // Best-effort: refresh the connection so the Integrations tab's per-org key
      // metadata reflects the new key. A failure here leaves the gateway stored and
      // the picker correct, so it must not surface as a failed pick.
      try { await refreshCorveilConnection(); } catch (_) { /* best-effort */ }
      S.render();
    };
    wrap.appendChild(S.field('Organization', sel,
      'Pick a Corveil organization — Crow provisions its gateway key and points this gateway at it.'));

    if (corveilOrgsError) {
      wrap.appendChild(el('div', 'st-perm-status', 'Could not load organizations: ' + corveilOrgsError));
    } else if (corveilOrgs && !corveilOrgs.length && !corveilOrgsLoading) {
      wrap.appendChild(el('div', 'st-help', 'No Corveil organizations found for your account.'));
    }
    wrap.appendChild(msg);

    const refresh = el('button', 'action-btn', 'Refresh organizations');
    refresh.type = 'button';
    refresh.disabled = corveilOrgsLoading;
    refresh.onclick = () => loadCorveilOrgs(true);
    wrap.appendChild(S.field(null, refresh));

    // Manual entry stays available as an advanced fallback. Native <details> keeps
    // it collapsed by default and needs no extra render state.
    const adv = el('details', 'st-advanced-gateway');
    const sum = el('summary', 'st-advanced-summary', 'Enter a gateway manually');
    adv.appendChild(sum);
    adv.appendChild(opts.manual);
    wrap.appendChild(adv);
    return wrap;
  }

  function renderIntegrations(body) {
    body.appendChild(S.group('Corveil'));
    body.appendChild(el('div', 'st-help',
      'Connect Crow to your Corveil account to provision AI-gateway keys and ship '
      + 'session transcripts to the organizational knowledge graph.'));
    renderCorveilCard(body);
  }

  // Connected = the block is present with a non-empty client id. The block reaches
  // the browser only when a connection is stored, and the client id survives
  // transport (only the OAuth token strings are stripped) — so it is the one
  // always-present, required field that separates "connected" from "not".
  function corveilConnected(conn) {
    return !!(conn && (conn.clientID || '').trim());
  }

  // Re-read ONLY cfg.corveilConnection from a fresh get-config, leaving any unsaved
  // edits on other tabs untouched and never marking the form dirty. The connection
  // lives outside the Save flow (authored via local-only POSTs, restored verbatim on
  // set-config), so this is how the tab reflects a connect/disconnect that completed
  // out of band — the OAuth consent happens in a separate browser window.
  async function refreshCorveilConnection() {
    const res = await rpc('get-config');
    let parsed = {};
    try { parsed = JSON.parse((res && res.config) || '{}'); } catch (_) { parsed = {}; }
    S.cfg.corveilConnection = parsed.corveilConnection || null;
    return S.cfg.corveilConnection;
  }

  function renderCorveilCard(body) {
    const conn = S.cfg.corveilConnection || null;
    const connected = corveilConnected(conn);

    const statusRow = el('div', 'st-corveil-status');
    statusRow.appendChild(el('span', 'st-corveil-dot' + (connected ? ' on' : '')));
    statusRow.appendChild(el('span', 'st-corveil-status-text',
      connected ? corveilIdentityLine(conn) : 'Not connected.'));
    body.appendChild(statusRow);

    if (connected) renderCorveilConnected(body, conn);
    else renderCorveilDisconnected(body, conn);
  }

  function corveilUserText(user) {
    const name = ((user && user.name) || '').trim();
    const email = ((user && user.email) || '').trim();
    if (name && email) return name + ' (' + email + ')';
    return name || email || '';
  }
  function corveilIdentityLine(conn) {
    const t = corveilUserText(conn.connectedUser || {});
    return t ? 'Connected as ' + t : 'Connected to Corveil.';
  }

  // Config dates arrive from get-config encoded by a default Swift JSONEncoder,
  // whose .deferredToDate strategy emits a NUMBER of seconds since the 2001-01-01
  // reference epoch — not unix milliseconds, and not ISO. Handing that straight to
  // `new Date(n)` (which reads a bare number as unix ms) renders every date in
  // January 1970 (CROW-1122 review). Convert the number from the Swift epoch here;
  // also accept an ISO-8601 string defensively (the shape `crow corveil status`
  // emits). Returns a Date, or null when the value is absent or unparseable.
  const SWIFT_REFERENCE_EPOCH_MS = Date.UTC(2001, 0, 1); // 978307200000
  function corveilParseDate(v) {
    if (v == null || v === '') return null;
    const d = typeof v === 'number'
      ? new Date(SWIFT_REFERENCE_EPOCH_MS + v * 1000)
      : new Date(v);
    return isNaN(d.getTime()) ? null : d;
  }

  function corveilOrgSub(org) {
    const parts = [];
    if (org.orgID && org.orgID !== org.orgName) parts.push(org.orgID);
    if ((org.keyPrefix || '').trim()) parts.push('key ' + org.keyPrefix + '…');
    const created = corveilParseDate(org.createdAt);
    if (created) parts.push('provisioned ' + created.toLocaleDateString());
    return parts.join(' · ') || '—';
  }

  function renderCorveilConnected(body, conn) {
    // Identity + base URL, read-only — non-secret fields kept in the stripped
    // config, shown the same way as the read-only dev-root path and gateway views.
    const user = conn.connectedUser || {};
    if (corveilUserText(user)) {
      body.appendChild(S.textField('Signed in as', { v: corveilUserText(user) }, 'v', { readonly: true }));
    }
    body.appendChild(S.textField('Base URL', { v: conn.baseURL || '' }, 'v',
      { readonly: true, help: 'The Corveil API endpoint this connection resolves against.' }));

    // Client id + access-token expiry: useful, non-secret connection detail. The
    // token VALUE never reaches the browser (stripped); only its expiry does.
    const detail = [];
    if ((conn.clientID || '').trim()) detail.push('Client ID ' + conn.clientID);
    const exp = corveilParseDate(conn.oauth && conn.oauth.accessTokenExpiresAt);
    if (exp) detail.push('access token expires ' + exp.toLocaleString());
    if (detail.length) body.appendChild(el('div', 'st-perm-status', detail.join(' · ')));

    // Organizations — the per-org gateway-key metadata (never key material; the
    // sk-citadel-… value lives in the generated workspace gateway header, not here).
    body.appendChild(S.group('Organizations'));
    const orgs = conn.orgKeys || [];
    if (!orgs.length) {
      body.appendChild(el('div', 'st-empty', 'No organizations provisioned yet.'));
    } else {
      for (const org of orgs) {
        const row = el('div', 'st-row');
        const main = el('div', 'st-row-main');
        main.appendChild(el('div', 'st-row-title', org.orgName || org.orgID || '(unnamed org)'));
        main.appendChild(el('div', 'st-row-sub', corveilOrgSub(org)));
        row.appendChild(main);
        body.appendChild(row);
      }
    }

    // Disconnect — local-only, like clearing a gateway.
    body.appendChild(S.group('Connection'));
    if (!S.isLocal) {
      body.appendChild(S.readonlyNote(
        'Disconnecting is available only from a local browser (on the machine running crowd).'));
      return;
    }
    const msg = el('div', 'st-perm-status', '');
    const btn = el('button', 'action-btn action-danger', 'Disconnect');
    btn.type = 'button';
    btn.onclick = async () => {
      if (!await confirmModal(
        'Disconnect from Corveil? Crow stops using this connection. The per-org gateway '
        + 'keys are revoked separately on the Corveil side.',
        { title: 'Disconnect from Corveil', okLabel: 'Disconnect', danger: true })) return;
      btn.disabled = true; msg.textContent = 'Disconnecting…';
      try {
        await S.postConfig('/config/corveil-connection', { clear: true });
        S.cfg.corveilConnection = null;
        // Drop the cached memberships too — they belong to the connection just
        // cleared, and a later Connect in this same modal must refetch its own
        // account's orgs rather than paint the previous one's (CROW-1123 review).
        resetCorveilOrgState();
        S.render();
      } catch (e) {
        msg.textContent = 'Failed: ' + (e.message || e);
        btn.disabled = false;
      }
    };
    body.appendChild(S.field('Disconnect', btn,
      'Clears the stored connection on this machine. Applies immediately — no Save needed.'));
    body.appendChild(msg);
  }

  function renderCorveilDisconnected(body, conn) {
    // Connect authors OAuth tokens on the daemon host, so — like the web password
    // and AI gateways — it is refused from a proxied/remote session (the POST's own
    // gate). Show a read-only note rather than a dead button.
    if (!S.isLocal) {
      body.appendChild(S.readonlyNote(
        'Connect to Corveil from a local browser (on the machine running crowd). '
        + 'The sign-in stores OAuth tokens on that machine, so a remote session can’t start it.'));
      return;
    }

    const msg = el('div', 'st-perm-status', corveilConnectNote);
    const urlInput = el('input', 'st-input');
    urlInput.type = 'text';
    urlInput.placeholder = 'https://app.corveil.example';
    urlInput.value = (conn && conn.baseURL) || '';
    body.appendChild(S.field('Corveil base URL', urlInput,
      'Your Corveil instance’s URL. Crow self-registers an OAuth client and opens your browser to sign in.'));

    const btn = el('button', 'action-btn action-primary', 'Connect to Corveil');
    btn.type = 'button';
    // Disabled while a poll is in flight, so a re-render (Refresh / tab return /
    // reopen) can never present a second, enabled Connect over a pending sign-in.
    btn.disabled = corveilPolling;
    btn.onclick = async () => {
      const baseURL = urlInput.value.trim();
      if (!baseURL) { corveilConnectNote = 'Enter your Corveil base URL.'; msg.textContent = corveilConnectNote; return; }
      btn.disabled = true;
      corveilConnectNote = 'Opening sign-in…';
      corveilAuthorizeURL = '';
      msg.textContent = corveilConnectNote;
      try {
        const res = await S.postConfig('/integrations/corveil/connect', { baseURL });
        corveilConnectNote = 'A browser window opened to sign in to Corveil. '
          + 'Complete it there — this updates automatically when you’re done.';
        corveilAuthorizeURL = (res && res.authorizeURL) || '';
        startCorveilConnectPoll();
        // Re-render so the whole card reflects the in-flight poll uniformly
        // (Connect disabled, waiting copy, fallback link) from module state.
        S.render();
      } catch (e) {
        corveilConnectNote = 'Failed: ' + (e.message || e);
        corveilAuthorizeURL = '';
        msg.textContent = corveilConnectNote;
        btn.disabled = false;
      }
    };
    body.appendChild(S.field('Connect', btn, 'Applies immediately — no Save needed.'));
    body.appendChild(msg);

    // Auto-open is best-effort on the daemon host; offer the URL as a fallback.
    // Rendered from module state so it survives a re-render while polling.
    if (corveilAuthorizeURL) {
      const fallback = el('div', 'st-perm-status');
      fallback.appendChild(document.createTextNode('Didn’t see a window? '));
      const a = el('a', null, 'Open the sign-in page');
      a.href = corveilAuthorizeURL;
      a.target = '_blank';
      a.rel = 'noopener';
      fallback.appendChild(a);
      body.appendChild(fallback);
    }

    // Manual fallback if the auto-poll window elapses (a slow sign-in). Safe to
    // click during a poll — render() keeps Connect disabled until the poll ends.
    const refresh = el('button', 'action-btn', 'Refresh status');
    refresh.type = 'button';
    refresh.onclick = async () => {
      refresh.disabled = true;
      try { await refreshCorveilConnection(); S.render(); }
      catch (e) { corveilConnectNote = 'Could not refresh: ' + (e.message || e); msg.textContent = corveilConnectNote; refresh.disabled = false; }
    };
    body.appendChild(S.field(null, refresh));
  }

  // After Connect, the OAuth consent completes in a separate browser window and the
  // daemon stores the tokens; this tab still holds the pre-connect config. Poll a
  // fresh get-config until the connection appears (or the user leaves), then
  // re-render — into the connected view on success, or back to an enabled Connect
  // (with "still not connected" copy) on timeout. State lives entirely in the module
  // vars above and the card is a pure function of them, so a mid-poll Refresh / tab
  // switch can't leave a stale, stuck button behind.
  function startCorveilConnectPoll() {
    if (corveilPolling) return;
    corveilPolling = true;
    // Bind this poll to the modal instance that started it: a close+reopen replaces
    // `backdrop` with a new element, and this poll must go inert rather than drive
    // (or double up on) the fresh modal — which reset its own state on open.
    const myBackdrop = S.backdrop;
    let attempts = 0;
    const tick = async () => {
      // Stop if this modal closed/reopened, or the user left the Integrations tab.
      // Clear the transient copy so a later return shows a clean, enabled card.
      if (S.backdrop !== myBackdrop || S.activeTab !== 'integrations') {
        if (S.backdrop === myBackdrop) { corveilPolling = false; corveilConnectNote = ''; corveilAuthorizeURL = ''; }
        return;
      }
      attempts++;
      try {
        if (corveilConnected(await refreshCorveilConnection())) {
          corveilPolling = false;
          corveilConnectNote = '';
          corveilAuthorizeURL = '';
          // Fresh connection → drop any org list cached from a prior one, so the
          // gateway pickers lazily refetch this account's memberships (CROW-1123
          // review). The daemon cache is already connection-keyed; this is the
          // browser-side twin.
          resetCorveilOrgState();
          S.render();
          return;
        }
      } catch (_) { /* transient — keep polling */ }
      if (attempts >= 24) {
        // Consent + 2FA can outlast the poll window. Drop the flag and re-render:
        // Connect comes back enabled and the copy points at Refresh.
        corveilPolling = false;
        corveilConnectNote = 'Still not connected. Finish the Corveil sign-in, then '
          + 'click Refresh status — or Connect again.';
        corveilAuthorizeURL = '';
        S.render();
        return;
      }
      setTimeout(tick, 2500);
    };
    setTimeout(tick, 2500);
  }

  T.integrations = renderIntegrations;
  T.orgGatewayEditor = orgGatewayEditor;
  T.corveilConnected = corveilConnected;
  T.resetCorveilConnectState = resetCorveilConnectState;
})();
