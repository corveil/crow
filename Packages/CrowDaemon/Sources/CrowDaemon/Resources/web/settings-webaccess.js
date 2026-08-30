'use strict';
// Crow web UI — Settings → Web access (CROW-1160).
(function () {
  const T = window.CrowSettingsTabs = window.CrowSettingsTabs || {};
  const S = new Proxy({}, {
    get(_, k) { return window.CrowSettings[k]; },
    set(_, k, v) { window.CrowSettings[k] = v; return true; },
  });

  function renderWebAccess(body) {
    const isSet = !!S.cfg.webAuth;
    body.appendChild(S.group('Web access password'));
    body.appendChild(el('div', 'st-perm-status', isSet
      ? 'A web password is set — non-local (proxied) access requires logging in.'
      : 'No web password set — non-local access is disabled until one is set.'));

    if (!S.isLocal) {
      body.appendChild(S.readonlyNote(
        'The web password can only be set, changed, or removed from a local browser '
        + '(on the machine running crowd) — never from a remote session, so a remote '
        + 'client can’t change the password that gates its own access.'));
    } else {
      const msg = el('div', 'st-perm-status', '');
      const row = el('div', 'st-sound-row');
      const input = el('input', 'st-input');
      input.type = 'password';
      input.placeholder = isSet ? 'New password' : 'Password';
      input.autocomplete = 'new-password';
      const setBtn = el('button', 'action-btn', isSet ? 'Change password' : 'Set password');
      setBtn.type = 'button';
      setBtn.onclick = async () => {
        if (!input.value) { msg.textContent = 'Enter a password.'; return; }
        setBtn.disabled = true; msg.textContent = 'Saving…';
        try {
          await S.postConfig('/config/web-password', { password: input.value });
          S.cfg.webAuth = { hashB64: '', saltB64: '', iterations: 0 }; // reflect "set" locally
          input.value = '';
          S.render();
        } catch (e) { msg.textContent = 'Failed: ' + (e.message || e); setBtn.disabled = false; }
      };
      row.appendChild(input); row.appendChild(setBtn);
      body.appendChild(S.field('Password', row,
        'Required for non-local (proxied) access. Applies immediately — no Save needed.'));
      body.appendChild(msg);

      if (isSet) {
        const rmBtn = el('button', 'action-btn', 'Remove password');
        rmBtn.type = 'button';
        rmBtn.onclick = async () => {
          if (!await confirmModal('Remove the web password? Non-local access will be disabled.', { title: 'Remove password', okLabel: 'Remove', danger: true })) return;
          rmBtn.disabled = true;
          try { await S.postConfig('/config/web-password', { clear: true }); S.cfg.webAuth = null; S.render(); }
          catch (_) { rmBtn.disabled = false; }
        };
        body.appendChild(S.field('Remove', rmBtn, 'Deletes the web password; non-local access is then disabled.'));
      }
    }

    const outBtn = el('button', 'action-btn', 'Log out');
    outBtn.type = 'button';
    outBtn.onclick = async () => {
      try { await fetch('/logout', { method: 'POST' }); } catch (_) {}
      location.reload();
    };
    body.appendChild(S.field('Session', outBtn, 'Ends this browser’s login session on this device.'));

    renderMCPTokens(body);

    body.appendChild(S.group('Remote access'));
    body.appendChild(el('div', 'st-perm-status',
      'Non-local access must go through an HTTPS proxy (Tailscale serve or ngrok) that forwards to crowd on '
      + 'localhost — bind crowd to loopback so the proxy is the only way in. Direct plain-http LAN access is denied.'));
  }

  // MCP bearer tokens (CROW-1004). Sits under Web access because it is the same
  // question — who may reach this daemon from off-box — answered for a different
  // client. Minting is local-only for the same reason the web password is: a remote
  // session must not be able to issue itself the credential that gates remote access.
  function renderMCPTokens(body) {
    S.cfg.mcpTokens = S.cfg.mcpTokens || [];
    body.appendChild(S.group('MCP access tokens'));
    body.appendChild(el('div', 'st-perm-status',
      'Read-only MCP for off-box clients at POST /mcp. Local clients need no token — '
      + 'point them at `crow mcp serve` instead.'));

    if (!S.cfg.mcpTokens.length) body.appendChild(el('div', 'st-empty', 'No MCP tokens.'));
    for (const token of S.cfg.mcpTokens) {
      const scopes = (token.scopes || []).join(', ') || 'no scopes';
      const expired = token.expiresAt && new Date(token.expiresAt) <= new Date();
      const expiry = token.expiresAt
        ? (expired ? 'EXPIRED ' : 'expires ') + new Date(token.expiresAt).toLocaleDateString()
        : 'never expires';
      const sub = scopes + ' · ' + expiry
        + (token.prefix ? ' · crow_mcp_' + token.prefix + '…' : '');

      const row = el('div', 'st-row');
      const main = el('div', 'st-row-main');
      main.appendChild(el('div', 'st-row-title', token.name || '(unnamed)'));
      main.appendChild(el('div', 'st-row-sub', sub));
      row.appendChild(main);
      if (S.isLocal) {
        const actions = el('div', 'st-row-actions');
        const del = S.iconBtn('trash', 'Revoke', 'danger');
        del.onclick = async () => {
          if (!await confirmModal(
            'Revoke “' + (token.name || 'this token') + '”? Any client using it stops working immediately.',
            { title: 'Revoke token', okLabel: 'Revoke', danger: true })) return;
          del.disabled = true;
          try {
            await S.postConfig('/config/mcp-tokens', { action: 'revoke', id: token.id });
            S.cfg.mcpTokens = S.cfg.mcpTokens.filter((t) => t.id !== token.id);
            S.render();
          } catch (e) { del.disabled = false; alertModal('Revoke failed: ' + (e.message || e)); }
        };
        actions.appendChild(del);
        row.appendChild(actions);
      }
      body.appendChild(row);
    }

    if (!S.isLocal) {
      body.appendChild(S.readonlyNote(
        'MCP tokens can only be minted or revoked from a local browser (on the machine '
        + 'running crowd) — never from a remote session, so a remote client can’t issue '
        + 'itself the credential that gates its own access.'));
      return;
    }

    const msg = el('div', 'st-perm-status', '');
    const nameInput = el('input', 'st-input');
    nameInput.placeholder = 'Name, e.g. grok-bot';

    const scopeSel = el('select', 'st-select');
    for (const [value, label] of [
      ['sessions:read board:read', 'sessions:read + board:read'],
      ['sessions:read', 'sessions:read only'],
      ['board:read', 'board:read only'],
    ]) {
      const opt = el('option', null, label);
      opt.value = value;
      scopeSel.appendChild(opt);
    }

    // Seconds, not a duration string: the HTTP route takes `expiresInSeconds`, and
    // keeping the parsing on the CLI side means one grammar with one owner.
    const EXPIRIES = [
      ['Expires in 90 days', 7776000],
      ['Expires in 30 days', 2592000],
      ['Expires in 1 year', 31536000],
      ['Never expires', 0],
    ];
    const expirySel = el('select', 'st-select');
    for (const [label, value] of EXPIRIES) {
      const opt = el('option', null, label);
      opt.value = String(value);
      expirySel.appendChild(opt);
    }

    const mintBtn = el('button', 'action-btn', 'Mint token');
    mintBtn.type = 'button';
    mintBtn.onclick = async () => {
      const name = nameInput.value.trim();
      if (!name) { msg.textContent = 'Enter a name.'; return; }
      mintBtn.disabled = true; msg.textContent = 'Minting…';
      const scopes = scopeSel.value.split(' ');
      const seconds = Number(expirySel.value);
      const payload = { action: 'mint', name, scopes };
      if (seconds > 0) payload.expiresInSeconds = seconds;
      else payload.noExpiry = true;
      try {
        const result = await S.postConfig('/config/mcp-tokens', payload);
        // Shown once and never again — only a hash is stored, so there is no
        // "reveal" to come back to. Make that unmissable.
        await alertModal(
          'Copy this token now. It is shown once and cannot be recovered:\n\n' + result.token,
          { title: 'MCP token minted' });
        // Append locally rather than refetching: the shape here must match what
        // `get-config` sends (camelCase), which is what the list above renders.
        S.cfg.mcpTokens = S.cfg.mcpTokens.concat([{
          id: result.id,
          name: result.name,
          prefix: result.prefix,
          scopes,
          createdAt: new Date().toISOString(),
          expiresAt: seconds > 0
            ? new Date(Date.now() + seconds * 1000).toISOString()
            : null,
        }]);
        nameInput.value = '';
        msg.textContent = '';
        S.render();
      } catch (e) {
        msg.textContent = 'Failed: ' + (e.message || e);
        mintBtn.disabled = false;
      }
    };

    const row = el('div', 'st-sound-row');
    row.appendChild(nameInput);
    row.appendChild(scopeSel);
    row.appendChild(expirySel);
    row.appendChild(mintBtn);
    body.appendChild(S.field('New token', row, 'Shown once. Applies immediately — no Save needed.'));
    body.appendChild(msg);
  }

  T.webaccess = renderWebAccess;
})();
