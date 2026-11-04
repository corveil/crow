# 0030 — Codex routes through the workspace gateway, opt-in per gateway

- **Status:** Accepted
- **Date:** 2026-11-04
- **Deciders:** Danny Gershman

## Context

A workspace's AI gateway (CROW-402) reached only Claude Code, as
`ANTHROPIC_BASE_URL` / `ANTHROPIC_CUSTOM_HEADERS`. For a Codex launch Crow
deliberately *cleared* that block (#861 r17/r18), so a gateway credential never
reached another vendor's process. As a result, Codex sessions and Managers in a
gateway-configured workspace bypassed Corveil entirely: no request logs, no
spend tracking, no guardrails. `gateway_set: true` read as "covered" when it
wasn't (corveil/crow#1407, observed in corveil/corveil#5202).

Corveil already has the server half: `/v1/responses` is a transparent proxy for
Codex (corveil#1293). Codex keeps its own ChatGPT sign-in or OpenAI API key in
`Authorization`, and Corveil forwards it unchanged. The Corveil key travels
separately as `X-Corveil-Key`, and `X-Corveil-Upstream: chatgpt_codex |
openai_api` selects the upstream. The Claude shape doesn't work here. Putting the
Corveil key in `Authorization` (`OPENAI_API_KEY`) returns 401 (corveil#5022).

Two forces shape the decision:

1. **Subscription forwarding is undocumented by OpenAI.** Corveil's own docs ask
   for a per-org banner before customer deployments turn on `chatgpt_codex`.
2. **Codex's `resume --last` filters threads by `model_provider`.** Verified on
   codex-cli 0.147.0: with provider `corveil`, `codex exec resume --last` skipped
   a newer thread recorded under another provider. Turning routing on or off
   therefore changes which thread a worker's restart picks up.

## Decision

Crow routes Codex through the **same** `WorkspaceGateway` Claude uses (the
tagged workspace's gateway, else `managerGateway`, for a Manager). This happens
**only when that gateway opts in** through a new optional field,
`codexUpstream: auto | chatgpt_codex | openai_api`, set with
`crow gateway set … --codex-upstream`. Absent, which is the default and what
every existing gateway reads as, means Codex launches exactly as before.

A routed launch adds per-run `-c` overrides that define a Crow-owned model
provider, `crow-corveil`. It never edits `~/.codex/config.toml`:

- `base_url` is the gateway URL with `/v1` appended.
- `wire_api` is `responses`, and `requires_openai_auth` is `true`, so Codex keeps
  its own auth.
- `http_headers.X-Corveil-Upstream` is the chosen upstream. `auto` reads
  `auth_mode` from `$CODEX_HOME/auth.json`, and falls back to `chatgpt_codex`
  when it can't tell.
- `env_http_headers.X-Corveil-Key=CROW_CORVEIL_GATEWAY_KEY` names the env var
  that holds the gateway's `x-citadel-api-key`. The key itself is not in the
  overrides.
- A gateway with no Corveil key header (`x-citadel-api-key` / `X-Corveil-Key`) is
  not a Corveil gateway, so it never routes Codex.

**The key is never in argv, a stored command, or a file.** The overrides name
only the env var, so they are safe in a Manager terminal's persisted `command`
and in `setup.sh`'s `crow new-terminal --command`. The daemon types
`export CROW_CORVEIL_GATEWAY_KEY='…' && ` into the pane at the moment it pastes
the command. It does this at `launchAgent`, `pasteDeferredLaunch`,
`prepareTerminal` and `rehydrateTerminalSurface`, keyed on the override's
presence in the text. The key is shell state, the same way Claude's launch-line
prefix works.

## Consequences

- Codex in an opted-in workspace shows up in Corveil's request log under
  `/v1/responses` with the right upstream and user (verified live against
  corveil.io on 2026-11-04). It still does **not** appear in
  `sessions-list` or the Corveil graph, which build Codex work from uploaded
  transcripts and gateway sessions for `claude_code` only. That gap is tracked
  in corveil/corveil#5202.
- Codex isn't covered until someone opts in. That's deliberate (force 1), but it
  means `gateway_set: true` still doesn't imply Codex coverage on its own. Check
  `codex_upstream` in `crow gateway get`.
- **Restart continuity across the toggle.** Because `resume --last` is
  provider-filtered (force 2), a `.work`/`.job`/`.review` restart right after
  routing is turned on (or off) opens a fresh thread instead of the previous
  one. Resume by id, the Manager's path (ADR 0028), is unaffected: a thread
  resumes by id under a different provider.
- A key that can't be resolved (a failed `op read`) is exported empty. Codex
  then reaches Corveil without `X-Corveil-Key` and gets a 401, failing loudly
  rather than silently falling back to OpenAI direct, the same rule
  `GatewayResolver` follows.
- The bash `setup.sh` (`codex_gateway_overrides`) and Swift
  (`CodexGatewayArgs.configOverrides`) both build the override string, and must
  stay byte-identical. Tests on each side pin the same string.
- The opt-in is written only through the local-only gateway doors
  (`gateway-set`, `/config/*-gateway`), like the rest of the gateway. Every
  writer that rebuilds a gateway from base URL + headers carries the stored
  value forward, so an unrelated edit doesn't drop it.

## Alternatives considered

- **On by default for every gateway.** Rejected. It forwards ChatGPT
  subscription tokens without the org banner Corveil asks for, and it silently
  changes restart continuity for every running Codex session.
- **`openai_api` by default.** Rejected. Most Codex users sign in with ChatGPT,
  and a ChatGPT token sent to the OpenAI API upstream fails every request.
- **Write a `[model_providers]` block into `~/.codex/config.toml`.** Rejected.
  The file is the user's, and is shared by the desktop app and the IDE extension.
  It also forces a key-at-rest decision.
- **Reuse the provider id `corveil` / env var `CORVEIL_API_KEY`.** Rejected.
  Users who followed Corveil's Codex guide already have a `[model_providers.corveil]`
  table with the key inline, which `-c` would merge into. `CORVEIL_API_KEY` also
  overrides the `corveil` CLI's own profile inside the session.
- **Pass the key with `tmux new-window -e`.** Rejected: that is argv of a tmux
  client process, visible in `ps`.
- **A workspace (non-gateway) field.** Rejected. `crow workspace edit` is
  reachable from a remote `/rpc` peer, and turning on forwarding of the user's
  OAuth token belongs with the local-only credential.

## References

- Ticket: corveil/crow#1407
- Related ADRs: [0014](./0014-pluggable-coding-agent-adapter.md),
  [0015](./0015-harness-capability-tiers.md),
  [0020](./0020-first-class-corveil-integration.md),
  [0028](./0028-manager-resume-by-id.md)
- Code: `Packages/CrowCodex/Sources/CrowCodex/CodexGatewayArgs.swift`,
  `Packages/CrowEngine/Sources/CrowEngine/CodexGatewayLaunch.swift`,
  `Packages/CrowCore/Sources/CrowCore/Models/WorkspaceGateway.swift`,
  `skills/crow-workspace/setup.sh` (`codex_gateway_overrides`)
- Corveil: `marketing/docs-site/clients/codex-cli.md` (Passthrough mode)
