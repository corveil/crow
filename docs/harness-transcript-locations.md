# Harness transcript locations (CROW-1090)

Field reference: **where each coding-agent harness writes a durable session
transcript on disk**, and whether that transcript can be attributed to a Crow
worktree without opening every file. This is the input the session-log collector
([CROW-1056](https://github.com/corveil/crow/issues/1056),
[session-log-collector.md](session-log-collector.md)) and the historical backfill
([CROW-1075](https://github.com/corveil/crow/issues/1075),
[session-backfill.md](session-backfill.md)) need before a harness can be wired.

It exists so the verified locations captured while scoping
[CROW-1089](https://github.com/corveil/crow/issues/1089) outlive that issue and
land in front of whoever picks up the per-harness fan-out
(**[#1095](https://github.com/corveil/crow/issues/1095)** Cursor ·
**[#1096](https://github.com/corveil/crow/issues/1096)** OpenCode ·
**[#1097](https://github.com/corveil/crow/issues/1097)** Antigravity ·
**[#1098](https://github.com/corveil/crow/issues/1098)** Grok Build ·
**[#1099](https://github.com/corveil/crow/issues/1099)** Muse Code) — so nobody
re-discovers a path already found.

## The wiring test

The collector's `CodingAgent.logSources(worktreePath:harnessSessionID:)` hook
returns `[AgentLogSource]`; the protocol default is `[]`. A harness is **cheap to
wire iff a worktree path maps to its transcript files without reading every
file's contents** — anything less risks uploading a transcript attributed to the
wrong session, which is worse than uploading nothing (the reason the default is
opt-in). Two attribution modes exist today:

- **Path-partitioned** — the store's directory layout already encodes the working
  directory, so a worktree path resolves straight to its transcripts with a
  string transform. Claude Code is the reference (slug = worktree path, every
  non-alphanumeric → `-`). `cwdFilter` is `nil`.
- **Content-filtered** — the store pools transcripts globally, so the collector
  scans the tree and keeps only files whose *recorded* `cwd` equals the worktree
  (`AgentLogSource.cwdFilter` + `AgentLogCwdReader`). A file with no readable cwd
  is dropped, never guessed. Codex is the reference.

A store that is neither (no per-worktree layout **and** no recoverable cwd inside
each transcript) cannot be attributed and stays on the `[]` default.

## Reference table

Every harness Crow registers, plus the non-harness tools investigated under
CROW-1090. "cwd-attributable?" is the wiring test above.

| Harness / tool | Binary | Crow-launched? | Store path | Transcript file | Format | cwd-attributable? | Status · ticket |
|---|---|---|---|---|---|---|---|
| Claude Code | `claude` | ✅ | `~/.claude/projects/<slug>/` (slug = worktree path, non-alnum → `-`) | `<uuid>.jsonl` | NDJSON | ✅ path-partitioned | **Wired** (CROW-1089) |
| Codex | `codex` | ✅ | `~/.codex/sessions/<YYYY>/<MM>/<DD>/` | `rollout-<ts>-<uuid>.jsonl` | NDJSON | ✅ content-filtered (`session_meta.payload.cwd`) | **Wired** (CROW-1092) |
| Cursor | `cursor-agent` | ✅ | `~/.cursor/chats/<id>/<sub>/` | `store.db` (+ sibling `meta.json`) | SQLite (opaque blobs) | ✅ cwd in `meta.json` | Deferred — needs blob extractor · [#1095](https://github.com/corveil/crow/issues/1095) |
| OpenCode | `opencode` | ✅ | `~/.local/share/opencode/storage/{project,session,message,part}/` | scattered `message`/`part` records | multi-file object store | ✅ cwd in `project/<id>.json.worktree` | Deferred — needs reassembler · [#1096](https://github.com/corveil/crow/issues/1096) |
| Grok Build | `grok` | ✅ | `~/.grok/sessions/<urlencoded-abs-cwd>/<uuid>/` | `chat_history.jsonl` | NDJSON | ✅ path-partitioned (URL-encoded cwd) | **Lead found** — verify identity, then wire · [#1098](https://github.com/corveil/crow/issues/1098) |
| Antigravity | `agy` | ✅ | `~/.gemini/antigravity-cli/brain/<conv-id>/.system_generated/logs/` (pooled globally, keyed by id) | `transcript_full.jsonl` (`transcript.jsonl` is truncated) | NDJSON | ❌ no cwd in transcript (only off-transcript: per-conv SQLite DB / hooks / latest-only `cache/last_conversations.json`) | Deferred — durable log confirmed, **not** cwd-attributable · [#1097](https://github.com/corveil/crow/issues/1097) |
| Muse Code | `muse` | ✅ | unknown | — | — | ❓ unconfirmed | Research-first · [#1099](https://github.com/corveil/crow/issues/1099) |
| Cowork (Claude desktop, local-agent mode) | — (desktop app) | ❌ | `~/Library/Application Support/Claude/local-agent-mode-sessions/<acct>/<install>/local_<uuid>/` | `audit.jsonl` | NDJSON | ⚠️ cwd inside JSON, no path shortcut | Out of harness scope — see below |
| Grok Bot | — (Electron app) | ❌ | `~/Library/Application Support/Grok Bot/` | — (leveldb / server-side) | — | ❌ no durable local transcript | No collectable log — skip |

Wired-harness details live in
[session-log-collector.md](session-log-collector.md#harness-coverage); the rows
above summarize them for one-glance comparison. Cursor/OpenCode paths are from
their fan-out tickets ([#1095](https://github.com/corveil/crow/issues/1095) /
[#1096](https://github.com/corveil/crow/issues/1096)). The remaining rows are the
CROW-1090 field findings, detailed next.

## Field findings (CROW-1090)

Captured live on **2026-08-21** (macOS, a single dev machine — the URL-encoded
Grok paths were rooted at `/Users/danny/…`) and **re-verified 2026-08-24** on a
second machine. Drift from the re-verification is called out per entry.

### 1. Grok Build (`grok`) — path-partitioned, low-friction, wire first

- **Store:** `~/.grok/sessions/<url-encoded-absolute-cwd>/`
  - The directory name is the absolute worktree path URL-encoded — `/` → `%2F`
    (e.g. `%2FUsers%2Fdanny%2FProjects%2Fdevroot%2Fcorveil%2Fshell-crm-359-…`).
    This is a **different** encoding from Claude's `-` slug and from Codex's
    read-the-recorded-cwd, so wiring needs a small URL-encode path helper rather
    than reusing `AgentLogSource.posixPathSlug`.
  - `prompt_history.jsonl` at the cwd level.
  - `<session-uuid>/chat_history.jsonl` — the transcript. Verified 148 lines /
    382 KB; roles `tool_result` / `reasoning` / `assistant` / `user` / `system`;
    system prompt begins *"You are Grok 4.6 released by xAI…"*.
  - siblings: `events.jsonl`, `hunk_records.jsonl`, `prompt_context.json`.
  - global/index: `~/.grok/logs/unified.jsonl`, `~/.grok/sessions/session_search.sqlite`.
  - **62** `chat_history.jsonl` files across worktrees on the capture machine.
- **Attribution:** direct (path-partitioned). `logSources` would URL-encode the
  worktree path and point at `~/.grok/sessions/<enc>/*/chat_history.jsonl`.
  Already NDJSON → `AgentLogFormat.jsonl`, **no transform** — the single easiest
  non-Claude harness to add.
- ⚠️ **Identity caveat — confirm before wiring.** `~/.grok/` is grok-build's own
  config home (Crow already treats `~/.grok/bin/agent` and
  `~/.grok/trusted_folders.toml` as grok-build's — see
  [agent-harness-matrix.md](agent-harness-matrix.md)), so `~/.grok/sessions/` is
  almost certainly grok-build's store. But the `grok` binary **collides** with
  the community `superagent-ai/grok-cli`, which also installs `grok`
  (`GrokAgent.verifyBinaryIdentity`, CROW-911). #1098's spike must confirm the
  store is written by xAI's grok-build — not the community CLI — before wiring, so
  the collector never uploads a foreign tool's transcript under the `grok`
  harness.
- ⚠️ **Not re-verified on the second machine (2026-08-24):** grok-build is not
  installed there, so `~/.grok/` is absent. The layout above stands on the
  2026-08-21 capture only; #1098 re-confirms it live.
- **Adapter state:** `logSources` intentionally not overridden —
  `Packages/CrowGrok/Sources/CrowGrok/GrokAgent.swift` (the recorded note). This
  finding is the lead that retires that note once #1098 verifies it.

### 2. Cowork (Claude desktop app, local-agent mode) — real transcripts, ⚠️ not cwd-partitioned

- **Store:** `~/Library/Application Support/Claude/local-agent-mode-sessions/<accountId>/<installId>/`
  - `local_<uuid>.json` — session record (metadata; its `cwd` field points at the
    session's *own* `outputs` dir; the user's real project is in
    `userSelectedFolders`).
  - `local_<uuid>/audit.jsonl` — the durable transcript. Verified 134 events /
    201 KB on the capture machine; event types `system` / `assistant` / `user` /
    `result` / `command_lifecycle` / `rate_limit_event`; real message text.
  - `local_<uuid>/` also holds `.claude/`, `outputs/`, `uploads/`.
  - secondary: `~/Library/Application Support/Claude/claude-code-sessions/<accountId>/<installId>/local_<uuid>.json`.
- **Attribution:** ⚠️ **not** path-partitioned. Recovering the real project means
  reading each `local_<uuid>.json`'s `userSelectedFolders` and matching a
  worktree — there is no path-slug shortcut. The `audit.jsonl` format is
  Claude-Code-shaped NDJSON, so the normalizer is reusable; only discovery is
  harder.
- ✅ **Re-verified 2026-08-24** on the second machine: the store exists with
  **74** `local_*` entries (vs ~1,180 on the capture machine); the
  `<accountId>/<installId>/local_<uuid>/{audit.jsonl,.claude/,outputs/,.audit-key}`
  layout is exactly as documented.
- **Scope:** Cowork is **not a Crow-launched harness** — see
  [scope question](#scope-question).

### 3. Grok Bot (Electron desktop app) — ❌ nothing collectable locally

- **Store:** `~/Library/Application Support/Grok Bot/` — a Chromium/Electron
  profile (`Local Storage/leveldb`, `blob_storage`, `Cache`, `Code Cache`,
  `Cookies`, `Crashpad`, `Partitions/…`). The `sand-*` naming + statsig bootstrap
  indicate a sandboxed web wrapper around grok.com; conversations are
  **server-side**.
- `~/.grokbot/` holds only local-exec-daemon connection/credential state, not
  transcripts.
- **Attribution:** N/A — there is no durable local transcript. Leave on the `[]`
  default; do not point the collector here.
- ✅ **Re-verified 2026-08-24** on the second machine: the Electron profile is
  present with exactly the Chromium wrapper shape above, and `~/.grokbot/` carries
  only daemon connection/credential/log files — no transcript. (Credential files
  were not read.)

## Scope question

Two of the three field findings — **Cowork** and **Grok Bot** — are **not
harnesses Crow launches**. Wiring them would mean the collector uploads
transcripts from tools Crow does not drive. Before either is wired, decide the
collector's scope:

- **"Harnesses Crow launches"** (the current implicit scope) → Cowork and Grok
  Bot stay out; only the seven registered `CodingAgent`s are candidates.
- **"Any coding-agent transcript on the box"** → Cowork becomes wireable (its
  `audit.jsonl` is real and reusable), pending the harder `userSelectedFolders`
  discovery; Grok Bot remains impossible (no durable local log regardless).

This doc records the locations either way; the scope call is a product decision,
not blocked on discovery.

## Per-ticket disposition

- **[#1098](https://github.com/corveil/crow/issues/1098) (Grok Build)** — the
  `~/.grok/sessions/<urlenc-cwd>/<uuid>/chat_history.jsonl` lead above is the path
  its spike went looking for. Confirm binary identity (grok-build, not the
  colliding community `grok-cli`) and re-confirm the layout on a machine with
  grok-build installed, then wire it as a path-partitioned `.jsonl` source with a
  URL-encode path helper. No new normalizer needed.
- **[#1095](https://github.com/corveil/crow/issues/1095) (Cursor)** /
  **[#1096](https://github.com/corveil/crow/issues/1096) (OpenCode)** — storage
  already known (table above); these are "build the normalizer" tickets, not
  research.
- **[#1097](https://github.com/corveil/crow/issues/1097) (Antigravity)** —
  **resolved.** The `agy` CLI *does* write a durable NDJSON transcript at
  `~/.gemini/antigravity-cli/brain/<conv-id>/.system_generated/logs/transcript_full.jsonl`,
  but pooled globally by conversation id with **no cwd on any line** — so it is
  neither path-partitioned nor content-filterable, and stays on `[]`. The cwd
  lives only off-transcript (a conditional protobuf-in-SQLite per-conversation DB,
  the ephemeral hook / status-line payloads, or the latest-only
  `cache/last_conversations.json` pointer).
  Verified from Antigravity CLI docs + community tooling, not a live `agy` (not
  installed; Google-Sign-In/GCP-gated). Full rationale in `AntigravityAgent.logSources`.
- **[#1099](https://github.com/corveil/crow/issues/1099) (Muse Code)** — still
  genuinely unknown; CROW-1090 found no location. Research-first, as its ticket
  says.

## Caveats

- All paths verified on macOS (darwin). Re-confirm on other machines and after a
  Grok CLI / Cowork version bump before relying on the exact layout.
- On-disk **formats** are not guaranteed schema-stable across versions; the
  `AgentLogFormat.jsonl` normalizer should tolerate unknown event types.
- The second-machine re-verification (2026-08-24) could confirm Cowork and Grok
  Bot but **not** Grok Build (not installed there). The Grok Build layout rests on
  the 2026-08-21 capture until #1098 re-confirms it live.

## See also

- [session-log-collector.md](session-log-collector.md) — the live collector
  (CROW-1056) and its harness-coverage table.
- [session-backfill.md](session-backfill.md) — the historical backfill
  (CROW-1075).
- [agent-harness-matrix.md](agent-harness-matrix.md) — what each harness can do,
  and the `grok`/`agent`/`muse` binary-collision handling.
- ADR [0014](adr/0014-pluggable-coding-agent-adapter.md) (adapter architecture) ·
  [0015](adr/0015-harness-capability-tiers.md) (capability tiers).
