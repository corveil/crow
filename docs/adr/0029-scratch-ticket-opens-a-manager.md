# 0029 — Scratch Ticket opens a Manager

- **Status:** Accepted
- **Date:** 2026-09-22
- **Deciders:** @dhilgaertner

## Context

Scratch Ticket (CROW-1259) filed a provider issue itself. The web button listed every workspace repo, asked the operator to pick one when there was more than one, and called `TaskBackend.createTask` with the scratch text as the title and "Filed from Crow Scratch." as the body. That is the wrong shape for a ticket: the repo choice and the wording are the work, and a one-line dump does not capture either.

Explore already had the right shape. It opens a Manager, seeds a brief, and lets the agent look at the code before anyone commits to a ticket. Ticket should be that path with a different brief, not a second, deterministic create.

This revises decision 2 of [ADR 0026](./0026-native-pre-ticket-idea-list.md). The rest of that ADR (the durable `todos` collection, the lifecycle, MCP staying read-only) is unchanged.

## Decision

`todo ticket` opens a Manager the same way `todo explore` does, and seeds a file-ticket brief. Crow does not choose a repo and does not call `TaskBackend.createTask`. The Scratch board has no repo dropdown, and the web-only `list-workspace-repos` RPC that fed it is removed.

The agent files the provider issue, then attaches it with `todo link --type ticket`. That link moves the item to `ticketed` unless the item is already `working` or `done`. An item that already has a ticket URL is refused, so Ticket cannot open a second filing session. Calling `todo ticket` again from inside the filing Manager is the wrong loop — the brief says so.

## Consequences

A filed ticket can name the right repo and say something a reviewer can act on. The cost is that filing is no longer instant or deterministic: it needs tmux and a Manager, and the ticket URL appears only after the agent links it. `crow todo ticket --workspace` / `--repo` are gone. An old client that still calls `list-workspace-repos` gets an unknown-method error.

## Alternatives considered

- **Keep `createTask` and only drop the modal.** A single-repo workspace would still file the scratch sentence as the title. The complaint is the deterministic issue, not only the picker.
- **Keep the picker, then open a session pre-seeded with that repo.** The operator is still choosing before anyone has looked at the code, which is the step the session is for.
- **A new session kind.** Explore is already a Manager plus a brief. A second kind would fork launch, resume, and the sidebar for a prompt difference.

## References

- Ticket: https://github.com/corveil/crow/issues/1289
- Related ADRs: [0026](./0026-native-pre-ticket-idea-list.md)
- Code: `Packages/CrowDaemon/Sources/CrowDaemon/TodoRPCHandlers.swift`, `Packages/CrowEngine/Sources/CrowEngine/TodoRPCSupport.swift`, `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/scratch-board.js`
