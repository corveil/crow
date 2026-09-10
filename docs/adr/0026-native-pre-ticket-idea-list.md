# 0026 — Native pre-ticket idea list (Scratch)

- **Status:** Accepted
- **Date:** 2026-09-10
- **Deciders:** @dhilgaertner

## Context

Crow had no home for an idea that is not a ticket yet. Capturing one meant leaving Crow for another tool; turning it into a Manager session took a handful of `crow` commands (`create-manager`, `rename-session`, `launch-agent`, `retry-readiness`, `list-terminals`, `send`, …) plus a wrong-default-agent detour. The existing `crow explore-issue` / `isExplore` flow explores a *ticket*; there was no sibling that explores an *idea* with no ticket, branch, or work session unless it earns one.

The list has to be self-contained (no external todo host), durable (explicitly not reaped by the 24h session cleanup), and written through the one injected `JSONStore` — a throwaway `JSONStore().mutate` would reintroduce the whole-file clobber that ate sessions in #728. MCP stays read-only per [ADR 0019](./0019-read-only-mcp-server.md): writes go through CLI and the web Scratch board.

## Decision

Crow persists a `todos[]` collection on `StoreData` (same `store.json` as sessions) and exposes it as `crow todo`, a Scratch sidebar board, and a `todos:read` MCP scope.

1. **Lifecycle.** `captured → exploring → ticketed → working → done`, with `parked` / `dropped` as no-ticket exits. `links[]` is the provenance trail (Manager session, filed ticket, PR).
2. **Promotions reuse existing verbs.** `todo explore` is `create-manager` + `crow send` of an explore brief (pre-ticket sibling of `/crow-workspace --explore`). `todo ticket` files via `TaskBackend.createTask`. `todo work` types `/crow-workspace` into the primary Manager. `todo talk` is sugar over `crow send` to the linked Manager.
3. **Non-reaped.** Session cleanup only deletes completed/archived *sessions*. `todos` is never cascaded on session delete and is never visited by the reaper.
4. **MCP.** `todo-list` / `todo-get` are ledgered `mcp: .read(scope: .todosRead)`. There is no `todos:write`.

## Consequences

An idea can be captured mid-work and explored without committing a ticket. Reopening a stale item shows its whole history, which an external tool cannot answer. The MCP catalog grows from six tools over five methods to eight over seven; ADR 0019's read-only / closed-allowlist rule is unchanged. v1 does not drag-reorder, due-date, remind, or sync the list to GitHub/Jira.

## Alternatives considered

- **External todo host (pndr, Notion, …).** The point of the ticket is that Crow owns the loop; a second auth and a context-switch are the problem, not the solution.
- **Session-shaped items that the reaper would wipe.** A parked idea must outlive the 24h session cleanup; stuffing ideas into `sessions[]` would fight that.
- **Writes over MCP.** Rejected by ADR 0019; the ledger gate still fails the build if a write is flagged for export.

## References

- Ticket: https://github.com/corveil/crow/issues/1231
- Related ADRs: [0019](./0019-read-only-mcp-server.md) (MCP read-only), [0016](./0016-cli-control-plane-parity.md), [0009](./0009-crowd-sole-authority-clients-only.md)
- Precedent: `crow explore-issue` / `Session.isExplore` (CROW-1149)
- Code: `Packages/CrowCore/Sources/CrowCore/Models/TodoItem.swift`, `Packages/CrowPersistence/Sources/CrowPersistence/Repositories/TodoRepository.swift`, `Packages/CrowCLI/Sources/CrowCLILib/Commands/TodoCommands.swift`, `Packages/CrowDaemon/Sources/CrowDaemon/TodoRPCHandlers.swift`
