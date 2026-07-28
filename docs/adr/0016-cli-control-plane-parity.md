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

The gate records today's honest state, and it is not flattering: all of
`workspaces[].*`, the automation toggles and `terminal.*` have no CLI path at
all, and `set-config`/`run-setup`/`batch-start-review`/`run-job` are writes with
no verb. Freezing that inventory in a file is what makes it shrinkable — and it
already works in both directions: rebasing onto CROW-810 turned the gate red
until the nine `defaults.*` rows were moved from exempt to covered, which is also
how the two fields that ticket left readable-but-not-writable
(`defaults.excludeDirs`, `defaults.mirrorClaudeMCPToCodex`) came to light.

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

- Ticket: [corveil/crow#807](https://github.com/corveil/crow/issues/807) — anti-drift parity test + CI gate
- Related ADRs: [0002](./0002-unix-socket-cli-architecture.md) (the CLI surface),
  [0007](./0007-linux-ci-swift.md) (why the RPC check is split),
  [0009](./0009-crowd-sole-authority-clients-only.md) (mutation flows through crowd),
  [0015](./0015-harness-capability-tiers.md) (*harness* parity — a different axis)
- Code: `Packages/CrowCore/Sources/CrowCore/Parity/ParityLedger.swift`,
  `Packages/CrowCLI/Tests/CrowCLITests/ParityGateTests.swift`,
  `Packages/CrowDaemon/Tests/CrowDaemonTests/RPCLedgerParityTests.swift`,
  `Packages/CrowIPC/Sources/CrowIPC/CommandRouter.swift` (`methodNames`),
  `scripts/check-cli-parity.sh`, `.github/workflows/ci.yml` (`parity` job)
