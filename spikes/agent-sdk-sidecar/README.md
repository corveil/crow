# Agent SDK chat sidecar — THROWAWAY SPIKE

crow#1524, [ADR 0033](../../docs/adr/0033-agent-sdk-chat-typescript-sidecar.md). This directory is not product code: it is deleted, or moved and rewritten, when the ADR is decided.

`crowd` starts one `node sidecar.mjs` per Crow session whose Chat is switched to **SDK** and talks to it over stdio:

- **stdin** carries one JSON command per line:
  - `{"op":"message","text":…}`
  - `{"op":"respond","request_id":…,"behavior":"allow"|"deny","message"?,"answers"?}`
  - `{"op":"interrupt"}`
- **stdout** carries one JSON event per line, in Web Chat's vocabulary:
  - The kinds Chat already renders: `user`, `assistant`, `tool_call`, `tool_result`, `turn_end`, `notice`.
  - New for the spike: `ready`, `delta`, `permission`, `question`, `resolved`, `error`, `exit`, `command_error`.

`bridge.mjs` holds all the logic: SDK messages to events, `canUseTool` to `permission` / `question` and back. `sidecar.mjs` is the stdio entry point.

## Run it

Needs Node ≥ 18.14 and Claude Code on `PATH`. The sidecar runs the operator's own `claude`, not the SDK's bundled binary.

```bash
cd spikes/agent-sdk-sidecar
npm install --omit=optional        # skips the ~384 MB per-platform claude binary
npm test                           # bridge tests against a fake query(); no network

# A crowd from this branch (`make daemon` at the repo root) with the spike on.
# Run it *instead of* your usual crowd (quit Crow first): two crowds share the
# store, the tmux cockpit and the dev root's scaffolding.
CROW_AGENT_SDK_SPIKE="$PWD" ../../.build/debug/crowd
```

Then turn on Chat view (`crow ui set --chat-view true`), open a Claude work session, switch it to **Chat** once (that is when the browser asks `crowd` whether the spike is on), and pick **SDK** in the header's **Terminal | Chat | SDK** toggle.

Auth is whatever `claude` resolves. A workspace gateway reaches the SDK through the `env` block Crow writes into the worktree's `.claude/settings.local.json`. Per Anthropic's Agent SDK terms, a product built on the SDK must not offer claude.ai (Max/Pro) login without Anthropic's approval; see the ADR.

## Tests

- `npm test` runs `bridge.test.mjs` against a fake `query()`: streaming, approval, question, deny, interrupt and errors.
- `swift test --package-path Packages/CrowDaemon --filter AgentSDKSpike` runs `crowd`'s half (a fake launcher, plus `/bin/sh` standing in for node).
- `CROW_LIVE_AGENT_SDK=1 swift test --package-path Packages/CrowDaemon --filter AgentSDKSpike` also runs one real turn through this sidecar. It calls the model and costs a few cents.
- `node Packages/CrowDaemon/web-tests/chat-sdk.test.js` runs the web UI's SDK mode in jsdom.
