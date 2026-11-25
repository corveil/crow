# 0033 — Crow chat on the Claude Agent SDK runs in a TypeScript sidecar that crowd supervises

- **Status:** Proposed (spike behind `CROW_AGENT_SDK_SPIKE`, off by default)
- **Date:** 2026-11-25
- **Deciders:** @dhilgaertner

## Context

Web Chat ([`docs/web-chat-view.md`](../web-chat-view.md)) is a second view of a terminal agent. `crowd` tails the harness's transcript file every 2 seconds and sends by pasting into the agent's tmux pane. That works, but Crow controls none of the loop:

- **Approvals never reach Chat.** Permission prompts aren't in the transcript, so the operator switches back to the terminal to answer one. Danny on the Nov 18 check-in: "The only time I switch back is like when it prompts to like do something because those don't come through in transcripts."
- **Questions are answered by typing keys.** The question card (crow#1512) answers Claude's `AskUserQuestion` by pressing digits in the TUI picker and checking the pane after each one, and falls back to a plain message when the picker looks different.
- **Nothing streams.** A reply appears when the transcript line is written, up to 2 seconds later, all at once.
- **The UI can only render what the transcript says.** The Nov 18 discussion wanted interactive components in Chat (the CIQ merge queue as a list with buttons, micro-confirmations). A view that reads a file can't send a click back into the turn.

[T3 Code](https://github.com/pingdotgg/t3code) does all four. It drives Claude through the **Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`): its server calls `query()` with a streaming-input prompt and answers approvals and questions through the SDK's `canUseTool` callback. Dustin, Nov 25: "T3 code is like right there… the power you get with the agent SDK of being able to draw your own user interface… brings you to the next level."

The constraint is the one Danny named the same day: `crowd` is Swift, and the Agent SDK ships for TypeScript and Python only. Dustin's answer was to build it "in parallel as a flag". This ADR picks the architecture, and the spike (crow#1524) runs one session's chat turn through it.

Two facts about the SDK shape every option below:

1. **The SDK is a client of the Claude Code CLI.** It spawns `claude` as a subprocess and speaks a stream-JSON control protocol to it ([hosting docs](https://code.claude.com/docs/en/agent-sdk/hosting): "The Agent SDK spawns and supervises a `claude` CLI subprocess"). Tools, skills, hooks, CLAUDE.md, compaction, permission rules and the transcript file are the CLI's, not the SDK's. The TypeScript SDK 0.3.332 pins Claude Code 2.1.332.
2. **The SDK loads the same settings the terminal does.** With `settingSources` omitted (or set to `user`, `project`, `local`), `query()` loads the same user, project and local settings, CLAUDE.md files and `.claude/` skills, agents and commands as the CLI ([docs](https://code.claude.com/docs/en/agent-sdk/claude-code-features)). The system prompt is the exception: the SDK uses a minimal prompt unless you pass `systemPrompt: {type: 'preset', preset: 'claude_code'}`.

## Options

- **(a) TypeScript sidecar.** A Node process per session (or per daemon) running `@anthropic-ai/claude-agent-sdk`. `crowd` starts it, writes commands to its stdin, and reads events from its stdout.
- **(b) Python sidecar.** The same shape with `claude-agent-sdk` for Python.
- **(c) Port the chat backend into `crowd` (Swift).** There is no Swift SDK, so this means one of:
  - **(c1)** Run the agent loop on the Messages API from Swift and rebuild Claude Code's harness: tools, permissions, skills, hooks, compaction and CLAUDE.md loading.
  - **(c2)** Run `claude -p` as a subprocess from Swift with stream-JSON input and output, doing what the SDK does without Node. This is a documented route: the Agent SDK overview says "To drive the same agent loop from a language other than Python or TypeScript, run the CLI as a subprocess with the `-p` flag and `--output-format json`", and the [headless docs](https://code.claude.com/docs/en/headless) document streaming (`--output-format stream-json --include-partial-messages`), `--resume`, and approvals through a `--permission-prompt-tool` MCP tool or `PermissionRequest` hooks. What is **not** published is the stdin control channel the SDKs use to answer `canUseTool` (including `AskUserQuestion`'s `updatedInput.answers`), interrupt a turn and change the model.

## Comparison

| Criterion | (a) TS sidecar | (b) Python sidecar | (c1) Messages API in Swift | (c2) CLI protocol from Swift |
|---|---|---|---|---|
| **Packaging on macOS** | Needs Node ≥ 18.14. The SDK is 5.2 MB; with `--omit=optional` the spike's `node_modules` is 63 MB. Skipping the optional per-platform `claude` binary (384 MB unpacked for darwin-arm64) and passing the operator's `claude` as `pathToClaudeCodeExecutable` is what T3 Code does too. To avoid a Node dependency, ship a Node SEA or `bun build --compile` binary. | Needs Python ≥ 3.10, or a bundled interpreter. The macOS arm64 wheel bundles a 166 MB `claude`; the sdist plus `cli_path` avoids it. | Nothing new to ship. | Nothing new to ship. |
| **Signing / notarization** | Plain `.mjs` files are resources and need nothing. A compiled Node binary must be signed and notarized in `release.yml` ([ADR 0021](./0021-signed-notarized-macos-releases.md)) with the hardened-runtime JIT entitlements V8 needs. T3 Code already signs and notarizes its Node SEA CLI. | Every `.so`/`.dylib` in a bundled interpreter must be signed. This is the hardest of the four to notarize. | Unchanged. | Unchanged. |
| **Corveil gateway routing** | Works. The SDK runs the same CLI, which reads `ANTHROPIC_BASE_URL` / `ANTHROPIC_CUSTOM_HEADERS` from its environment or from the `env` block Crow writes into `.claude/settings.local.json` (loaded through the `local` setting source). **Verified:** with the gateway variables only in a `settings.local.json` (none in the process env), a full SDK turn went through the gateway. With a wrong key in that file, the gateway answered `401 Invalid API key` rather than the CLI falling back to the operator's login. | Same as (a). | Crow would add the gateway URL and headers itself, the way the CLI does today. | Same as (a). |
| **Transcript and session-log compatibility** | Same file. The SDK session wrote `~/.claude/projects/<cwd>/<id>.jsonl` in the CLI's format, with entries tagged `entrypoint: "sdk-ts"`. `ChatTranscript`, `HarnessTranscriptLocator`, log sync and `claude --resume <id>` all apply. SDK sessions are left out of `claude --continue` and the session picker ([docs](https://code.claude.com/docs/en/agent-sdk/sessions)). | Same as (a). | **Breaks.** No Claude Code JSONL, so log sync, handoff ([ADR 0011](./0011-agent-handoff-preserves-session-not-chat.md)), resume-by-id ([ADR 0028](./0028-manager-resume-by-id.md)) and the existing Chat reader would all need a new source. | Same as (a). |
| **Manager sessions and skills** | Same as the terminal: the `claude_code` preset plus `user`/`project`/`local` sources give the same CLAUDE.md, skills, slash commands, hooks and permission rules. Crow's own hooks are the catch: see "Hooks would repoint the session" below. Manager auto mode ([ADR 0004](./0004-manager-auto-permission-mode.md)) is `permissionMode: 'auto'`; resume-by-id is `resume`. | Same as (a). | Each one is rebuilt by hand. | Same as (a), if the protocol holds. |
| **Max/Pro subscription auth** | Technically works: the operator's `claude` uses whatever login it has (T3 Code reuses `claude auth login`). See terms. | Same as (a). | Not possible: the Messages API takes API keys and gateway credentials. | Same as (a). |
| **Anthropic terms** | "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK. Use the API key authentication methods described in the Quickstart instead." ([Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)). Crow would be such a product: API keys, Bedrock, Vertex, Foundry or the Corveil gateway are fine, and claude.ai login is not without approval. The same page puts SDK use under Anthropic's Commercial Terms and sets branding rules (a product may say "Powered by Claude" but must not call itself "Claude Code"). | Same as (a). | API terms only. | Same policy: `claude -p` is "the Agent SDK via the CLI" in Anthropic's docs. |
| **Protocol stability** | Public, versioned SDK API. | Public, versioned SDK API. The Python SDK is on its own version line (0.2.x, vs 0.3.x for TypeScript). | The Messages API is stable, but the harness is ours to maintain forever. Mixed. Stream-JSON output, partial messages, `--resume` and `--permission-prompt-tool` are documented. The stdin control channel (answers to `canUseTool`, interrupt, model changes) is not; it is the SDKs' contract with the CLI. Whether a permission-prompt tool can return `AskUserQuestion` answers is untested. |
| **Reference implementation** | T3 Code's `ClaudeAdapterV2.ts`, which can be read for parts. | None in our orbit. | None. | The SDK's own minified client. |

## Decision

Crow's Agent SDK chat runs in a **TypeScript sidecar that `crowd` supervises**, one per session that uses it:

- **Transport.** `crowd` starts `node sidecar.mjs --cwd <worktree> [--claude <path>] [--resume <id>]` and speaks NDJSON over stdio. Commands go to stdin: `message`, `respond` (an approval or answer) and `interrupt`. Events come back on stdout.
- **The sidecar owns the SDK.** It translates SDK messages into Web Chat's existing event vocabulary (`user`, `assistant`, `tool_call`, `tool_result`, `turn_end`, `notice`), plus four new kinds: `delta` (streamed text), `permission`, `question` and `resolved`. `crowd` never parses an SDK message type, so SDK churn stays in one JavaScript file.
- **`crowd` owns Crow's side.** It owns session identity, the event log, the push to browsers (an `sdk-chat-event` notification over the existing `/rpc` WebSocket, the same path as `tui-record-event`) and input validation (it forwards only answers to requests still waiting).
- **The operator's own `claude`.** The sidecar runs it through `pathToClaudeCodeExecutable` and installs the SDK with `--omit=optional`, the way T3 Code does. Crow already requires `claude` for Claude sessions, and this drops the 384 MB binary.
- **Parity with the terminal agent, minus hooks.** The sidecar passes `systemPrompt: {type: 'preset', preset: 'claude_code'}` and `settingSources: ['user', 'project', 'local']`, and turns hooks off for the SDK child with `settings: {disableAllHooks: true}` (the flag-settings tier, the CLI's `--settings`). See the hooks finding below.
- **Approvals and questions go through `canUseTool`.** A tool approval returns `{behavior: 'allow' | 'deny'}`. `AskUserQuestion` arrives through the same callback and is answered with `updatedInput.answers`, keyed by question text, with labels as values (several labels joined with ", ").
- **API-key-class auth only.** That means API keys, Bedrock, Vertex, Foundry or the Corveil gateway, never claude.ai login, unless Anthropic approves it in writing.

Python (b) loses on packaging and has no reference implementation. (c1) gives up the transcript, and with it every feature built on it. (c2) is the one to watch, and it is closer than "unpublished" suggests. Streaming, resume and a documented approval route (`--permission-prompt-tool`, an MCP tool `crowd` would host) exist for `claude -p`, and it needs nothing new in the bundle. What (a) buys over it is the SDK's public API for the parts that are not documented on the CLI: answering `AskUserQuestion` as data, `interrupt()`, `setModel()`, `streamInput()` and `getContextUsage()`, plus T3 Code's code to borrow from. Revisit if Anthropic documents the CLI's control channel, ships a Swift SDK, or if a spike shows a permission-prompt tool can answer questions.

The decision stays **Proposed** until the follow-up epic below ships a supported version. Until then the code is a spike.

## The spike

Files: [`spikes/agent-sdk-sidecar/`](../../spikes/agent-sdk-sidecar/) (sidecar, bridge and tests), [`AgentSDKSpike.swift`](../../Packages/CrowDaemon/Sources/CrowDaemon/AgentSDKSpike.swift) and [`AgentSDKSpikeRPCHandlers.swift`](../../Packages/CrowDaemon/Sources/CrowDaemon/AgentSDKSpikeRPCHandlers.swift) in `crowd`, and [`chat-sdk.js`](../../Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/chat-sdk.js) in the web UI.

- **The flag.** `crowd` reads `CROW_AGENT_SDK_SPIKE=<sidecar dir>` at startup. It is an environment variable, not a config field: there is nothing to migrate when the spike is deleted, and nothing a user can switch on by accident. With it unset, `get-sdk-chat-events` answers `{enabled: false}`, `sdk-chat-input` refuses, and the web UI shows no SDK option.
- **The UI.** With the flag on (and Chat view on), the session header's toggle reads **Terminal | Chat | SDK**. SDK mode reuses Chat's log, composer and renderers, with this behavior:
  - Text streams into a live bubble.
  - Tool calls and results render like the transcript's.
  - Approvals get an **Allow / Deny** card.
  - `AskUserQuestion` gets the question card, answered through the SDK rather than by keystrokes.
  - The status line offers **Interrupt** and **End**.
  - A new message after End or a sidecar exit resumes the same SDK session (`--resume`). End takes effect at once: `crowd` drops anything the old sidecar still prints, nothing it asked stays answerable, and its cards close. Request ids are unique per sidecar, so an answer can only reach the request its card was drawn for.
  - Sidecars of sessions that are deleted, completed or archived are stopped within 30 seconds, and all of them when `crowd` shuts down.
- **Alongside the terminal.** SDK mode is a separate Claude conversation in the session's worktree. The terminal agent keeps running, and with hooks off the SDK turn doesn't touch the session's state in Crow: not its conversation pointer, status or notifications. One thing is shared: the SDK writes its transcript into the same `~/.claude/projects/<cwd>/` folder. A Claude session with no recorded conversation id yet has its Chat view fall back to the newest transcript in that folder, which can be the SDK's. It runs in Claude work, Manager and job sessions; not in review sessions (a review clone's `.claude/` is the PR author's) and not for other harnesses. The browser offers SDK mode only in sessions where it runs.

What it showed:

- **One turn, end to end.** A real turn ran `crowd`'s `AgentSDKSpike` → `node` sidecar → Agent SDK 0.3.332 → Claude Code 2.1.332 → the Corveil gateway → Claude Opus 5.5. It streamed text deltas, asked an `AskUserQuestion` and requested a `Write` approval. Both were answered through `respond`, the command the cards send, by test code rather than a browser click. It then wrote the file and ended. The model-side turn took 4.1 s; the opt-in test (`CROW_LIVE_AGENT_SDK=1`), sidecar startup included, took 9.4 s. The browser cards themselves are covered by a jsdom test.
- **First-turn cost.** The SDK reported $0.29 for that first turn. The SDK runs the same CLI, so prompt size and caching should match a terminal session's first turn; crow#1499 and crow#1501 apply unchanged.
- **The default permission mode must be set.** If `permissionMode` is omitted, the SDK takes `permissions.defaultMode` from settings, else `auto`. This operator's user settings say `auto`, which approves most calls without asking. The spike sets `'default'`; the real design picks the mode per session, the way the terminal launch does.
- **Hooks would repoint the session (found in review).** Loading `local` settings also loads Crow's hooks from `.claude/settings.local.json`, which carry the Crow session id. `hook-event` records the payload's conversation id as the session's `harnessConversationID`, latest wins, and persists it. One SDK turn would therefore have repointed the session's regular Chat view, a cold-start Manager relaunch ([ADR 0028](./0028-manager-resume-by-id.md)) and handoff at the SDK conversation, with the pointer flapping as both agents fired hooks. The spike passes `settings: {disableAllHooks: true}`. **Verified:** a hook in a temp `settings.local.json` ran without that setting and did not run with it, and the turn still went through the gateway the same file names. The cost is that the user's and the project's own hooks don't run in SDK mode either; managed-policy hooks still do. When the SDK *is* the session's only agent (the epic), Crow's hooks are exactly what it should run.
- **No new protocol work for questions.** The question card's draft and validation logic is reused as is. Only the delivery changes, from keystrokes into a picker to a typed callback.

## T3 Code comparison

Read from a local checkout of T3 Code at `680152e27b` (its server's `ClaudeAdapterV2.ts`, `packages/contracts`, `apps/web`).

| T3 Code does better today | How | SDK path unlocks it for Crow? |
|---|---|---|
| Approvals in the UI: Approve / Decline / "Always allow this session" | `canUseTool` returns `updatedPermissions` for "always" | **Yes.** The spike does Allow / Deny; "always" is `updatedPermissions` |
| Questions answered as data, with multi-select, custom answers and dismiss | `canUseTool` → `updatedInput.answers` | **Yes.** In the spike |
| Live output | Thinking deltas, plus assistant text in whole markdown blocks at most every 400 ms; a live context meter from `message_start` usage | **Yes.** The spike streams text deltas; `getContextUsage()` would feed a meter |
| Interrupt, steer mid-turn, queued messages | `interrupt()`, `streamInput()` | **Yes.** Interrupt is in the spike |
| Model and effort picker per thread, changeable live | `setModel()`, flag settings | **Yes** |
| Plan mode with a proposed-plan card | `permissionMode: 'plan'`, `ExitPlanMode` intercepted in `canUseTool` | **Yes** |
| Typed tool rendering (edit diffs, command output, todo list, subagent threads) | Turn items built from SDK messages | **Mostly.** The data is in `tool_use` inputs either way, but live and structured needs the SDK |
| Image attachments sent as image blocks | SDK user content blocks | **Yes.** Today Crow uploads the file and pastes its path |
| Custom interactive components in the conversation | Its own UI over typed events | **Yes.** That is the point: a component's click can become a turn input |
| Checkpoints, diff and revert | Git refs `refs/t3/checkpoints` | Separate work (git; the SDK has `rewindFiles()`) |
| Mobile app, remote access through a relay | Expo app; Tailscale, SSH, T3 Connect | No. Not SDK work; Crow is web-first over Tailscale already |

Where Crow is ahead and stays ahead: a worktree per task, the Manager agent, PR, CI and review automation, the boards, the Corveil integration, and every other harness (Codex, Cursor, OpenCode, Grok, …) through the terminal ([ADR 0014](./0014-pluggable-coding-agent-adapter.md)). The SDK path is Claude-only and doesn't replace any of that.

T3 Code keeps its own SQLite event store as the source of truth and uses Claude's JSONL only for resume, rollback and fork. The spike keeps events in memory. The epic below keeps the JSONL transcript as the durable record, which is what log sync and handoff already read.

## Consequences

- **Easier.** Approvals, questions, streaming, interrupts, plan mode and custom components all become data in a turn, not keystrokes into a TUI. The question card's fallback-to-message path disappears for SDK sessions.
- **Harder.** Crow takes on a second runtime (Node) and a second agent process per SDK session. Version pairs to watch: the SDK pins a Claude Code version, and the operator's `claude` may differ, so the epic needs a compatibility check. Hooks, `harnessConversationID`, the Chat transcript fallback and handoff were designed for one terminal agent per session. Two agents in one session can't both own them, which is why the spike runs with hooks off and the epic makes the SDK the session's only agent.
- **Terms.** Max/Pro subscription users can't use the SDK path as shipped. It needs an API key, a cloud provider or the Corveil gateway. Ask Anthropic before relaxing that.
- **The terminal path doesn't move.** Other harnesses, and Claude sessions without the SDK, keep working exactly as today. Replacing it is out of scope.

## Alternatives considered

- **(b) Python sidecar.** Same capability as (a). It costs more to package and notarize, its version line differs from the TypeScript SDK's, and there is no reference implementation to borrow from.
- **(c1) Messages API in Swift.** Rebuilds Claude Code and loses the transcript format that log sync, handoff, resume and Chat depend on.
- **(c2) `claude -p` with stream-JSON from Swift.** No Node to ship, transcripts preserved, and streaming plus a permission-prompt route are documented. Not chosen because answering questions, interrupting and changing models would rest on the CLI's unpublished control channel, and there is no reference implementation. Revisit as described under Decision.
- **A new daemon instead of a sidecar.** Dustin's "a completely new crowd D service". The sidecar is that service at the smallest size that works. It runs only while a session uses it, and `crowd` stays the sole authority ([ADR 0009](./0009-crowd-sole-authority-clients-only.md)).
- **Keep improving the terminal path.** It can't get approvals out of a TUI, and every new interaction is another keystroke driver like crow#1512's.

## Recommendation and follow-up epic

**Go**, behind a flag, on the terms above. Draft epic (not filed):

> **Epic: Claude sessions on the Agent SDK (opt-in per session)**
>
> Goal: a Claude session can run on the Agent SDK instead of a tmux terminal, with Web Chat as its UI. The terminal path stays the default and the only path for other harnesses. Builds on ADR 0033 and replaces the crow#1524 spike.
>
> 1. **Ship the sidecar.** Move `spikes/agent-sdk-sidecar` to a supported location. Choose "Node required" or a signed `bun --compile` / Node SEA binary in `release.yml`. Pin the SDK, check the operator's `claude` version against it, and report the result in Settings → About.
> 2. **SDK as a session launch mode.** A `claude-sdk` launch choice in `new-session` / `crow-workspace`. One conversation per session: the SDK replaces the tmux agent for that session, and Crow's hooks run again (the spike turns them off because two agents shared one session). `harnessConversationID` is the SDK session id, so resume ([ADR 0028](./0028-manager-resume-by-id.md)) and handoff ([ADR 0011](./0011-agent-handoff-preserves-session-not-chat.md)) work, and "Open in terminal" runs `claude --resume <id>` in a tmux window when the sidecar is idle.
> 3. **Durable history.** Read history from the JSONL transcript (`ChatTranscript`) and stream live events from the sidecar, replacing the spike's in-memory log. Survive a `crowd` restart by resuming.
> 4. **Permissions.** A per-session permission mode (default, acceptEdits, plan, auto; Manager auto per [ADR 0004](./0004-manager-auto-permission-mode.md)). "Always allow" through `updatedPermissions`. Notifications for a waiting approval.
> 5. **Rendering.** Edit and Write diffs, Bash output, the TodoWrite list, a plan-mode card, subagent threads, images in the composer, a context meter from `getContextUsage()`.
> 6. **Control.** Interrupt, steer and queue; a live model and effort picker.
> 7. **Custom components.** A typed channel for Crow components in the conversation, such as the CIQ queue with actions, whose clicks become turn input.
> 8. **Auth, gateway and branding.** Default to the workspace gateway or an API key; the `settings.local.json` route is verified, and passing the resolved env explicitly would drop the dependence on `local` settings. Show `apiKeySource`. Get Anthropic's answer before allowing claude.ai login. Follow the SDK branding rules in UI labels.
> 9. **CLI and MCP parity** ([ADR 0016](./0016-cli-control-plane-parity.md)). `crow` verbs to send to, approve in and answer an SDK session, so a Manager can drive one.
> 10. **Delete the spike.** Remove `CROW_AGENT_SDK_SPIKE`, `get-sdk-chat-events` / `sdk-chat-input` and `chat-sdk.js`, or fold them into the above. Move this ADR to Accepted.

## References

- Ticket: crow#1524. Related: crow#1512 (question card), crow#1499 and crow#1501 (cache cost), [ADR 0014](./0014-pluggable-coding-agent-adapter.md) and [ADR 0015](./0015-harness-capability-tiers.md) (harness parity), [ADR 0024](./0024-tauri-sidecar-app.md) (how `crowd` itself ships).
- Agent SDK docs: [overview and auth policy](https://code.claude.com/docs/en/agent-sdk/overview), [TypeScript reference](https://code.claude.com/docs/en/agent-sdk/typescript), [handling approvals and user input](https://code.claude.com/docs/en/agent-sdk/user-input), [permissions](https://code.claude.com/docs/en/agent-sdk/permissions), [sessions](https://code.claude.com/docs/en/agent-sdk/sessions), [Claude Code features](https://code.claude.com/docs/en/agent-sdk/claude-code-features), [hosting](https://code.claude.com/docs/en/agent-sdk/hosting).
- Corveil: the Nov 18 check-in (Chat view, T3 Code, components in chat) and the Nov 25 debrief (`c7100c34`, Python-sidecar question, "in parallel as a flag").
- Code: `spikes/agent-sdk-sidecar/{sidecar,bridge}.mjs`, `Packages/CrowDaemon/Sources/CrowDaemon/AgentSDKSpike*.swift`, `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/chat-sdk.js`.
