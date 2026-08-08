# Automation

Crow automates the boring parts of moving a ticket from "assigned" to "merged". This page is the single source of truth for what each automation does, how to turn it on or off, and where the toggles live.

## Lifecycle

A fully automated ticket walks through these stages:

1. **Assignment** — an issue is assigned to you. If it carries the `crow:auto` label *and* the **Auto-launch workspaces** toggle is on (off by default — #312), Crow auto-creates a workspace for it (#211).
2. **Workspace** — a git worktree is created, ticket metadata is captured, and the issue is moved to "In Progress" on the project board. For **GitHub** this is a Projects v2 status mutation; for **Jira** it transitions the work item to the status `jiraStatusMap` maps `In Progress` → (see [Jira status transitions](#jira-status-transitions)).
3. **Session** — Claude Code launches in plan mode with the issue context. Worker sessions inherit the configured permission mode; the Manager terminal can launch with `--permission-mode auto` (#189).
4. **PR open** — when Claude pushes the branch and you open a PR, Crow auto-suggests opening one if you forget (#213).
5. **Review** — repos that opt in get a review session auto-started when the PR turns reviewable (#209). The review board lets you batch-start, bulk-delete, and filter sessions (#207, #210, #212, #220, #226, #231).
6. **Status response** — Crow can prompt Claude to fix changes-requested reviews and failing CI runs without you typing anything (#214).
7. **Completion** — the session moves to Completed once the PR is merged or the issue is closed *and* the session shows positive evidence the work was attempted (#182). Session analytics are emitted via Claude Code's OpenTelemetry pipeline (#137).

## Settings → Automation tab

PR #228 split every automation toggle out of General into its own tab. Open **Settings → Automation** to find:

> **Also drivable from the CLI (#812).** `crow automation get` prints the whole tab as one JSON payload; `crow automation set` patches the toggles. Both surfaces write the same `config.json` through the same lock, and the daemon's mtime poll broadcasts `configReloaded`, so an open Settings modal and a CLI write stay in agreement. See [CLI Reference → Automation Commands](cli-reference.md#automation-commands). The config key named in each toggle entry below is its flag name in kebab-case (`autoMergeWatcherEnabled` → `--auto-merge-watcher-enabled`).
>
> The tab's three **list** fields under Reviews and Tickets are `AppConfig.defaults` fields, so `crow defaults set` writes them (`--add-exclude-review-repo`, …) — `crow automation get` echoes them read-only. The **Manager AI gateway** editor has its own local-only verb (`crow gateway`), and the **Jira (status fetch)** credential stays UI-only.

### Reviews

- **Excluded Repos** — comma-separated list of repos to hide from the review board, sidebar badge counts, and review notifications. Supports `*` wildcards: `zarf-dev/*` hides every repo in the org; `bmlt-enabled/yap` hides one. Backed by `defaults.excludeReviewRepos` in `{devRoot}/.claude/config.json`. Per-workspace auto-review opt-ins (#209) are configured separately in **Workspaces → edit workspace**.

### Tickets

- **Excluded Repos** — comma-separated, wildcard-aware list of repos to hide from the ticket board, pipeline counts, and auto-create candidates. Backed by `defaults.excludeTicketRepos`. An issue in an excluded repo will not be considered for auto-create even if it carries the `crow:auto` label.

### Remote Control

- **Enable remote control for new sessions** — when on, new Claude Code sessions launch with `--rc` so you can drive them from claude.ai or the Claude mobile app. Each session's remote name matches its Crow session name. Backed by `remoteControlEnabled`. Off by default.

### Manager Terminal

- **Launch in auto permission mode** — passes `--permission-mode auto` to the Manager's `claude` invocation so orchestration commands (`crow`, `gh`, `git`) run without per-call approval prompts. Default **on**. Requires:
  - Claude Code **2.1.83+**
  - **Max / Team / Enterprise / API** plan
  - **Anthropic** API provider (not Bedrock / Vertex / Foundry)
  - A supported model: **Sonnet 4.6**, **Opus 4.6**, or **Opus 4.7**
  - On Team / Enterprise plans, an admin must enable auto mode in Claude Code admin settings.

  Turn this off if your account reports auto mode as unavailable. Worker sessions and CLI-spawned terminals are unaffected. Takes effect on next app launch — the Manager's stored command is rebuilt on hydration.

### Jira MCP

`acli` cannot set a Jira assignee (at create or after) and its transitions are unreliable, so every ticket Crow filed landed unassigned. The **agent-side** Jira flow (create-with-assignee, assign/reassign, transition, fetch, comment) now routes through the **`jira` MCP server** (`sooperset/mcp-atlassian`, Docker stdio) using the `jira_*` tools. Crow's in-app issue-board polling and auto-complete still use `acli` (that path works); only the agent flow moved.

The `jira` server is configured **globally** in `~/.claude.json`'s top-level `mcpServers` (Docker stdio with `JIRA_URL` / `JIRA_USERNAME` / `JIRA_API_TOKEN`), so it is auto-loaded and trusted in **every** Claude Code session — worktrees, the Manager, and cron jobs. Crow therefore injects nothing: there is no per-session `.mcp.json` or `enabledMcpjsonServers` entry to write (CROW-528). The launched agent (and the `/crow-create-ticket`, `/crow-workspace`, `/crow-batch-workspace` skills) call the `jira_*` tools — `jira_get_issue`, `jira_create_issue`, `jira_update_issue`, `jira_transition_issue` (+ `jira_get_transitions`), `jira_add_comment`, `jira_get_user_profile` — instead of `acli`. `gh`/`glab` GitHub/GitLab task paths are untouched.

<a id="atlassian-mcp-headless-auth"></a>
**Headless auth — one-time setup.** The `jira` server authenticates with a **personal API token** via the `JIRA_*` env vars in its `~/.claude.json` entry. Create the token at <https://id.atlassian.com> → Security → API tokens and set `JIRA_URL` (your `https://<site>.atlassian.net`), `JIRA_USERNAME` (account email), and `JIRA_API_TOKEN`. The same global config serves the Manager and cron jobs, so no Crow-side credential is needed for the agent flow.

> **In-app status fetch.** The "Fetch from Jira" button in **Settings → Workspaces** (the #523 status map) calls Jira's REST API *directly from the crowd process*, which cannot use the MCP. That one feature uses a small **Settings → Automation → Jira (status fetch)** credential (`JIRA_USERNAME` + an `op://`/plaintext API token), stored in `config.json` as `jiraCredential`. It is unrelated to the agent-side MCP.

<a id="jira-status-transitions"></a>
**Jira status transitions (app-side).** The MCP above is *agent-side* (it lives in launched Claude sessions). Crow itself also moves a Jira work item through its workflow at three points the app owns — and those run **headless** (Manager, batch, cron), where no agent session is available:

- **Session start → mapped In Progress** — `/crow-workspace` and `/crow-batch-workspace` transition the work item as the worktree is set up (previously a no-op for Jira, so tickets sat in Backlog — #529).
- **Mark in review → mapped In Review** and **mark done → mapped Done** — the session-row "Mark in review" / "Mark issue done" actions, and their `crow mark-in-review` / `crow mark-issue-done` verbs. Neither transition is automatic: nothing moves a board to In Review when a PR opens, so a session that never runs one of these leaves its ticket where it was (`crow resync-jira`, below, is the bulk repair).

Each transition resolves the target status name via the per-workspace **`jiraStatusMap`** (#523; default `Ready`→`To Do`, others verbatim — e.g. `In Progress`→`In Development` for SecurityScorecard), then calls the Jira Cloud REST API: it **fetches the issue's available transitions first** and only fires one that reaches the mapped status, so an unmapped or currently-unavailable status is a logged **no-op rather than an error**. It reuses the same **Settings → Automation → Jira (status fetch)** credential (`jiraCredential`, HTTP Basic) as the status-map "Fetch from Jira" button above; with no credential configured it falls back to `acli`. This path does **not** depend on the agent-side MCP.

**Re-sync stuck tickets.** To fix Jira tickets left in Backlog by sessions started before this existed, run:

```bash
crow resync-jira
```

It walks every Jira-backed session and transitions its ticket to the status implied by the Crow session state (`active`→In Progress, `inReview`→In Review, `completed`→Done). Each move goes through the same graceful-degrade path, so tickets already in the right status are no-ops. You can also move a single session's ticket explicitly:

```bash
crow transition-ticket --session <uuid> --to inProgress   # or inReview | done
```

### Auto-respond

PR #214 added two opt-in toggles that let Crow type a follow-up instruction into a session's Claude Code terminal when a PR signal arrives. Both are off by default — typing into a running terminal unprompted is intrusive.

- **Respond to "changes requested" reviews** — when a PR review requests changes, Crow types an instruction into the linked session's Claude Code terminal asking Claude to read the review and address each comment.
- **Respond to failed CI checks** — when CI checks transition to failure, Crow types an instruction asking Claude to investigate the logs and push a fix.
- **Re-request review once changes are addressed** (CROW-921, on by default) — the one auto-respond toggle that types nothing. When a changes-requested PR's fix has landed and nobody has been asked to look again, the daemon calls `gh pr edit --add-reviewer` itself for each reviewer whose latest review is `CHANGES_REQUESTED`.

All three read from `AutoRespondSettings` in `AppConfig`. The two prompt-typing toggles need the session to have an active Claude Code terminal for the instruction to land; the re-request one does not, which is the point.

#### Why the re-request is not a prompt

A changes-requested PR has three states, and the loop used to model only two:

| State                                                             | Action           |
| ------------------------------------------------------------------ | ---------------- |
| No commits since the review                                       | prompt the agent |
| Fix landed, **the blocking reviewer has not been re-requested**    | re-request       |
| The blocking reviewer has been re-requested                        | wait             |

The middle row is the one that was missing. The only thing that re-requested review was a sentence inside the changes-requested prompt — and that prompt is reachable only while the agent still *owes* a fix, so it could never fire once the fix landed. A PR fixed by any other path parked in `changesRequested` indefinitely: the host had already cleared the review request when the reviewer submitted, so the PR was invisible to the reviewer's queue and to Crow's `review-requested:@me` board alike (CROW-921).

Note the row labels say *the blocking reviewer*, not *anyone*. Review requests are per-reviewer and the host clears only the submitting reviewer's, so a PR routinely carries reviewer A's changes-requested verdict alongside reviewer B's still-pending original request. Reading "does this PR have any pending request" would call that "wait" and silence both halves of the loop for a PR whose findings nobody has addressed — the same dead-end, reintroduced for multi-reviewer PRs. The decision is therefore scoped to the reviewers who actually requested changes (`PRStatus.changesRequestedReviewerIsPending`).

Doing it from the daemon rather than through the agent is what makes it reliable — a one-line API call routed through an agent turn costs a full turn's tokens, can't be verified, and would re-inherit the terminal gate that caused the dead-end. The prompt hint stays as belt-and-braces; re-requesting a reviewer who is already requested is a host-side no-op.

Two supporting details:

- **The commit anchor is the author date, not the committer date.** A rebase replays the feature commits with their committer date rewritten to ~now, which used to read as "the agent pushed a fix". Author dates survive a rebase, so a rebase-only advance no longer fires a no-op review round — or suppresses a genuine needs-refine. (`git commit --amend` and `cherry-pick` also preserve author dates, so an amend-delivered fix is indistinguishable from a rebase by dates alone; both failure directions are the safe one — Crow nudges the agent rather than pinging a reviewer.)
- **Every suppressed needs-refine evaluation is logged.** `crowd-automation.log` gets a `needs-refine: #N gated (reason=…, state=…, lastCR=…, lastCommit=…, reviewerReRequested=…, idle=…, cooldown=…)` line naming which gate held, emitted when the reason changes and at most hourly otherwise. Previously only *firing* was logged, so a stuck PR left no trace at all. The auto-re-request watcher's own skip and failure lines share that limiter, and its retries are capped — the inputs to a re-request are fixed for the life of a round, so a failure that isn't transient never becomes one.

#### Behind-ness is measured, not inferred (#944)

**Rebase and resolve conflicts** used to decide "is this branch behind its base?" from one
GitHub field, `mergeStateStatus == "BEHIND"`. That field is *single-valued* — it reports the
highest-priority reason the merge button isn't green, not a set of flags — so a PR that is
behind base **and** anything else reports the other value. `BLOCKED` (a required review not
yet in) masks it, and so do `DIRTY`, `DRAFT`, and `UNKNOWN`.

`BLOCKED` is the expensive one, because it is the *normal* state of a PR waiting on its
reviewer — exactly the window in which a busy base drifts ahead. On a repo with GitHub's
"require branches to be up to date before merging" rule, the PR then stalled short of merge
until a human pressed **Update branch**. The rebase Crow could have done for free during
review was instead serialized behind approval.

Crow now treats `mergeStateStatus` as a *candidate filter* only — anything open and not
`CLEAN` is worth a look — and asks git the actual question
(`git rev-list --count origin/<branch>..origin/<base>`) before spending a provider API call.
Consequences worth knowing:

- **A PR that needs nothing is a cheap no-op**, logged once per head state as
  `no-op:already-on-base`, with no force-push and no "Branch rebased" notification.
- **Drafts are still eligible**, as they have been since CROW-318 — a rebase only rewrites
  the session's own branch and can never merge. Drafts are where behind-ness was masked
  *permanently*, so this is where the change bites most.
- **Every open GitLab MR is now a candidate**, because the GitLab backend never populates
  `mergeStateStatus`. MRs do fall behind and nothing else handled them; the cost is one
  `git fetch` per head state.
- **The `crow:merge` hand-off is narrower.** Auto-rebase yields to auto-merge's
  `gh pr update-branch` only while auto-merge can still act. Before, the yield was
  unconditional, so once auto-merge burned its one-shot per-head attempt and gave up,
  *nobody* brought the branch up to date.

#### A wedged branch now says so

`rebaseOntoBase` refuses to force-push a worktree that is ahead of, or diverged from,
`origin/<branch>` — a force-push there would publish unpushed work or revert remote commits.
That refusal used to back off on an exponential delay capped at 15 minutes and then repeat
forever, in silence: the only trace was `deferred:out-of-sync-diverged` in
`crowd-automation.log`, and the PR pill rendered as fully green because `mergeStateStatus`
never reaches the web at all.

After five consecutive deferrals of the same reason — the point at which the backoff has
saturated, so ~30 minutes and four failed retries in — the session card grows a **⟲** chip
(orange while waiting, red once stuck) carrying a sentence that names the fix, and a
**Rebase Stuck** notification fires once per PR and reason.

Escalating is *not* giving up: Crow keeps retrying at the cap, so whatever you do to
reconcile the branch is picked up on the next cycle. Crow deliberately does **not** try to
self-heal a diverged worktree — by definition it holds commits `origin` doesn't, and any
automated reset would destroy them — and, unlike the conflict path, it does not hand off to
the agent, for the same reason.

### Auto-launch workspaces

PR #312 gated the existing `crow:auto` label automation behind a single opt-in toggle. Off by default — typing `/crow-workspace` into the Manager terminal without an explicit opt-in is intrusive, and matches the precedent set by `crow:merge` auto-merge (#299).

- **Auto-launch workspaces for `crow:auto` labeled issues** — when on, Crow watches assigned open issues each polling cycle. If one carries the `crow:auto` label, Crow sends `/crow-workspace <issue-url>` to the Manager terminal and strips the label so the trigger is one-shot. While off, the label is intentionally left in place so a later opt-in still picks up the issue. Requires Crow (and the Manager) to be running.

Backed by `AppConfig.autoCreateWatcherEnabled`. Issues in `excludeTicketRepos` are filtered before the toggle is consulted, so they remain ignored regardless of the setting.

### Auto-merge

PR #299 added a single toggle that lets Crow enable GitHub's native auto-merge on Crow-authored PRs carrying the `crow:merge` label. Off by default.

- **Enable `crow:merge` auto-merge for Crow-authored PRs** — when on, Crow watches each session's linked PR. If it sees the `crow:merge` label, the commits include a `Crow-Session: <uuid>` trailer matching a known Crow session, and the PR is not in `CONFLICTING`/`CHANGES_REQUESTED`/draft state, Crow runs `gh pr merge --auto --squash --delete-branch`. GitHub holds the merge server-side until required reviews and checks pass; Crow only enables it once per PR (idempotent via `Session.autoMergeEnabledAt`).

Backed by `AppConfig.autoMergeWatcherEnabled`. Hand-written PRs without the Crow trailer are ignored even when labeled. Crow lazily creates the `crow:merge` label in the repo on first observation so repo owners don't need to pre-seed it.

**The label is a request, not an action** (#888). Applying it — via the session menu, `crow add-merge-label`, or GitHub itself — does not merge anything on its own; the watcher decides. When the watcher can't act, it now says so instead of only writing to `crowd-automation.log`:

- The session's PR pill carries a tinted ⛙ chip — green (auto-merge enabled, waiting on GitHub), purple (Crow merged it directly), orange (will retry), red (permanently blocked), grey (the watcher is off) — with the full reason in its tooltip and `aria-label`. The chip appears only on PRs that actually asked for auto-merge: a PR Crow has never seen carrying `crow:merge`, and has never armed, is left alone rather than described in auto-merge vocabulary it never earned.
- A permanent block also fires an **Auto-Merge Blocked** notification, once per PR rather than once per poll.
- `crow add-merge-label` still applies the label and still returns `ok: true`, but adds a `warning` field when the label can't lead to a merge.
- When the repo has GitHub's **Allow auto-merge** setting off, `gh pr merge --auto` can never succeed. Crow reads `Repository.autoMergeAllowed` from the same GraphQL fetch it already makes, so it knows this before attempting the mutation, and **falls back to a direct squash merge** (`gh pr merge --squash --delete-branch`) when the PR is OPEN, non-draft, `CLEAN`, `MERGEABLE`, checks `SUCCESS`, `APPROVED`, and Crow-authored. Anything short of that is reported as blocked rather than merged — a direct merge has no server-side gate, so every check GitHub would have enforced is re-checked first.

## Automation notifications

Every automation above acts without you asking, so each one announces itself. Alongside the
five agent/PR events (Task Complete, Agent Waiting, Review Requested, Changes Requested, CI
Failing), the daemon pushes seven **automation** events to connected clients at the moment a
watcher acts:

| Event                    | Fires when                                                              |
| ------------------------ | ----------------------------------------------------------------------- |
| Auto-Workspace Created   | A `crow:auto`-labeled assigned issue triggered `/crow-workspace`         |
| Auto-Merge Enabled       | Crow enabled auto-merge on a `crow:merge`-labeled PR                     |
| Auto-Merge Blocked       | Crow gave up on a `crow:merge` PR (needs attention — a permanent skip latches, so nothing re-announces it) |
| Branch Rebased           | An auto-rebase succeeded and force-pushed                               |
| Rebase Conflicts         | An auto-rebase hit conflicts (needs attention — deliberately harsher tone) |
| Rebase Stuck             | An auto-rebase can't proceed — a dirty worktree, or local commits a force-push would destroy (needs attention; fires once per PR + reason) |
| Config Reloaded          | `{devRoot}/.claude/config.json` changed and was picked up               |

Each has its own **Enabled / Play sound / System notification / Sound** row under
**Settings → Notifications**, on top of the global mute and sound/system category toggles.
Unlike the session events, these are not suppressed when you are already looking at the
session they belong to — an action Crow took on your behalf is worth surfacing either way.

Transport is the existing `/rpc` WebSocket: the daemon broadcasts an idless JSON-RPC
`notify` frame (`EventHub.notifyFrame`), which the web client turns into a chime plus a
browser/Tauri notification with the same 2s per-`(key, event)` dedup as everything else.

## Per-PR feature notes

Short descriptions of each shipped automation, in roughly the order they fire during the lifecycle.

### #211 — Auto-create workspace on `crow:auto` label

When an issue assigned to you carries the `crow:auto` label *and* the **Auto-launch workspaces** toggle is on (PR #312, off by default), the issue tracker auto-creates a workspace for it on the next polling cycle (every 60s). It picks the right repo, opens a worktree, captures ticket metadata, and launches Claude Code in plan mode with the issue context. Issues in `excludeTicketRepos` are skipped. While the toggle is off the label is left in place, so flipping it on later still picks up previously-labeled issues.

### #189 — Manager auto permission mode

The Manager terminal launches in `--permission-mode auto` by default so orchestration commands run without prompts. Toggle is at **Settings → Automation → Manager Terminal**. See above for plan / model requirements.

### #182 — Positive-evidence auto-complete

Auto-complete (PR merged / issue closed) no longer fires solely on the GitHub signal. The session must also show positive evidence that work was attempted — at minimum a started Claude Code terminal with non-empty activity. This prevents idle sessions from being marked completed when an unrelated PR lands.

### #213 — Auto-suggest opening a PR

When a session completes its work locally but no PR is linked, Crow surfaces a "Open PR" suggestion on the session detail surface. Clicking it walks Claude Code through `gh pr create` against the session's branch.

### #209 — Auto-start review sessions for opted-in repos

A per-workspace setting (Workspaces → edit workspace → Auto-review). When on, any reviewable PR in that workspace's repos triggers a review session in the background — Crow clones into `{devRoot}/crow-reviews/`, launches Claude Code with the review prompt, and surfaces it on the review board when ready.

### #214 — Auto-respond to PR status changes

See the **Auto-respond** toggles in the Settings tab section above. Crow watches the PR for review-changed and check-failed transitions on the standard 60-second polling cycle.

### #299 — Auto-merge on `crow:merge` label

When a PR linked to an active Crow session carries the `crow:merge` label, the IssueTracker enables GitHub native auto-merge on the next poll. Eligibility is conjunctive: the label must be present, at least one commit on the PR must carry a `Crow-Session: <uuid>` trailer whose UUID matches a session this Crow instance knows about, and the PR must not be a draft / conflicting / changes-requested. The merge method is hard-defaulted to **squash with branch delete** to match the existing `/merge-pr` quick action.

Crow does not babysit the merge — GitHub queues it server-side and fires once required checks settle. Enablement is one-shot per PR: `Session.autoMergeEnabledAt` is persisted on success, and an in-memory dedupe set protects the gap between dispatch and persistence. Trailer-with-unknown-session is treated as not-Crow-authored (defensive: someone copy-pasting our trailer convention into a hand-written commit should not be able to trigger auto-merge). If the repo has GitHub **Allow auto-merge** disabled (`enablePullRequestAutoMerge`), Crow logs once and stops retrying for that PR for the process lifetime rather than spamming every poll (CROW-621); transient `gh` failures still retry.

#888 addressed the silence around that permanent skip. Crow now reads `Repository.autoMergeAllowed` from the GraphQL fetch it was already making, so the repo-policy case is detected *before* the failed mutation rather than by string-matching its error (the error match survives as a backstop for records where the field wasn't fetched). The twelve skip reasons — previously six enum cases plus six ad-hoc string literals — are one enum carrying a log-stable `rawValue`, a human sentence, and a permanence flag; the verdict is published to `AppState.autoMergeState` and shipped on `list-sessions-live` as `auto_merge_state` (`{phase, reason, message, permanent}`). Reasons the PR pill already renders (conflicts, changes-requested, no label) are deliberately *not* republished, so two surfaces can't disagree about one PR (CROW-773). A repo that forbids auto-merge now also gets a direct squash-merge fallback for fully green, approved, Crow-authored PRs.

Audit trail: each enable writes `[Crow] Auto-merge enabled on <pr-url> (session <uuid>, squash)` to the system log and posts a banner notification; each permanent block writes an `auto-merge:` line and fires an **Auto-Merge Blocked** notification, once per (PR, reason).

### #137 — Session analytics via OpenTelemetry

Claude Code's OpenTelemetry exporter is wired up so each session emits standard OTLP metrics for token counts, tool-call latency, and turn duration. Configuration follows Claude Code's own env vars (e.g. `CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_EXPORTER_OTLP_ENDPOINT`); Crow does not collect telemetry itself.

## Where it lives

| Concern                          | File                                                                                              |
| -------------------------------- | ------------------------------------------------------------------------------------------------- |
| Settings tab UI                  | `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/settings.js`                                     |
| CLI verb (`crow automation`)     | `Packages/CrowCLI/Sources/CrowCLILib/Commands/AutomationCommands.swift`                                |
| `automation-*` RPC handlers      | `Packages/CrowDaemon/Sources/CrowDaemon/RPCHandlers.swift` + `Packages/CrowEngine/Sources/CrowEngine/SettingsRPCSupport.swift` (`SettingsRPC.automationJSON`, `ListPatch`) |
| Persisted toggles                | `Packages/CrowCore/Sources/CrowCore/Models/AppConfig.swift` (`ConfigDefaults`, `AutoRespondSettings`) |
| Manager auto-permission decision | `Packages/CrowEngine/Sources/CrowEngine/SessionService.swift` (Manager command rebuild)                                    |
| Auto-create / auto-respond loop  | `Packages/CrowEngine/Sources/CrowEngine/IssueTracker.swift` (60s polling cycle)                                         |
| Review session auto-start        | `Packages/CrowEngine/Sources/CrowEngine/IssueTracker.swift` + per-workspace flag in `AppConfig`                         |
| Auto-merge watcher (`crow:merge`)| `Packages/CrowEngine/Sources/CrowEngine/IssueTracker.swift` (`applyAutoMerge`, `extractCrowSessionUUIDs`, `crowAuthored`) |
| Auto re-request review            | `Packages/CrowEngine/Sources/CrowEngine/IssueTracker.swift` (`applyAutoReRequestReview`, `autoReReviewSkipReason`, `agentSettled`) + `PRStatus.changesRequestedState` + `CodeBackend.requestReviewers` |
| Auto-merge verdict → UI          | `Packages/CrowEngine/Sources/CrowEngine/IssueTracker.swift` (`AutoMergeSkipReason.state`, `publishAutoMergeVerdict`) → `Packages/CrowDaemon/Sources/CrowDaemon/RPCHandlers.swift` (`list-sessions-live` → `auto_merge_state`) → `.../web/app.js` (`PR_AUTOMERGE_GLYPH`, `prAutoMergeGlyph`) |
| Direct-merge fallback            | `Packages/CrowEngine/Sources/CrowEngine/IssueTracker.swift` (`shouldDirectMerge`, `directMergeGatesPass`, `performDirectMerge`) + `CodeBackend.mergeNow` |
| Automation notification push     | `Packages/CrowDaemon/Sources/CrowDaemon/CrowDaemon.swift` (`wireTrackerAutomations`) + `EventHub.notifyFrame`             |
| Notification events + defaults   | `Packages/CrowCore/Sources/CrowCore/Models/NotificationEvent.swift`                                                       |
| Chime / browser notification     | `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/app.js` (`onServerNotify`, `emitEvent`)                             |

## See also

- [Configuration](configuration.md) — full schema for `{devRoot}/.claude/config.json`, including `excludeReviewRepos`, `excludeTicketRepos`, `remoteControlEnabled`, and `managerAutoPermissionMode`.
- [Getting Started](getting-started.md) — first-launch setup that creates the config file these toggles write to.
- [Troubleshooting](troubleshooting.md) — what to do when an automation does not fire as expected.
