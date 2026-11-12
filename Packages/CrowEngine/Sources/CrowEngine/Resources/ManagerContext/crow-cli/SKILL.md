---
name: crow-cli
description: Look up a crow CLI verb's exact flags, JSON output and gotchas before running it. Use for any crow command not listed in the Manager context — sessions and lifecycle, links and tickets, terminals, worktrees, ticket board and reviews, jobs, Scratch todos, workspaces, agents, automation, defaults, settings (telemetry, cleanup, ui, terminal, version), notifications, skins, gateways and web password, Corveil CLI and connection, session-log sync, backfill, MCP tokens, TUI recordings, autostart, maintenance, analytics.
---

# crow CLI reference

The per-verb `crow` reference lives next to this file, in `reference.md`. It is loaded on demand so it does not cost every session's context.

## How to use it

1. Find the group you need. Each one is a `## <Group>` heading in `reference.md` (for example `## Notification Commands`, `## Workspace Commands`, `## Corveil connection`). Search for the verb itself (`crow notifications set`) or the heading, then read that section, not the whole file.
2. For a verb's exact flag list, run `crow <verb> --help` (for example `crow notifications set --help`). It is generated from the command itself, so it is always current.
3. Run the verb with `dangerouslyDisableSandbox: true`, like every `crow` command.

Never guess a flag or a value. If neither the reference nor `--help` shows it, the verb does not take it.

The same reference, with longer worked examples, is `docs/cli-reference.md` in corveil/crow; `docs/cli.md` there is the generated list of every verb and flag.
