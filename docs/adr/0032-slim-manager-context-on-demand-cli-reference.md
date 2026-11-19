# 0032 — The Manager context is a slim core; the CLI reference loads on demand

- **Status:** Accepted
- **Date:** 2026-11-11
- **Deciders:** @dhilgaertner

## Context

Crow scaffolds `{devRoot}/.claude/CLAUDE.md` on every launch. Claude Code loads every `CLAUDE.md` from a session's working directory up to the filesystem root, and every Crow session runs under `{devRoot}`: Managers in `{devRoot}` or `{devRoot}/.crow/managers/<id>/`, work sessions in `{devRoot}/{workspace}/{dir}`, reviews in `{devRoot}/crow-reviews/{dir}`. So every session (Managers, work, review and job sessions) carries that file on every turn.

That file was the crow repo's own root `CLAUDE.md`, 64,148 bytes, and 52,421 bytes of it (82%) was the full `crow` CLI reference. It kept growing because [ADR 0016](./0016-cli-control-plane-parity.md) listed "The Manager's context: `CLAUDE.md`" as a place every new verb must be documented, and `CLIDocsTests.claudeMdDocumentsEveryUserFacingVerb` enforced it. A work session in some unrelated repo carried instructions for minting MCP tokens and choosing notification sounds that it would never use.

Gateway logs for 2026-11-04 to 2026-11-11 ([#1443](https://github.com/corveil/crow/issues/1443)) put the cost at roughly 45k tokens per session opener. A Manager's first request was 140–144k tokens before any work. At Opus 5.5 prices that came to about 7% of total usage (API-equivalent), and it brought long-running Managers to compaction sooner.

Two more problems came with using the repo-root file as the source:

- A session in a **crow** worktree loaded the reference twice: once from `{devRoot}/.claude/CLAUDE.md` and once from the worktree's own root `CLAUDE.md`, the same file.
- Dev builds read the repo-root `CLAUDE.md` (64KB), while the app read `Resources/CLAUDE.md.template` (26KB), a second, hand-trimmed copy. Only the first was tested for completeness.

## Decision

**The Manager context holds only what every session needs, capped at 12KB. The per-verb `crow` reference ships as the `crow-cli` skill, which agents read on demand.**

- The Manager context comes from `Packages/CrowEngine/Sources/CrowEngine/Resources/ManagerContext/manager-context.md`, a SwiftPM resource of CrowEngine, so dev builds and the app scaffold from the same file. It keeps the Manager naming rule, the sandbox requirement, the most-used verbs, Important Notes, the worktree rules, one line per bundled skill, the ticket/PR fetch and Bash conventions, and the operator's preserved `## Known Issues / Corrections` tail. It says in one line where to look for any other verb.
- The `crow-cli` skill (`…/ManagerContext/crow-cli/SKILL.md` and `reference.md`) is scaffolded to `{devRoot}/.claude/skills/crow-cli/`. Its description lists the command groups, so Claude Code knows when to load it. Agents without skills read `reference.md` directly, and `crow <verb> --help` stays the exact flag list.
- The crow repo's root `CLAUDE.md` is repo documentation again and is never scaffolded. `Resources/CLAUDE.md.template` is deleted.
- This replaces ADR 0016's "The Manager's context" row. The per-verb documentation requirement now targets the `crow-cli` reference, not always-loaded context. `CLIDocsTests` enforces it (`cliSkillReferenceDocumentsEveryUserFacingVerb`, same exemptions as before), caps the Manager context at 12KB (`managerContextStaysUnderSizeCap`), and checks that every verb the context names is real (`managerContextNamesOnlyRealVerbs`). `ScaffolderManagerContextTests` in CrowEngine checks that the resource actually loads from the bundle and that an upgrade keeps the operator's corrections.

## Consequences

**Easier.** Every session's opener drops by roughly 35–45k tokens, and every cache write and cache read with it. A new verb costs nothing in always-loaded context. Dev and the app can no longer disagree about what the Manager knows.

**Harder.** An agent that needs a rare verb now spends one tool call reading the skill's reference. That's the trade: one read when needed instead of 45k tokens on every turn. If the skill's description or the context's pointer stops working, agents may guess flags. The context tells them not to, and `--help` is always there.

**Live with.** The reference is now kept in three places: `docs/cli.md` (generated), `docs/cli-reference.md` (the long guide) and the `crow-cli` reference (the dense one agents read). That's the same three as before; this ADR only moved the third out of `CLAUDE.md`. The 12KB cap is a test, so growing the context past it takes a deliberate change to the cap.

## Alternatives considered

- **Point agents at `docs/cli-reference.md` directly.** It is in the crow repo, not on an installed user's disk, and at 144KB it is a long read for one verb.
- **Rely on `crow <verb> --help` alone.** It gives flags but not JSON shapes, gotchas or which verb to reach for, which is most of what the reference adds.
- **Keep the reference in `CLAUDE.md` and trim it.** It would grow back with the CLI, as it did after the last trim (`Resources/CLAUDE.md.template`).
- **Embed the context as a Swift string literal.** Same single source, but it is harder to edit and review than a Markdown file.

## References

- Ticket: [#1443](https://github.com/corveil/crow/issues/1443)
- Related ADRs: [0016](./0016-cli-control-plane-parity.md) (its Manager's-context row is replaced here), [0004](./0004-manager-auto-permission-mode.md)
- Code: `Packages/CrowEngine/Sources/CrowEngine/ManagerContext.swift`, `Packages/CrowEngine/Sources/CrowEngine/Scaffolder.swift`, `Packages/CrowCLI/Tests/CrowCLITests/CLIDocsTests.swift`
