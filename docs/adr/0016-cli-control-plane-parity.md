# 0016 — Every user-mutable capability has a CLI path

- **Status:** Accepted
- **Date:** 2026-07-27
- **Deciders:** @dhilgaertner

## Context

Crow's control plane exists three times over:

1. the JSON-RPC methods `crowd` registers (`makeCommandRouter` + the `makeEngineRouter` it falls back to),
2. the `crow` verbs that call them (`CrowCommand.configuration.subcommands`),
3. the `AppConfig` fields both of them mutate.

Nothing in the compiler ties those together. [ADR 0009](./0009-crowd-sole-authority-clients-only.md)
established that all mutation flows through `crowd` RPCs and that new client
features are "RPC + render, never local engine" — but it said nothing about
*which* clients must be able to reach a given capability. In practice that meant
a feature could ship as an RPC method plus a web Settings control and quietly
never grow a CLI verb.

That asymmetry matters more for Crow than for a typical app, because the primary
operator of Crow is an agent. The Manager session drives Crow through the `crow`
CLI ([ADR 0002](./0002-unix-socket-cli-architecture.md)); a capability reachable
only from a browser is a capability no agent can use and no script can automate.
Drift here doesn't degrade convenience, it removes the product's main interface.

A CLI path is also the only **reproducible** one. A sequence of verbs can be
checked in, replayed on another machine, and diffed when it stops working; a
click-path through Settings can be described but never re-run. Headless
operation — a `crowd` on a host nobody points a browser at — rests on the same
property.

The drift was also invisible. Nobody could answer "what can the web UI do that
the CLI can't?" without reading three files and holding the result in their head,
so the gap grew without anyone deciding it should.

All three surfaces are enumerable at build time, so the question can be settled
mechanically rather than by review vigilance.

## Decision

**Every user-mutable capability in Crow has a CLI path, or a checked-in written
reason why it doesn't.**

The rule is enforced by `ParityLedger` (`Packages/CrowCore/Sources/CrowCore/Parity/ParityLedger.swift`),
a checked-in ledger naming every RPC method and every `AppConfig` leaf field and,
for each, either the `crow` verb that reaches it or a `Coverage.noCLI(reason:)`
exemption. The reason is a required associated value, so an exemption cannot be
added without writing one — **the ledger diff is the review surface**, and adding
a row is the moment a human decides the gap is acceptable.

Three checks keep the ledger honest, each placed where it can see the truth:

| Check | Where | Runs on PRs |
|---|---|---|
| Ledger ⇄ `crow` verb tree; ledger ⇄ `AppConfig` `Mirror` walk | `CrowCLITests/ParityGateTests` | yes (Linux lane) |
| Ledger ⇄ `CommandRouter.methodNames` (authoritative) | `CrowDaemonTests/RPCLedgerParityTests` | no — macOS only |
| Ledger ⇄ router source (text) | `scripts/check-cli-parity.sh` | yes (`parity` job) |

The split is forced: no single test target can see both sides. `CrowCLI` does not
depend on `CrowDaemon`, and `CrowDaemon` depends on the Darwin-only `CrowTelemetry`,
so it is absent from `ci.yml`'s `LINUX_PACKAGES` per [ADR 0007](./0007-linux-ci-swift.md).
The shell script is the PR-lane stand-in for the daemon test; the daemon test is
what catches a router refactor the script's regex would under-report.

Reads are ledgered too, but only **writes** are held to the parity bar. A missing
read verb is an inconvenience; a missing write verb is a capability an agent
cannot exercise.

### Definition of done for a CLI-covered feature

> **Amendment (2026-07-27, [#806](https://github.com/corveil/crow/issues/806)):**
> this ADR was first written under CROW-807, the ticket for the *gate*. The
> contract's own ticket also asked for the checklist below and for the
> divergence note under *Consequences*.

A green ledger row is necessary but **not sufficient**: it proves a verb exists,
not that anyone can discover it or that it behaves. A capability is CLI-covered
when this file set is touched. The shape is the `crow job` family (CROW-604,
[#624](https://github.com/corveil/crow/pull/624)), re-run by every parity PR
since — board verbs (#866), agents (#886), automation (#884):

| Layer | File(s) | Enforced by |
|---|---|---|
| Shared handler body | `Packages/CrowEngine/Sources/CrowEngine/*RPCSupport.swift` | — |
| RPC registration | `Packages/CrowDaemon/Sources/CrowDaemon/*RPCHandlers.swift` | `RPCLedgerParityTests`, `check-cli-parity.sh` |
| Local-only gate, when it carries secrets or host affordances | `RPCWebSocketHandler.swift` + `DaemonSecurityTests.swift` | — |
| The verb | `Packages/CrowCLI/Sources/CrowCLILib/Commands/*Commands.swift` | — |
| Verb registration | `CrowCommand.swift` `subcommands` | `ParityGateTests` |
| Argument validation | `Validation.swift`, `*Args.swift` | — |
| Ledger row | `ParityLedger.swift` | `ParityGateTests` |
| Tests | `*CommandParsingTests`, `*HandlerTests`, `*RPCSupportTests` | — |
| Generated reference | `docs/cli.md`, via `make docs` | `CLIDocsTests` |
| Worked example | `docs/cli-reference.md`, inside a fenced block | `CLIDocsTests` |
| The Manager's context | `CLAUDE.md`, and `Resources/CLAUDE.md.template` | `CLIDocsTests` (`CLAUDE.md` only) |
| Release note | `CHANGELOG.md` | — |

Half the rows are machine-checked; the other half are convention — and
convention is exactly what the jobs CLI proved fragile. `crow job` shipped and
then went missing from the reference, along with `set-locked`,
`recreate-terminal`, `resync-jira` and `codex-notify`, until CROW-808 built the
doc gate that now catches it. An unenforced row is a review item, not an
optional one.

## Consequences

**Easier.** "What can the UI do that the CLI can't?" is now a grep of the ledger's
exempt rows rather than an audit. Each per-area parity ticket has an unambiguous
definition of done: delete its rows from the exempt set. A new RPC method or
config field cannot ship without someone consciously deciding its CLI story,
because the build goes red until a row exists.

**Harder.** Adding a config field now costs a ledger row and a sentence of
justification. That friction is the point, but it is real, and it lands on
changes that may feel unrelated to the CLI. Nested `AppConfig` fields are
enumerated by `Mirror` over a hand-maintained fully-populated probe instance
(`parityProbeConfig()`); a new optional struct or collection must be populated
there too, or the walk cannot see through it. A dedicated test fails loudly when
it isn't, so this is a caught error rather than a silent gap.

**Lived with.** The ledger is production code in `CrowCore` — the only package
both the CLI and the daemon already depend on — so a few KB of governance data is
compiled into shipped binaries. Encoding it as Swift rather than JSON buys the
type-enforced exemption reason and removes a hand-written decoder that could
itself drift, which is worth more than the bytes.

The gate records today's honest state, and it is not flattering: `terminal.*` and
`jiraCredential.*` have no CLI path at all, and `set-config`/`run-setup`/
`batch-start-review`/`run-job` are writes with no verb. Freezing that inventory in
a file is what makes it shrinkable — and it already works in both directions:
rebasing onto CROW-810 turned the gate red until the nine `defaults.*` rows were
moved from exempt to covered, which is also how the two fields that ticket left
readable-but-not-writable (`defaults.excludeDirs`,
`defaults.mirrorClaudeMCPToCodex`) came to light. CROW-809 (#885) then did the
same for `workspaces[].*`, which this branch absorbed on a rebase — the exempt
list is one PR shorter than when this ADR was drafted.

The gate's own first miss is instructive (#806). CROW-812 (#884) and the gate
(#883) were in review at the same time and merged in that order, so the ledger
reached `main` with no rows for `automation-get`/`automation-set` and with all
eleven automation toggles still marked *"Web Settings toggle; no verb reads or
writes it"* — by then untrue. `main` sat red until this ADR's own branch
reconciled it. **Two PRs that are each individually correct can still land a red
gate**, so the `parity` job has to be watched on `main`, not only on the PR that
last touched the ledger.

**A covered row does not mean one implementation** (#806).
[ADR 0009](./0009-crowd-sole-authority-clients-only.md) retired `forwardToApp`,
but the shape it left behind survived: the daemon's `makeCommandRouter` and the
`makeEngineRouter` it falls back to both registered **29 of the same method
names** — `new-session`, `set-status`, `delete-session`, `get-config` and 25
more. The daemon's copy always answered; the engine's was shadowed, reachable
only if the daemon's was removed. `CommandRouter.methodNames` *unions* the two,
so the ledger saw a single row where two bodies of code existed, and no check
could tell them apart.

Those bodies had already drifted. `get-config` reported `app_running: false`
from the daemon (`SnapshotRPCHandlers.swift`) and `true` from the engine copy,
and the daemon's copy returned three keys the engine's omitted (`configured`,
`default_dev_root`, `vs_code_available`) — one method name, two response
contracts. `delete-session` refused without tmux in the daemon copy and had no
such guard in the engine's.

CROW-1174 is the de-duplication this ADR named. It split `makeEngineRouter`
into per-concern `Engine*RPCHandlers.swift` files (assembler in
`EngineRouter.swift`) and **deleted** every engine registration whose method
name the daemon already owned. A name now exists in at most one of the daemon
`*RPCHandlers.swift` files or the engine handler files — the ledger still sees
one row, but there is only one body. The remaining engine-only verbs
(`hook-event`, `send`, `get-session`, `list-worktrees`, …) still live behind
`fallback: makeEngineRouter(ctx)` until a later ticket unifies them into the
daemon maps. `scripts/check-cli-parity.sh` globs both
`Packages/CrowDaemon/Sources/CrowDaemon/*RPCHandlers.swift` and
`Packages/CrowEngine/Sources/CrowEngine/*RPCHandlers.swift` (plus the
assemblers).

Parity work must still respect the older lesson: **a verb wired against a
shadowed copy is a no-op**. The newer verb families already demonstrated
single-body registration — `job-*`, `defaults-*`, `agents-*`,
`notifications-*` and `telemetry-*` share one body under
`Packages/CrowEngine/Sources/CrowEngine/*RPCSupport.swift` and never grew a
second.

## Alternatives considered

**A JSON or YAML ledger at the repo root.** Closer to the literal ticket wording
and trivial for the shell script to read with `jq`, but the Swift tests would need
`#filePath` walk-ups to locate it and a hand-written `Codable` schema that is
itself a drift risk — a decoder that can rot inside the drift detector.

**Naming/prefix heuristics instead of a ledger** (`get-`/`list-` is a read, everything
else needs a verb). No file to maintain, but it silently waves through a future
write named `get-something`, and it cannot express *why* a gap is acceptable —
which is the part that makes the gate a decision rather than a nag.

**One test target depending on both sides.** Cleanest assertion, but `CrowCLI`
would have to depend on `CrowDaemon` and thus on Darwin-only `CrowTelemetry`,
dropping the entire CLI package out of the Linux PR lane — trading a broad, fast
gate for a narrow one that only runs on release tags.

**Documentation and review discipline.** This is the status quo that produced the
drift; `docs/agent-harness-matrix.md` shows the pattern works when a table is
maintained, but only because something else forces the update.

## References

- Ticket: [corveil/crow#806](https://github.com/corveil/crow/issues/806) — the
  parity contract itself (this ADR's brief; the milestone's foundation ticket),
  [corveil/crow#807](https://github.com/corveil/crow/issues/807) — anti-drift
  parity test + CI gate (the mechanism, written first)
- Related ADRs: [0002](./0002-unix-socket-cli-architecture.md) (the CLI surface),
  [0007](./0007-linux-ci-swift.md) (why the RPC check is split),
  [0009](./0009-crowd-sole-authority-clients-only.md) (mutation flows through
  crowd — and the retired `forwardToApp` whose residue is the 29 duplicated
  handlers under *Consequences*),
  [0015](./0015-harness-capability-tiers.md) (*harness* parity — a different axis)
- Code: `Packages/CrowCore/Sources/CrowCore/Parity/ParityLedger.swift`,
  `Packages/CrowCLI/Tests/CrowCLITests/ParityGateTests.swift`,
  `Packages/CrowDaemon/Tests/CrowDaemonTests/RPCLedgerParityTests.swift`,
  `Packages/CrowIPC/Sources/CrowIPC/CommandRouter.swift` (`methodNames`),
  `scripts/check-cli-parity.sh`, `.github/workflows/ci.yml` (`parity` job)
