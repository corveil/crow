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
    body.appendChild(S.toggleField('Label PRs crow:reviewing while a review is running', S.cfg, 'reviewInProgressLabelEnabled',
      'Adds crow:reviewing when a Crow review starts and removes it when that review ends, so others can see a review is in progress. Off by default. Missing permission to label the repo is logged and does not fail the review.'));
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
    // Which Managers this covers (CROW-1478): a Manager tagged with a workspace
    // uses that workspace's gateway, or none, never this one.
    body.appendChild(el('div', 'st-help',
      'Used by the primary Manager and by untagged Managers. A Manager in a workspace uses that '
      + 'workspace\'s AI gateway, or none when the workspace has none.'));
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
        // Manual write/clear is not an org pick — drop the cached selection so
        // the rebuilt dropdown does not keep showing the last org (#1213 review).
        if (typeof S.forgetPickedOrg === 'function') S.forgetPickedOrg('manager');
        S.render();
      };
      const manual = S.gatewayEditor(S.cfg.managerGateway || null, applyManual);
      // Connected → org picker (manual under Advanced); otherwise the raw editor.
      if (S.corveilConnected(S.cfg.corveilConnection)) {
        body.appendChild(S.orgGatewayEditor({
          target: 'manager',
          current: S.cfg.managerGateway || null,
          postOrg: (orgId) => S.postConfig('/config/manager-gateway', { orgId }),
          // Off (CROW-1478) is the manual editor's clear.
          clear: () => applyManual(null),
          offText: 'Off: the primary Manager does not route through any AI gateway.',
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
    body.appendChild(S.toggleField('Include the model in Crow footers', S.cfg, 'attributionModel',
      'Review and ticket footers name the model as well as the harness (via Claude Code · claude-opus-5-5). Claude Code and Codex sessions only.'));

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

    // Context size + pre-expiry compaction (CROW-1493).
    S.cfg.contextCompaction = S.cfg.contextCompaction || {};
    const cc = S.cfg.contextCompaction;
    if (cc.minContextTokens == null) cc.minContextTokens = 200000;
    if (cc.idleMinutes == null) cc.idleMinutes = 50;
    body.appendChild(S.group('Context compaction'));
    body.appendChild(S.toggleField('Compact large idle sessions before their prompt cache expires', cc, 'autoCompact',
      'Types /compact into an idle Claude Code session whose context is at least the size below, once it has been idle '
      + 'that many minutes and while its prompt cache is still warm. A later resume then writes a small cache instead of '
      + 're-writing a large one. Compaction keeps a summary, not the conversation, so the agent loses detail. Never sends '
      + 'while the agent is working or waiting on you, or when the prompt holds unsent text. Off by default.'));
    body.appendChild(S.textField('Large context (tokens)', cc, 'minContextTokens', {
      type: 'number', number: true,
      help: 'Sessions at or above this size are compacted, and their sidebar context badge turns amber. 10000 to 10000000.',
    }));
    body.appendChild(S.textField('Idle minutes before compacting', cc, 'idleMinutes', {
      type: 'number', number: true,
      help: 'Minutes since the session’s last model call. Claude Code’s cache lasts an hour, so the default 50 leaves ten minutes of margin. 1 to 1440.',
    }));
  }

  T.automation = renderAutomation;
})();
