# Session backfill (CROW-1075)

A **user-initiated** backfill that captures the coding-session history already on
disk — sessions that predate the live upload path ([#1056](https://github.com/corveil/crow/issues/1056))
or were reaped from Crow's store — and uploads them as **real, fully-linked**
Corveil session artifacts, not orphans. Part of epic
[corveil/corveil#2425](https://github.com/corveil/corveil/issues/2425).

The live collector (`LogSyncCollector`) is **session-centric**: it walks Crow's
`store.json` and uploads one artifact per live, quiescent Crow session. It never
touches the disk. But the disk holds the real history — hundreds of Claude
`.jsonl` transcripts under `~/.claude/projects`, most orphaned from any Crow
session record. This feature is strictly that **historical backlog**: for the
current user now, and for every new user who arrives with a big backlog.

## The server contract is already there (decision #2)

No corveil companion change is needed. `POST /api/crow-sessions/{uid}/artifacts`
([corveil#2426](https://github.com/corveil/corveil/issues/2426), merged in
corveil#2433) already:

- **Creates the `crow_sessions` parent from an arbitrary `{uid}`.** The parent is
  a Class-A object, not an FK to a pre-existing Crow session — that is the whole
  point of the design (interactive sessions have no `worker_run`). The live
  collector already uploads with a session UUID the server has never seen, so
  using a **Claude session UUID (the `.jsonl` stem)** as `{uid}` is the same
  shape (decision #1).
- **Derives the authoring `Person` server-side from the API key**, never from the
  payload. The sidecar (`repo`, `ticket_url`, …) is *untrusted hints*.
- **Builds `REFERENCES` downstream** in the derive job
  ([corveil-cloud-terraform#459](https://github.com/corveil/corveil-cloud-terraform/issues/459))
  from the *validated* reconstructed repo/ticket.
- **Is write-once** — a second upload of the same `(session, harness, kind)` is a
  409, treated as an idempotent success.

The producer-side obligation (decision #3) is therefore only: **never stamp a
`ticket_url`/`ticket_number` into the sidecar unless the provider confirms the
issue/PR exists.**

## Reconstruction — "fill in the gaps"

For each on-disk transcript, `BackfillScanner` recovers what a live run would
have sent, working from the **transcript's own recorded `cwd` and `gitBranch`**
(authoritative — not the lossy project-slug directory name, which flattens every
`/` and `-` alike):

- **Workspace** = the first path component of `cwd` under the dev root.
- **Worktree** = the next component, `<repo>-<number>-<slug>`.
- **Repo → `owner/repo`** = the `<repo>` matched against a `repoName → RepoRemote`
  map built by reading the `origin` remote of the live clones under the dev root.
  One resolvable clone (a main checkout or any still-present worktree) gives every
  reaped worktree of that repo its `owner/repo`. The known repo names also
  disambiguate the `<repo>-<number>` split (`corveil-cloud-terraform-331-…` →
  repo `corveil-cloud-terraform`, ticket 331, not repo `corveil`).
- **Ticket** = the `<number>`, corroborated by the branch.
- **Person** = server-derived from the API key (always correct).

Each session gets a confidence tier:

| Tier | Condition | Upload |
|---|---|---|
| `high` | repo resolved **and** a ticket number parsed | validated ticket link |
| `medium` | repo resolved, no ticket | repo-only |
| `low` | no workspace / no repo (orphan) | attributed, unlinked — only if selected |

The scan is **disk- and git-only** (no provider calls), so it is fast over
hundreds of sessions. Ticket **validation** is deferred to upload, where a link
is actually asserted: `TicketValidator` runs one `gh api repos/{o}/{r}/issues/{n}`
(GitHub returns issues and PRs, distinguished by a `pull_request` member) — a
clean 404 means no link, an auth/network failure is inconclusive (repo-only, not
a false "not found").

## Upload — reuse the live path, idempotently

`BackfillService.upload` normalizes the single `.jsonl` with the same
`TranscriptNormalizer`, validates the ticket, builds the sidecar (gating the
ticket fields on validation), and POSTs through the same `TranscriptUploader` as
the live collector. Destination and credential come **solely** from the named
workspace's local-only AI gateway — the same security invariant as the live path;
no browser-writable field can redirect a credential-bearing upload, and no AWS
credential touches the laptop.

Idempotency is doubly enforced: the local ledger (`logsync-ledger.json`) skips a
slot already recorded uploaded, and the server 409s a duplicate. Because backfill
is a **second writer** to that ledger (the poll loop is the first), both now go
through a shared, serialized `LogSyncLedgerStore` actor so no update is lost.

Uploads are serial, capped, and **always user-initiated** — never automatic or
unbounded.

## Surfaces

- **Settings → Workspaces → (edit) → Session logs → "Backfill history…"** — a
  reviewable table (workspace · repo · ticket · date · size · status ·
  confidence) with filters, multi-select, select-all-by-filter, and a counted
  "Backfill (N)" action that reports per-session outcomes. Gated on the workspace
  having a gateway (the upload reuses it), like the opt-in checkbox beside it.
- **CLI** — `crow backfill scan` and
  `crow backfill upload --workspace NAME (--session UID… | --all-high-confidence | --all)`.
  See [cli-reference.md](cli-reference.md#session-backfill-commands).

## Scope

- **Claude Code, Codex, Grok Build, Cursor, OpenCode, and Muse Code** — the
  harnesses whose transcripts can be reliably attributed to a worktree (CROW-1089,
  CROW-1098, CROW-1095, CROW-1096, CROW-1106). Claude and Grok partition their logs
  by working directory
  (Claude slugifies the path; Grok URL-encodes it into the directory name,
  `~/.grok/sessions/<url-encoded-cwd>/<uuid>/chat_history.jsonl`, so the scan
  recovers the cwd by decoding the directory name). Codex pools its
  `~/.codex/sessions/**/rollout-*.jsonl` globally but records the real `cwd` in
  each rollout's first-line `session_meta`; Cursor pools its
  `~/.cursor/chats/<id>/<sub>/store.db` globally but records the `cwd` in the
  sibling `meta.json`; OpenCode (1.17.10+) keeps every session in the
  `~/.local/share/opencode/opencode.db` SQLite store, each `session` row recording
  the `directory` it ran in; and Muse pools its
  `~/.local/share/muse/sessions/**/session.jsonl` globally but records the cwd in
  each journal's line-1 `runtime.session.metadata` record
  (`payload.record.workspace_root`), so the scan reconstructs those from the file
  head. All make historical reconstruction reliable because the authoritative `cwd`
  is recoverable, not a lossy directory name. The scan stays disk- and git-only —
  for Cursor the uid is the `<subId>` directory name and the cwd a tiny sibling JSON
  read, so the `store.db` is opened only at upload time (where `CursorStore`
  extracts the ordered messages); OpenCode records no git branch, so its ticket is
  parsed from the worktree name alone, its shared `filePath` is the database (one
  session reassembled by id at upload), and child/subagent OpenCode sessions are
  excluded (they belong to a parent). Muse's `subagent/` child journals are skipped
  the same way (each is a different session; the parent supplies its cwd). ⚠️ The
  Muse `workspace_root` key is unverified against a live install (Meta-auth-gated,
  CROW-1099) — it fails safe: a journal with no readable cwd reconstructs as a
  low-confidence orphan, never a misattributed link. Other harnesses follow as their
  `logSources` land (see
  [session-log-collector.md](session-log-collector.md), and
  [harness-transcript-locations.md](harness-transcript-locations.md) for the
  verified per-harness on-disk locations).
