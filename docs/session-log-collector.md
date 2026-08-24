# Session-log collector (CROW-1056)

Crow collects durable coding-session logs and — **opt-in per workspace, OFF by
default** — uploads them to Corveil as session-transcript artifacts, with the
Crow session's metadata attached. This is the **producer** side of epic
[corveil/corveil#2425](https://github.com/corveil/corveil/issues/2425); the
storage/endpoint side is [#2426](https://github.com/corveil/corveil/issues/2426)
(merged in corveil/corveil#2433).

## Why the adapter owns log locations

Crow persists **no** transcript of its own — terminal scrollback is
tmux-memory-only, captured on demand for browser replay, never written to disk.
But **each harness writes its own durable logs**, in a different place and
format. The `CodingAgent` adapter already knows how to launch each harness, so it
also declares where that harness's logs live, via a new protocol capability:

```swift
func logSources(worktreePath: String, harnessSessionID: String?) -> [AgentLogSource]
```

The protocol-extension default returns `[]` (the same opt-in idiom as
`fallbackCandidates`), so a harness whose on-disk location is unconfirmed
contributes nothing rather than uploading the wrong bytes.

## Harness coverage

**Claude Code**, **Codex**, **Grok Build**, and **Cursor** are wired (CROW-1089 /
CROW-1098 / CROW-1095). Claude and Grok partition their logs by working directory,
so a Crow worktree maps straight to that session's transcripts — Claude by
slugifying the path, Grok by URL-encoding it into the directory name. Codex and
Cursor pool their stores globally, so they're attributed by **content** instead:
the source scans the whole tree but carries a `cwdFilter`, and the collector keeps
only the sessions whose recorded `cwd` matches the worktree. Codex records the cwd
in its rollout head (`AgentLogCwdReader`); Cursor records it in the sibling
`meta.json` (`CursorStore.recordedCwd`). A session with no readable cwd is dropped,
never guessed.

| Harness | On-disk location | Status |
|---|---|---|
| `claude-code` | `~/.claude/projects/<slug>/<uuid>.jsonl` (slug = worktree path, every non-alphanumeric → `-`) | **Wired.** One artifact per session; multiple `.jsonl` under the slug dir are concatenated. |
| `codex` | `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<uuid>.jsonl` (already NDJSON; cwd in the first-line `session_meta.payload.cwd`) | **Wired.** Recursive `.logDir` source with a `cwdFilter`; the collector keeps only cwd-matching rollouts and concatenates them (`~/.codex/archived_sessions` and `.../log` are not scanned). |
| `cursor` | `~/.cursor/chats/<chatId>/<subId>/store.db` (CLI store; cwd in the sibling `meta.json`) | **Wired.** Recursive `.sqlite` source (`fileExtension: db`) with a `cwdFilter`; `CursorStore` follows the `meta['0'].latestRootBlobId` root blob's ordered message-blob refs and emits each message's JSON as one NDJSON line. Not the Cursor IDE's `state.vscdb`. |
| `grok` | `<$GROK_HOME or ~/.grok>/sessions/<url-encoded-cwd>/<uuid>/chat_history.jsonl` (already NDJSON; directory name is the cwd URL-encoded, `/`→`%2F`) | **Wired.** Recursive `.jsonl` source pointed at the encoded worktree directory, filtered to `chat_history.jsonl`; attribution is exact by construction (no `cwdFilter`), so sibling `events.jsonl` / `prompt_history.jsonl` are left out. |
| `opencode` | `~/.local/share/opencode/storage/{project,session,message,part}` | Deferred — a `project/<id>.json`'s `worktree` maps to the cwd, but a session's `message`/`part` records must be reassembled into ordered NDJSON first. |
| `antigravity` | `~/.gemini/antigravity-cli/brain/<conv-id>/.system_generated/logs/transcript_full.jsonl` (JSONL; pooled globally, keyed by id) | Deferred — the transcript records **no cwd** at all (step records are `step_index`/`type`/`source`/`status`/`created_at`), so a `cwdFilter` source would drop every file. The cwd lives only off-transcript (a conditional protobuf-in-SQLite per-conversation DB, the ephemeral hook / status-line payloads, or the latest-only `cache/last_conversations.json` pointer), which the current reader can't consume (CROW-1097). |
| `muse` | `~/.local/share/muse/sessions/<YYYY>/<MM>/<DD>/<id>/session.jsonl` (durable, already JSONL) | Deferred — durable global JSONL store **confirmed** (Meta dev cookbook, CROW-1099). The cookbook documents no cwd field (its jq prints only event records, whose git refs `base_commit`/`base_ref` collide across worktrees), but a first-hand third-party parser reports the cwd at `runtime.session.metadata.workspace_root` (line 1), so attribution is **likely** possible (content-filtered, Codex-style). Format fits `.logDir` as-is; verify `workspace_root` on a real `session.jsonl` (Meta-auth-gated), then wire. |

The framework (collector, normalizer, uploader, ledger, config, CLI) is
harness-general; wiring a deferred harness is implementing its `logSources`
override — plus, for a `.sqlite`/multi-file store, a normalizer for that on-disk
shape (the Cursor `.sqlite` store is normalized by `CursorStore`). A
globally-stored harness attributes by `cwdFilter` rather than a per-worktree path
(Codex and Cursor are the references), reading the cwd from the transcript head or
a sibling metadata file as its shape dictates; a directory-partitioned one maps the
worktree path straight to its directory (Claude and Grok).

Harnesses map to the artifact contract's `harness` value via
`LogSyncHarness(agentKind:)`. The four the server enumerates
(`claude`/`cursor`/`codex`/`opencode`) map directly. Grok maps to an internal
`.grok` that drives the local ledger slot and the backfill display, but its
`wireValue` collapses to `unknown` on the wire because the server's CHECK does not
(yet) accept `grok` — the upload is still accepted and attributed (the true kind
rides along in the `agent_kind` sidecar hint), just not harness-typed. Every other
kind maps to `unknown`.

## Pipeline

```
CrowDaemon.startLogSyncPoll (5-min tick, config read fresh each tick)
  └─ LogSyncCollector.sweep(appState):
       for each live session on an OPTED-IN workspace (SessionService.workspaceName):
         agent.logSources(worktree) → resolve files → normalize to NDJSON
         (skip until quiescent: terminal status, or newest file older than quietPeriod)
         → TranscriptUploader → POST /api/crow-sessions/{sessionUID}/artifacts
         → record in the local ledger (idempotent)
```

- **Attribution** is by worktree-path match (`AppState.sessionIDs(forWorktreePath:)`),
  the same resolution the hook-event handler uses. Metadata attached as untrusted
  sidecar hints: session UUID (the `{sessionUID}`), name, status, `agentKind`,
  ticket URL/number, repo, org goal. The server derives the *authoring principal*
  from the API key, never from these hints.
- **Upload** authenticates with the workspace operator's own Corveil API key
  (`Authorization: Bearer …`, resolved from an `op://…` reference via the same
  `GatewayResolver.opRead` the gateway uses). The server performs the
  object-storage upload — **no AWS credentials live on the laptop**.
- **Format**: uncompressed NDJSON. The server sniffs content-encoding from magic
  bytes, so plain NDJSON is stored with an empty `content_encoding`; gzip is a
  future size optimization (it would let larger transcripts fit under the cap).

## Guarantees (acceptance)

- A completed session on an **opted-in** workspace has its transcript uploaded
  with correct Crow metadata.
- An **opted-out** workspace uploads nothing (per-workspace gate; default OFF).
- **No AWS credential** on the laptop (server-side upload).
- **Backfill is idempotent**: the on-disk ledger
  (`{devRoot}/.claude/logsync-ledger.json`) plus the server's write-once 409 mean
  a repeated sweep re-converges without re-uploading. The sweep visits every
  known session, so enabling the feature backfills existing on-disk history.
- **Upload failure never delays or fails a session**: the collector runs entirely
  off the session lifecycle; each upload retries once, then the ledger records the
  outcome (transient failures back off ~30 min).

## Write-once and quiescence

The server keys an artifact on `(session, harness, kind)` and rejects a second
upload with 409. So the collector uploads a session's transcript **once, when it
has gone quiescent** — terminal status (`completed`/`archived`) or no log-file
activity within `quietPeriodMinutes` (default 30) — to avoid capturing a partial
transcript it could never replace.

## Opt-in and controls (CROW-1070)

A workspace uploads its coding-session transcripts iff **both**:

1. its **"Upload session transcripts to Corveil"** checkbox is on
   (`WorkspaceInfo.uploadSessionLogs`, default `false`) — set in Settings →
   Workspaces or with `crow workspace edit --workspace NAME --upload-session-logs true`; **and**
2. the workspace has an **AI gateway** configured.

That is the whole opt-in. There is no separate global master switch, base URL or
API-key reference — CROW-1070 removed them. The upload **destination and
credential are the workspace's own gateway** (see below), so ticking the box on a
workspace that already routes its LLM traffic through Corveil is all it takes.

The remaining global block, `AppConfig.logSync`, holds only **behavior knobs** —
`retentionDays`, `quietPeriodMinutes`, `maxUploadBytes`. These are not credentials,
so unlike the pre-1070 block they are an ordinary, browser-editable config surface:
Settings → General → **Session logs**, or the (no-longer-local-only) `crow logsync`
CLI. See [cli-reference.md](cli-reference.md#session-log-sync-commands).

### Gateway reuse — destination and credential (the security invariant)

For an opted-in workspace, `LogSyncCollector.resolvedUpload(for:)` derives the
upload target **solely** from that workspace's local-only `gateway`:

- **Destination** = `{gateway.baseURL}/api/crow-sessions/{sessionUID}/artifacts`.
  The Corveil gateway `baseURL` is the Corveil host root (e.g. `https://corveil.io`
  — see [configuration.md](configuration.md#ai-gateway)), which is exactly where the
  REST artifact endpoint lives.
- **Credential** = the gateway's Corveil key. The collector looks it up
  case-insensitively, preferring `x-citadel-api-key` then `authorization` /
  `x-api-key` / `x-corveil-key` defensively, resolves an `op://…` reference the same
  way the gateway launch path does, and strips a leading `Bearer ` so
  `TranscriptUploader` can re-wrap the bare key as `Authorization: Bearer <key>`.

**The invariant:** the destination and credential come only from the **local-only**
gateway — never from any browser-writable workspace field. A web-flippable field must
not be able to choose where a *credential-bearing* upload goes, or an authenticated
remote peer could redirect the workspace's Corveil key to a host it chose (an
exfiltration vector). `resolvedUpload` reads only the gateway; a workspace with no
gateway (or no resolvable key) returns `nil` and uploads nothing — a browser field
alone can never supply a destination. This is asserted in `LogSyncCollectorTests`
(`resolvedUploadComesFromTheGateway`, `noGatewayResolvesToNil`).

Why this is safe where the earlier design wasn't: the `crow gateway` config is itself
**local-only** (CROW-815 — it carries credentials, so the remote `/rpc` path refuses
it and only the local Unix socket can write it). Reusing it introduces **zero** new
exposure — it is the same local-only, already-trusted key going to the same Corveil
host that already receives the workspace's LLM traffic. The only thing a remote peer
gains from the browser-flippable checkbox is toggling one workspace's transcript
upload on/off, to the operator's own Corveil, with a credential it can neither see
nor change.

### Decisions recorded here (CROW-1070)

1. **Dropped the global `logSync.enabled` master switch.** A ticked checkbox plus a
   configured gateway is the only gate. The old switch was the "check the box and
   nothing happens" foot-gun (uploads also required a separate `crow logsync set
   --enabled true`), so removing it is the fix, not a regression.
2. **The behavior knobs (`retentionDays`/`quietPeriodMinutes`/`maxUploadBytes`) moved
   to the web Settings UI** (General → Session logs) as well as the CLI, since they
   carry no credential. A slim, no-longer-local-only `crow logsync get/set` stays for
   control-plane parity (ADR 0016) and headless hosts.
3. **Migration.** A legacy opt-in via `crow logsync set --add-workspace` (the removed
   `logSync.enabledWorkspaces` list) is carried over on first boot by
   `LogSyncMigration` / `ConfigStore.migrateLogSyncAtBoot` — a listed workspace's
   `uploadSessionLogs` is set (only when the legacy master switch was on, so a
   workspace that uploaded nothing before keeps uploading nothing). The removed keys
   (`enabled`/`baseURL`/`apiKeyRef`/`enabledWorkspaces`) drop on the re-encode, so the
   migration is idempotent. A legacy workspace with no gateway simply needs a gateway
   configured before it uploads — that reuse is now the point.

## Depends on

- The artifact contract + upload endpoint, [#2426](https://github.com/corveil/corveil/issues/2426)
  (`POST /api/crow-sessions/{sessionUID}/artifacts`).
- `docs/agent-harness-matrix.md`, ADR 0014 / 0015.

## See also

- [harness-transcript-locations.md](harness-transcript-locations.md) — the
  verified **on-disk transcript location** per harness (CROW-1090): the input this
  collector's `logSources` overrides are built from, including the leads and
  open questions feeding the CROW-1089 fan-out (#1095–#1099).
- [session-backfill.md](session-backfill.md) — the **historical** backfill
  ([CROW-1075](https://github.com/corveil/crow/issues/1075)): a user-initiated
  reconciliation of the on-disk transcripts this session-centric collector never
  reaches (reaped or ad-hoc sessions), reusing this same upload path.
