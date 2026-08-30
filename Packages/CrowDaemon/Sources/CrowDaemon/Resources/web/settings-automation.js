'use strict';
// Crow web UI — Settings → Automation (CROW-1160).
(function () {
  const T = window.CrowSettingsTabs = window.CrowSettingsTabs || {};
  const S = new Proxy({}, {
    get(_, k) { return window.CrowSettings[k]; },
    set(_, k, v) { window.CrowSettings[k] = v; return true; },
  });

  // ---- Automation ---------------------------------------------------------

  function renderAutomation(body) {
    S.cfg.defaults = S.cfg.defaults || {};
    S.cfg.autoRespond = S.cfg.autoRespond || {};

    body.appendChild(S.group('Reviews'));
    body.appendChild(S.listField('Excluded repos', S.cfg.defaults, 'excludeReviewRepos',
      'One per line. Repos to hide from the review board. Supports wildcards (e.g. owner/*).'));
    body.appendChild(S.listField('Ignored labels', S.cfg.defaults, 'ignoreReviewLabels',
      'One per line. Labels to ignore from the review board (e.g. dependencies, renovate).'));

    body.appendChild(S.group('Tickets'));
    body.appendChild(S.listField('Excluded repos', S.cfg.defaults, 'excludeTicketRepos',
      'One per line. Repos to hide from the ticket board. Supports wildcards.'));

    body.appendChild(S.group('Permission modes'));
    body.appendChild(S.toggleField('Enable remote control for new sessions', S.cfg, 'remoteControlEnabled',
      'New Claude Code sessions start with --rc so you can drive them from claude.ai or the mobile app.'));
    body.appendChild(S.toggleField('Manager Terminal: launch in auto permission mode', S.cfg, 'managerAutoPermissionMode',
      'Passes --permission-mode auto so the Manager can run crow/gh/git without per-call approval. Takes effect on next app launch.'));
    body.appendChild(S.toggleField('Coder Views: launch new coder views in auto permission mode', S.cfg, 'coderViewAutoPermissionMode',
      'Passes --permission-mode auto so new work coder views start in auto-accept instead of plan mode. Off by default.'));
    body.appendChild(S.toggleField('Code Reviews: launch in auto permission mode', S.cfg, 'reviewAutoPermissionMode',
      'Passes --permission-mode auto so a kicked-off code review runs its review flow unattended instead of coming up in plan mode. On by default.'));

    body.appendChild(S.group('Manager AI gateway'));
    if (!S.isLocal) {
      body.appendChild(S.readonlyNote((S.cfg.managerGateway && S.cfg.managerGateway.baseURL
        ? 'Manager gateway: ' + S.cfg.managerGateway.baseURL + '. '
        : 'No Manager gateway set. ')
        + 'The gateway is editable only from a local browser (on the machine running crowd).'));
    } else {
      // Out-of-band local-only write, like the desktop editor — not part of Save.
      const applyManual = async (g) => {
        await S.postConfig('/config/manager-gateway', g ? { baseURL: g.baseURL, headers: g.customHeaders } : { clear: true });
        S.cfg.managerGateway = g;
        S.render();
      };
      const manual = S.gatewayEditor(S.cfg.managerGateway || null, applyManual);
      // Connected → org picker (manual under Advanced); otherwise the raw editor.
      if (S.corveilConnected(S.cfg.corveilConnection)) {
        body.appendChild(S.orgGatewayEditor({
          current: S.cfg.managerGateway || null,
          postOrg: (orgId) => S.postConfig('/config/manager-gateway', { orgId }),
          setGateway: (g) => { S.cfg.managerGateway = g; },
          manual,
        }));
      } else {
        body.appendChild(manual);
      }
    }
    // Jira credential stays read-only on the web — its token is an op:// ref
    // managed outside the browser.
    body.appendChild(S.readonlyNote(S.cfg.jiraCredential && S.cfg.jiraCredential.username
      ? 'Jira user: ' + S.cfg.jiraCredential.username + ' (credential managed outside the web UI).'
      : 'No Jira credential set.'));

    body.appendChild(S.group('Attribution'));
    body.appendChild(S.toggleField('Add Crow-Session trailer to commits', S.cfg, 'attributionTrailers',
      'Writes a per-worktree settings.local.json adding a Crow-Session: <uuid> trailer. New worktrees only.'));

    body.appendChild(S.group('Auto-launch workspaces'));
    body.appendChild(S.toggleField('Auto-launch workspaces for crow:auto / crow:explore labeled issues', S.cfg, 'autoCreateWatcherEnabled',
      'The Manager detects assigned issues tagged crow:auto or crow:explore and runs /crow-workspace (or --explore) automatically. Off by default.'));

    body.appendChild(S.group('Auto-merge'));
    body.appendChild(S.toggleField('Enable crow:merge auto-merge for Crow-authored PRs', S.cfg, 'autoMergeWatcherEnabled',
      'A crow:merge label on a Crow-authored PR enables GitHub native auto-merge (squash + delete branch). Off by default.'));

    body.appendChild(S.group('Auto-respond'));
    body.appendChild(S.toggleField("Respond to 'changes requested' reviews", S.cfg.autoRespond, 'respondToChangesRequested',
      'Types a "read the review and address it" prompt into the session terminal.'));
    body.appendChild(S.toggleField('Respond to failed CI checks', S.cfg.autoRespond, 'respondToFailedChecks',
      'Types a "read the CI logs and fix it" prompt into the session terminal. Off by default.'));
    body.appendChild(S.toggleField('Auto-rebase onto base and resolve conflicts', S.cfg.autoRespond, 'autoRebaseAndResolveConflicts',
      'Rebases a behind/conflicting Crow-authored PR onto base and force-pushes (--force-with-lease). Off by default.'));
    body.appendChild(S.toggleField('Re-request review once changes are addressed', S.cfg.autoRespond, 'autoReRequestReview',
      'Re-adds the reviewers who requested changes once the fix lands, so the PR goes back on their queue instead of stalling.'));
  }

  T.automation = renderAutomation;
})();
