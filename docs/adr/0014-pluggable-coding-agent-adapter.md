# 0014 — Pluggable `CodingAgent` adapter

- **Status:** Accepted
- **Date:** 2026-07-23
- **Deciders:** @dgershman

## Context

Crow launches a coding agent into each session's terminal and observes it via
hook events. Phase A shipped exactly one agent — Claude Code — with its launch
flags, hook-config writer, and state machine hardwired into `SessionService`.
Adding Cursor, OpenAI Codex, and OpenCode ([#627](https://github.com/corveil/crow/issues/627)
and the harness follow-ups) meant those hardwired assumptions had to become an
abstraction, or every new harness would be another `switch agentKind { … }`
sprinkled across the engine.

The harnesses differ on nearly every axis — binary name, remote-control support,
hook transport, resume semantics, auto-permission, review support (see the
[capability matrix](../agent-harness-matrix.md)). We needed a contract that (a)
lets a harness declare its own capabilities as data the engine can branch on, (b)
lets a *downstream package* register a new harness without editing `CrowCore`,
and (c) makes a harness whose binary isn't installed simply absent rather than a
runtime error.

**Relationship to [ADR 0005](./0005-task-and-code-backend-protocols.md).**
0005 governs the **task/code provider** axis — `TaskBackend` / `CodeBackend` for
GitHub, GitLab, Jira, Corveil (*where the ticket and the PR live*). This ADR
governs the orthogonal **coding-agent** axis — `CodingAgent` for Claude Code,
Cursor, Codex, OpenCode (*which harness edits the code*). A session pairs one
harness with one or two providers; the two abstractions compose but do not
overlap. The 0005 file itself is `Accepted` (foundation #411, migration #454) —
its earlier `Proposed` status in the index was stale and is corrected alongside
this ADR. This ADR does **not** supersede 0005; they are parallel decisions on
different axes. `CodingAgent.generatePrompt` is the one seam where they meet: it
takes both `provider` and `codeProvider` so a Jira-task + GitHub-code session
routes the ticket fetch and the PR step to different CLIs (the 0005 cross-backend
case).

## Decision

Crow's harness contract is the
[`CodingAgent`](../../Packages/CrowCore/Sources/CrowCore/Agent/CodingAgent.swift)
protocol. Capabilities are **members of the protocol**, not a central switch:

- **Static capability members:** `supportsRemoteControl`, `launchCommandToken`,
  `displayName`, `iconSystemName`, `fallbackCandidates`.
- **Delegated collaborators:** `hookConfigWriter: any HookConfigWriter` and
  `stateSignalSource: any StateSignalSource` — each harness supplies its own hook
  transport and its own pure event→state machine.
- **Command builders:** `autoLaunchCommand`, `launchCommand`,
  `managerLaunchCommand`, `generatePrompt`, `sessionRenameSlashCommand` — each
  gets `autoPermissionMode` / `remoteControlEnabled` inputs it may honor or
  ignore.
- **Binary discovery:** `findBinary()` with a default three-tier impl
  (explicit `defaults.binaries.<kind>` override → `PATH` walk →
  hardcoded `fallbackCandidates`; CROW-484).

Harnesses are keyed by
[`AgentKind`](../../Packages/CrowCore/Sources/CrowCore/Agent/AgentKind.swift),
a `RawRepresentable` **struct** (not an enum) so a downstream package
(`CrowCursor`, `CrowCodex`, `CrowOpenCode`) can define a new kind without
modifying `CrowCore`.

[`AgentRegistry`](../../Packages/CrowCore/Sources/CrowCore/Agent/AgentRegistry.swift)
is the process-wide map from kind → agent. **The first kind registered becomes
the default.** At daemon boot, `CrowDaemon.registerAgents` registers
`ClaudeCodeAgent` unconditionally first, then Codex / Cursor / OpenCode **only if
`findBinary()` resolves**. So Claude Code is always present and always the
default; any other harness whose binary is off `PATH` is simply not in the map.

The engine never switches on harness identity. `SessionService.launchAgent`,
`handoffAgent`, and `buildReviewPrompt` look the agent up by kind and call
protocol members. The one accepted exception is a small **Claude-only prep
branch** (`if agent.kind == .claudeCode`) for trust seeding and AI-gateway env —
capabilities the protocol does not (yet) abstract because no other harness has an
analogue (see [ADR 0015](./0015-harness-capability-tiers.md)).

## Consequences

**Easier:**

- Adding a harness is a new package that conforms to `CodingAgent` plus one
  registration line in `CrowDaemon.registerAgents` — no engine surgery.
- Capabilities are declarative and testable per harness; the
  [matrix](../agent-harness-matrix.md) is generated from real property values,
  not aspirational.
- Handoff ([ADR 0011](./0011-agent-handoff-preserves-session-not-chat.md)) is a
  registry lookup + protocol calls; it inherited multi-harness support for free.

**Harder / accepted:**

- **A harness whose binary isn't on `PATH` is silently unavailable** in the
  picker and in `handoff-agent` (which fails `agentBinaryMissing`). This is
  intentional (no half-registered harness), but "why isn't Cursor in the list?"
  is answered by `findBinary()`, not an error message.
- The `Claude-only` prep branch is a real switch-on-identity the abstraction
  hasn't dissolved. It is documented and localized to two call sites, and is the
  candidate for a future `capabilities`-style member if a second harness grows a
  gateway/trust concept.
- `AgentKind` being an open struct means a typo'd raw value (`"claude_code"` vs
  `"claude-code"`) resolves to an unregistered kind rather than a compile error —
  the CLI validates the four known tokens to blunt this.

## Alternatives considered

- **Central `switch agentKind` in `SessionService`.** Rejected — reproduces the
  provider-switch anti-pattern 0005 dissolved on the task/code axis, and forces
  every harness's quirks into the engine.
- **`AgentKind` as an enum.** Rejected — a closed enum in `CrowCore` would force
  every new harness to modify the core module, breaking the "register from a
  downstream package" goal.
- **Supersede ADR 0005 with this one** (as the originating ticket floated).
  Rejected — 0005 is a different, still-valid decision on the provider axis; the
  two compose. The ticket's premise (that 0005 "predates and describes the
  CodingAgent design") conflated the two abstractions. The correct fix was to
  correct 0005's stale index status and record this as a parallel ADR.
- **Fail loudly when a harness binary is missing.** Rejected — a user who never
  installed Cursor should see a shorter picker, not an error; absence is the
  right signal.

## References

- Issue: [#827](https://github.com/corveil/crow/issues/827) (this doc);
  [#627](https://github.com/corveil/crow/issues/627) (handoff, first multi-harness driver)
- Related ADRs: [0005](./0005-task-and-code-backend-protocols.md) (orthogonal
  provider axis), [0011](./0011-agent-handoff-preserves-session-not-chat.md)
  (handoff), [0015](./0015-harness-capability-tiers.md) (capability tiers)
- Code:
  - `Packages/CrowCore/Sources/CrowCore/Agent/CodingAgent.swift`
  - `Packages/CrowCore/Sources/CrowCore/Agent/AgentKind.swift`
  - `Packages/CrowCore/Sources/CrowCore/Agent/AgentRegistry.swift`
  - `Packages/CrowCore/Sources/CrowCore/Agent/{HookConfigWriter,StateSignalSource,BinaryOverrides}.swift`
  - `Packages/CrowDaemon/Sources/CrowDaemon/CrowDaemon.swift` (`registerAgents`)
  - `Packages/Crow{Claude,Cursor,Codex,OpenCode}/`
- Reference: [Coding-agent harness capability matrix](../agent-harness-matrix.md)
