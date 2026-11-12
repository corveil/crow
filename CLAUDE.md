# Crow — repository guide

This is the source of Crow: the `crowd` daemon, the `crow` CLI, the web UI and the Tauri desktop shell. Crow manages AI coding sessions in git worktrees and drives them through a Manager agent. How to build, run and test it is in [`docs/development.md`](docs/development.md); contribution rules are in [`CONTRIBUTING.md`](CONTRIBUTING.md).

This file is for working **on** Crow. It is not the context Crow gives its own agents — see below.

## The Manager context is not this file

Crow scaffolds `{devRoot}/.claude/CLAUDE.md` on every launch, and every Crow session loads it on every turn, so it is kept small (CROW-1443, [ADR 0032](docs/adr/0032-slim-manager-context-on-demand-cli-reference.md)). Its sources, one set for dev builds and the app alike:

| Scaffolded to | Source |
|---|---|
| `{devRoot}/.claude/CLAUDE.md` | `Packages/CrowEngine/Sources/CrowEngine/Resources/ManagerContext/manager-context.md` (12KB cap, tested) |
| `{devRoot}/.claude/skills/crow-cli/SKILL.md` | `…/ManagerContext/crow-cli/SKILL.md` |
| `{devRoot}/.claude/skills/crow-cli/reference.md` | `…/ManagerContext/crow-cli/reference.md`, the per-verb CLI reference, read on demand |

The other bundled skills live in `skills/<name>/`, each with a twin in `Resources/<name>-SKILL.md.template` that release builds scaffold from (`make parity` checks the twins).

## Architecture Decision Records

Architectural decisions live in [`docs/adr/`](docs/adr/). Read [`docs/adr/README.md`](docs/adr/README.md) for the index, and copy [`docs/adr/template.md`](docs/adr/template.md) to start a new one. When superseding a decision, update the old ADR's `Status` field to `Superseded by NNNN` — don't delete it. The history is the point.

**Coding-agent harnesses:** Crow drives Claude Code, Cursor, Codex, OpenCode and others through the `CodingAgent` adapter. What each harness can (and can't) do — and why — lives in [`docs/agent-harness-matrix.md`](docs/agent-harness-matrix.md); the architecture is [ADR 0014](docs/adr/0014-pluggable-coding-agent-adapter.md) and the capability gaps are [ADR 0015](docs/adr/0015-harness-capability-tiers.md).

## Layout

- `Packages/`: the Swift packages. `CrowDaemon` is `crowd` (RPC server; web UI assets under `Sources/CrowDaemon/Resources/web`), `CrowCLI` is `crow`, `CrowEngine` is the headless session engine and the `Scaffolder`, and `CrowClaude`, `CrowCodex`, `CrowCursor` and the rest are the per-harness adapters.
- `crow-desktop/`: the Tauri shell that runs `crowd` as a sidecar ([ADR 0024](docs/adr/0024-tauri-sidecar-app.md)).
- `skills/` and `Resources/*.template`: the bundled skills scaffolded into `{devRoot}/.claude/skills/`.
- `docs/`: user and developer docs. `docs/cli.md` is generated (`make docs`); `docs/cli-reference.md` is the hand-written guide.

## Adding or changing a `crow` verb

[ADR 0016](docs/adr/0016-cli-control-plane-parity.md) lists every file a new verb touches. `CLIDocsTests` enforces the doc rows:

- `make docs` regenerates `docs/cli.md`.
- `docs/cli-reference.md` needs a worked example in a fenced block.
- `Packages/CrowEngine/Sources/CrowEngine/Resources/ManagerContext/crow-cli/reference.md` needs the verb in a fenced block. That is how agents learn it exists.
- Add a verb to `manager-context.md` only if nearly every session needs it. That file is capped at 12KB.

## Testing

Run one package at a time: `swift test --package-path Packages/<name>`. Tests must never touch live data ([ADR 0012](docs/adr/0012-tests-never-touch-live-data.md)). `make parity` runs the source-level drift gates that CI runs.

## Concurrency Safety

The `crow` CLI is safe for concurrent use. Multiple `crow` commands can run simultaneously without race conditions:

- **Socket Server**: Each CLI connection is dispatched to GCD's global concurrent queue. Multiple connections are accepted and processed in parallel.
- **State Mutations**: All RPC handlers use `await MainActor.run { ... }`, serializing all AppState mutations on the main thread. This prevents data races even when multiple CLI commands arrive simultaneously.
- **Persistence**: `JSONStore` serializes disk writes with `NSLock` and coalesces them by sequence — but **only within a single instance**. Its in-memory `_data` and `writeSeq` are instance state, and every `mutate` rewrites the whole `StoreData`. **All writers must therefore share the one injected `JSONStore`** (owned by `SessionService`). Constructing a throwaway `JSONStore().mutate { … }` reads its own (possibly stale) disk snapshot, and its full-store write can silently clobber a record another writer just added (#728).
- **Git Operations**: Each `setup.sh` creates its own worktree at a unique path, its own session (unique UUID), and its own terminal. There are no shared resources between parallel workspace setups.
