'use strict';
// Crow web UI — Settings → About (CROW-1160).
(function () {
  const T = window.CrowSettingsTabs = window.CrowSettingsTabs || {};
  const S = new Proxy({}, {
    get(_, k) { return window.CrowSettings[k]; },
    set(_, k, v) { window.CrowSettings[k] = v; return true; },
  });

  function renderAbout(body) {
    const head = el('div', 'st-about-head');
    const logo = el('img', 'st-about-logo');
    logo.src = '/brand.svg';
    logo.alt = 'Crow';
    const htext = el('div');
    htext.appendChild(el('div', 'st-about-name', 'Crow'));
    const ver = el('div', 'st-about-ver', 'Loading version…');
    const updateStatus = el('div', 'st-about-update', '');
    htext.appendChild(ver);
    htext.appendChild(updateStatus);
    head.append(logo, htext);
    body.appendChild(head);
    body.appendChild(el('div', 'st-help',
      'AI-powered development session manager. crowd is the sole authority; every UI is a client.'));

    S.cfg.versionUpdate = S.cfg.versionUpdate || { enabled: true, intervalHours: 1 };

    function renderUpdateStatus(status) {
      updateStatus.textContent = '';
      updateStatus.className = 'st-about-update';
      updateStatus.title = '';
      if (!status || !status.state) return;
      if (status.state === 'up_to_date') {
        updateStatus.textContent = 'Up to date with origin/main.';
        updateStatus.classList.add('st-update-ok');
      } else if (status.state === 'behind') {
        const n = status.behind_by || 0;
        updateStatus.textContent = n + ' commit' + (n === 1 ? '' : 's') + ' behind origin/main.';
        updateStatus.classList.add('st-update-behind');
        if (status.update_command) {
          updateStatus.title = 'Update: ' + status.update_command;
        }
      } else {
        updateStatus.textContent = status.reason || 'Could not check for updates.';
        updateStatus.classList.add('st-update-unknown');
      }
    }

    function loadUpdateStatus() {
      rpc('version-update-get').then((res) => {
        if (res && res.status) renderUpdateStatus(res.status);
      }).catch(() => {
        updateStatus.textContent = 'Update check unavailable.';
        updateStatus.classList.add('st-update-unknown');
      });
    }

    // CROW-1030: the SHA is a link to that commit on corveil/crow. Built as
    // nodes rather than one textContent so the SHA can carry an <a>; the link
    // href uses `gitShaFull` when stamped (the display stays short), and an
    // unlinkable stamp (`dev`, missing, non-hex) renders as plain text.
    function renderVersionLine(v) {
      ver.textContent = '';
      const parts = [];
      parts.push(document.createTextNode('Version ' + (v.version || '?')));
      if (v.gitSha) {
        const url = crowCommitURL(v.gitShaFull || v.gitSha);
        if (url) {
          const a = el('a', 'st-about-sha', v.gitSha);
          a.href = url;
          a.target = '_blank';
          a.rel = 'noopener';
          a.title = 'View this commit on GitHub';
          parts.push(a);
        } else {
          parts.push(document.createTextNode(v.gitSha));
        }
      }
      if (v.buildDate) parts.push(document.createTextNode(v.buildDate));
      parts.forEach((node, i) => {
        if (i > 0) ver.appendChild(document.createTextNode(' · '));
        ver.appendChild(node);
      });
    }

    fetch('/version.json').then((r) => (r.ok ? r.json() : null)).then((v) => {
      if (!v) { ver.textContent = 'Version unavailable'; return; }
      renderVersionLine(v);
    }).catch(() => { ver.textContent = 'Version unavailable'; });

    loadUpdateStatus();

    body.appendChild(S.group('Updates'));
    body.appendChild(S.toggleField('Check for upstream updates', S.cfg.versionUpdate, 'enabled',
      'Compare this build against corveil/crow main on a schedule (at least every hour).'));
    body.appendChild(S.selectField('Check interval', S.cfg.versionUpdate, 'intervalHours', [
      [1, '1 hour'], [6, '6 hours'], [12, '12 hours'], [24, '1 day'], [168, '1 week'],
    ], { number: true, help: 'Minimum 1 hour; hourly checks stay within GitHub unauthenticated rate limits.' }));

    const checkRow = el('div', 'st-field');
    const checkBtn = el('button', 'action-btn', 'Check now');
    checkBtn.type = 'button';
    checkBtn.onclick = async () => {
      checkBtn.disabled = true;
      updateStatus.textContent = 'Checking…';
      try {
        const res = await rpc('version-update-check', { force: true });
        renderUpdateStatus(res && res.status);
        if (window.refreshVersionUpdateBanner) window.refreshVersionUpdateBanner(res && res.status);
      } catch (e) {
        updateStatus.textContent = 'Check failed: ' + (e.message || e);
        updateStatus.className = 'st-about-update st-update-unknown';
      } finally {
        checkBtn.disabled = false;
      }
    };
    checkRow.appendChild(el('div', 'st-label', 'Upstream status'));
    checkRow.appendChild(checkBtn);
    body.appendChild(checkRow);

    // Maintenance actions — the desktop app's old Restart/Reload menu items,
    // now reachable from any browser (CROW-593).
    function actBtn(label, labelText, help, run) {
      const b = el('button', 'action-btn', label);
      b.type = 'button';
      b.onclick = run;
      body.appendChild(S.field(labelText, b, help));
    }

    body.appendChild(S.group('Maintenance'));
    actBtn('Restart Manager', 'Manager',
      'Relaunches the Manager’s Claude Code session.', async () => {
        if (await confirmModal('Restart the Manager? Its Claude Code session will relaunch.',
          { title: 'Restart Manager', okLabel: 'Restart' })) {
          try { await rpc('restart-manager', {}); }
          catch (e) { alertModal('Restart failed: ' + (e.message || e)); }
        }
      });
    actBtn('Reload tmux config', 'tmux config',
      'Re-applies the bundled tmux config without restarting the server.', async () => {
        try { await rpc('reload-tmux-config', {}); alertModal('tmux config reloaded.'); }
        catch (e) { alertModal('Reload failed: ' + (e.message || e)); }
      });
    actBtn('Reload tmux (restart server)', 'tmux server',
      'Kills and restarts the tmux server — terminals across every session are recreated.', async () => {
        if (await confirmModal('Restart the tmux server? Terminals across every session are recreated.',
          { title: 'Reload tmux', okLabel: 'Restart tmux', danger: true })) {
          try { await rpc('restart-tmux-server', {}); }
          catch (e) { alertModal('Restart failed: ' + (e.message || e)); }
        }
      });
  }

  T.about = renderAbout;
})();
