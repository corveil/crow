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

Only **Claude Code** partitions its logs by working directory, which is what
makes a Crow worktree map cleanly to exactly that session's transcripts:

| Harness | On-disk location | Status |
|---|---|---|
| `claude-code` | `~/.claude/projects/<slug>/<uuid>.jsonl` (slug = worktree path, every non-alphanumeric → `-`) | **Wired.** One artifact per session; multiple `.jsonl` under the slug dir are concatenated. |
| `codex` | `~/.codex/sessions/<YYYY>/…`, `~/.codex/archived_sessions`, `~/.codex/log` | Deferred — global, timestamp-partitioned; needs per-file `cwd` matching. |
| `opencode` | `~/.local/share/opencode/storage/{session,message,part}`, `.../log` | Deferred — global storage keyed by opencode session id; needs project→worktree matching. |
| `cursor` | `~/Library/Application Support/Cursor/User/workspaceStorage/<hash>/state.vscdb` | Deferred — per-workspace **SQLite**; needs `workspace.json` hash→path matching + chat-row extraction. |
| `grok`, `antigravity`, `muse` | app state / TBD | Deferred — log locations unconfirmed. |

The framework (collector, normalizer, uploader, ledger, config, CLI) is
harness-general; wiring a deferred harness is implementing its `logSources`
override plus, for `.sqlite`, a row extractor in `TranscriptNormalizer`.

Harnesses map to the artifact contract's `harness` value via
`LogSyncHarness(agentKind:)` — the four the server enumerates map directly, every
other kind maps to `unknown`.

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

## Controls — `crow logsync` (local-only, default OFF)

`AppConfig.logSync` (`enabled`, `baseURL`, `apiKeyRef`, `enabledWorkspaces`,
`retentionDays`, `quietPeriodMinutes`, `maxUploadBytes`) is **local-only**: like
`managerGateway`/`webAuth`, its API key is stripped before the config reaches a
browser and the whole block is writable only through the local-only
`logsync-get`/`logsync-set` RPCs (`RPCWebSocketHandler.localOnlyDenial`), so the
opt-in can never be flipped by a remote peer. See
[cli-reference.md](cli-reference.md#session-log-sync-commands).

## Per-workspace UI opt-in that reuses the gateway credential (CROW-1066)

The CLI-only opt-in above works but has friction: a user must drop to a terminal
(`crow logsync set --add-workspace …`) and, for a Corveil workspace, re-enter a
Corveil API key they already configured once as the workspace's **AI gateway**.
CROW-1066 adds a second opt-in surface — a **checkbox in Settings → Workspaces**,
"Upload session transcripts to Corveil" — that **reuses that workspace's gateway
credential** instead of asking for a second key.

- **Model.** A per-workspace `WorkspaceInfo.uploadSessionLogs: Bool` (default
  `false`), decode-tolerant and in `CodingKeys` like every other workspace field.
  Unlike `logSync.enabledWorkspaces` it rides on the workspace record, so the
  existing Settings → Workspaces form, the `set-config` round-trip and
  `crow workspace edit --upload-session-logs` all reach it with no new plumbing.
- **Opt-in is the union of both surfaces.** `LogSyncCollector` uploads a session
  when the local-only master switch `logSync.enabled` is on **and** the session's
  workspace either sets `uploadSessionLogs` **or** appears in
  `logSync.enabledWorkspaces`. The legacy CLI path is unchanged.
- **Credential reuse.** For a workspace opted in via the checkbox, the collector
  resolves the upload key from that workspace's `gateway` — the Corveil key it
  already holds — via the same `op://…` resolution the gateway launch path uses,
  falling back to the global `logSync.apiKeyRef` when the workspace has no
  reusable gateway credential.
- **UI.** The checkbox is **disabled with a tooltip** ("Configure a Corveil
  gateway first") when the workspace has no gateway — the reuse is the whole
  point, so the control is only meaningful with a gateway to reuse. The master
  switch / base URL / retention / quiet-period stay on the local-only `logSync`
  block.

### Three decisions resolved in CROW-1066

1. **Artifact base URL: the global, local-only `logSync.baseURL`.** The gateway
   `baseURL` is the *LLM proxy* endpoint (`ANTHROPIC_BASE_URL`), a different
   host/path from the REST artifact endpoint, so it is never used for the upload.
   We also deliberately do **not** derive the destination from the workspace's
   `corveilHost`: that field is **browser-flippable**, and letting a browser-set
   value choose where a *credential-bearing* upload goes would let an
   authenticated remote peer redirect the workspace's Corveil key to a host it
   chose (an exfiltration vector). The destination therefore stays the local-only
   `logSync.baseURL`; only the per-workspace on/off toggle is browser-flippable. A
   future need for per-workspace REST hosts would add a *local-only* override, not
   reuse a browser-writable field.
2. **Which gateway header carries the key.** Crow's established Corveil-gateway
   convention is the header **`x-citadel-api-key`** with a `Bearer sk-citadel-…`
   value (see [configuration.md](configuration.md#ai-gateway)). The collector
   looks the credential up case-insensitively, preferring `x-citadel-api-key` then
   `authorization` / `x-api-key` / `x-corveil-key` defensively, resolves an
   `op://…` value, and strips a leading `Bearer ` so `TranscriptUploader` can
   re-wrap the bare key as `Authorization: Bearer <key>` (double-prefixing would
   401).
3. **Security tradeoff: acceptable, bounded.** Making `uploadSessionLogs`
   browser-flippable relaxes the previously all-local-only posture, but narrowly:
   it only *reuses* a credential the workspace already holds (the gateway key,
   itself local-only — never readable or authorable from the web via
   `SettingsSecrets`), the destination stays local-operator-owned (decision 1),
   and the master `logSync.enabled` remains **local-only and the kill switch** —
   with it off, no workspace uploads regardless of any checkbox. So the only thing
   a remote peer gains is toggling one workspace's transcript upload on/off, to
   the operator's own Corveil, with a credential it can neither see nor change.

## Depends on

- The artifact contract + upload endpoint, [#2426](https://github.com/corveil/corveil/issues/2426)
  (`POST /api/crow-sessions/{sessionUID}/artifacts`).
- `docs/agent-harness-matrix.md`, ADR 0014 / 0015.
