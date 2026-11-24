# Context size and compaction

Crow shows how much context each session's agent is carrying and whether its prompt cache has likely expired. It can also compact large idle sessions before their cache expires. Compaction is opt-in and off by default (CROW-1493).

## Why it matters

Two context costs dominate Crow's spend, and both come from sessions that sit in the sidebar and get picked up again later:

- **Cache rebuilds after idle.** Claude Code writes its prompt cache with a lifetime, one hour on Crow sessions. When a session is resumed after that, its whole context is written to the cache again at the cache-write price instead of being read at the cache-read price. On a session carrying 500k tokens, that rebuild is most of what the next message costs.
- **Long context.** Every request re-reads the whole context. A Manager or a long work session can carry close to a million tokens.

A week of Crow sessions measured in CROW-1493: cache rebuilds after idle were about 23% of spend, and 67% of spend went on requests carrying more than 200k tokens.

## Seeing it

`crow get-session` and `crow list-sessions` carry a `context` object on every session (`null` when Crow has no transcript to read it from):

```json
"context": {
  "tokens": 512004,
  "max_tokens": 1000000,
  "model": "claude-opus-5-5",
  "last_request_at": "2026-11-20T10:00:20Z",
  "idle_seconds": 4210,
  "cache_ttl_seconds": 3600,
  "cache_expired": true,
  "large": true,
  "compacted_at": null
}
```

| Field | Meaning |
| ----- | ------- |
| `tokens` | Prompt tokens of the latest model call in the main conversation (Claude: input + cache read + cache write). After a compaction with no call since, the size the compaction reported; `null` if it reported none |
| `max_tokens` | The context window, from the transcript (Codex) or the model (Claude); `null` when unknown |
| `model` | The model of that call |
| `last_request_at`, `idle_seconds` | When the cache was last refreshed by a call (or a compaction), and how long ago |
| `cache_ttl_seconds` | The cache lifetime the transcript records: Claude Code's `usage.cache_creation` says whether it wrote a 1-hour or a 5-minute entry. `null` when the tail shows neither, and always for Codex |
| `cache_expired` | Idle at least `cache_ttl_seconds`: the next message will likely re-write the whole context. `null` when either input is unknown. "Likely" because a call the transcript doesn't record can refresh the cache, which only ever makes it warmer than reported |
| `large` | `tokens` is at least `contextCompaction.minContextTokens` (default 200,000) |
| `compacted_at` | Set when the conversation was compacted and nothing has been sent since |

It is read from the transcript the agent already writes, with the same usage rules as the [Chat view](web-chat-view.md)'s context meter, and found by the conversation id Crow records from the agent's hooks (`agent_conversations`). Claude Code and Codex only. Until the agent's first hook reports an id, `context` is `null`: Crow doesn't guess at the newest transcript in the directory, which could be a sibling conversation's. A transcript is re-read only when its size or modification time changed since the last poll.

With [debug mode](configuration.md#telemetry-cleanup--ui) on (Settings → About, `crow ui set --debug-mode true`; off by default), the sidebar shows the same number on each session row: muted while small, amber once `large`. A large session whose cache has likely expired reads `512k · cold`, in the text and not only in the tooltip, because the web UI is often used from a phone. Hover (or a screen reader) gives the full numbers and how long the cache stays warm.

Crow shows token counts, not dollars. The repo has no price table to take prices from, and a wrong price shown in the UI is worse than none.

## Compacting before the cache expires

**Settings → Automation → Context compaction**, or `crow automation set --auto-compact true`.

Once a minute Crow looks at each Claude Code session. It types `/compact` into a session only when all of these hold:

- auto-compaction is on;
- the session is active, paused or in review (not completed or archived);
- its context is at least `minContextTokens` (default 200,000) and it hasn't been compacted since its last call;
- its last model call was at least `idleMinutes` ago (default 50);
- its cache is still warm: the lifetime is recorded, and more than a minute of it is left;
- Crow hasn't already compacted it for this same last call;
- `agent_state` is `idle`. Never `working`, `waiting_permission`, `starting` or `exited`. This is the same readiness `crow wait` and `crow send --wait-ready` use;
- the composer is visibly empty. Crow reads the pane with its colors and skips the session if the prompt holds anything that isn't dimmed or gray placeholder text, or if it can't find the prompt at all (a menu, a dialog, bash mode).

The compaction call reads the still-warm cache, which is cheap. The next time someone sends to the session, the cache it writes is the small, compacted context rather than the whole conversation. At 500k tokens on Opus 5.5 that is roughly $0.20 instead of about $4 per rebuild (the ticket's estimate).

At most two sessions are compacted per minute. Each send is logged to `crowd-automation.log` (`auto-compact: <name> … sent /compact`), and so is any session skipped for an unusual reason (a draft in the composer, an unknown cache lifetime). A compaction Crow requested is not counted against the session's efficiency grade (ADR 0008). An operator's own `/compact` still is.

### The trade-off: compaction loses detail

`/compact` replaces the conversation with a summary. Afterwards the agent no longer has the files it read, the exact output it saw, the reasoning behind a decision, or an instruction you gave early on, unless the summary kept them. It may re-read files, repeat work, or miss a constraint it was told about. That is the price of the saving, and it is why this is off by default.

Turn it on if your sessions are mostly long-lived Managers and work sessions that you come back to after an hour or more. Leave it off, or raise `minContextTokens`, if you rely on an agent remembering fine detail across a long session. To keep one session's context intact, finish with it first (complete or archive it), or leave text in its prompt.

### Settings

| Key | Default | Meaning |
| --- | ------- | ------- |
| `contextCompaction.autoCompact` | `false` | Turn compaction on |
| `contextCompaction.minContextTokens` | `200000` | Sessions at or above this size are compacted and shown as large (10,000–10,000,000) |
| `contextCompaction.idleMinutes` | `50` | Minutes since the last model call before compacting (1–1,440) |

With Claude Code's 1-hour cache, the default 50 minutes leaves ten minutes of margin. A session whose transcript records a 5-minute cache is only compacted if `idleMinutes` is under 5.

### Not covered

- Harnesses other than Claude Code. Codex has `/compact` too, but the transcript doesn't describe its caching, so "before it expires" can't be judged.
- Sessions whose agent hasn't reported a conversation id yet.
- Re-measuring the saving. CROW-1493's acceptance asks for a week of data after shipping, measured the same way as the original numbers.
