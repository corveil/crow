# 0031 — Observations are diagnosed in Crow before they become tickets

- **Status:** Accepted
- **Date:** 2026-11-09
- **Deciders:** @dhilgaertner, @dgershman

## Context

Engineering work often starts as an observation, not a ticket. Someone says something in a meeting, and Corveil's Follow-up Ledger records it as a FollowUp. Someone posts in a Slack thread, and Corveil's Slack sensor records it. Or someone pastes a note into Crow's Scratch list ([ADR 0026](./0026-native-pre-ticket-idea-list.md)). Turning these into tickets works badly today:

- **`/my-follow-ups` files the quote.** It pipes the FollowUp into `gh issue create`, so the issue body is the meeting quote, an assignee line and a FollowUp id. #1413 was filed this way. It names no repo, no cause and no way to tell when it is done.
- **The Scratch Ticket brief files one issue without investigating.** `ticketBrief(for:workspace:)` (`Packages/CrowEngine/Sources/CrowEngine/TodoRPCSupport.swift:334-367`, [ADR 0029](./0029-scratch-ticket-opens-a-manager.md)) asks for "what is wrong or wanted, where it lives, and how to tell it is done". It can't produce an epic, it doesn't check for duplicates, and it has no verification section.

The team discussed this in the 2026-11-06 meeting. The options were to have Corveil file tickets from its knowledge graph, to keep observations in the graph, to add a code-less triage repo, or to have a Crow session diagnose each observation. The meeting chose the last option. A ticket needs a diagnosis and verification steps, and those "could only be written by the agent that has the code in mind." Neither the observer nor Corveil has the code.

Every other stage of the pipeline already exists. Capture is the Follow-up Ledger, the Slack sensor and Scratch. Prioritising is `/crow-backlog-brief`, working is `/crow-cascade-epic`, and releasing is `/crow-release-review`. The diagnose step is missing (#1413).

## Decision

1. **Observations are captured raw and stay at their source.** A FollowUp stays in Corveil, a Slack thread stays in Slack, and a Scratch item stays in Scratch. Nobody rewrites one into a ticket at capture time. The source remains the record of what was said.
2. **A Crow session that has the code diagnoses each observation and files the ticket.** A Manager can read every repo in its workspace, so it can name the repos, cite `file:line`, check for duplicates and decide between one ticket and an epic. The session either files the ticket or reports an outcome that isn't a ticket.
3. **Corveil doesn't file engineering tickets itself.** It supplies the observation and its context: the transcript around it, who said it, when, and the related entities. It also records the ticket URL that comes back.
4. **Every diagnosed ticket meets [the ticket standard](../ticket-standard.md).** The standard defines the sections (Observation, Diagnosis, Shape, Acceptance and verification, Out of scope, Provenance) and the four outcomes that aren't tickets: commitment, duplicate, needs info and won't do.
5. **The links go both ways.** The ticket's Provenance footer names its source, and the source records the ticket (a FollowUp's `ticket_url`, or a Scratch item's ticket link).

**Why:** a ticket written by Corveil or by the observer is an eyewitness report. It says what someone saw, but it names no repo, no cause and no way to verify a fix. The engineer who picks it up has to do the diagnosis anyway, often without the context from the meeting or thread. Diagnosing first, while the observation and the code are both in view, makes the ticket useful to the coder, the reviewer and the release review.

## Consequences

- Tickets name their repos, cite code, state a confidence level and carry post-release checks. `/crow-cascade-epic` can read an epic's `Depends on` lines, and `/crow-release-review` can reuse the checks.
- A duplicate check happens before filing instead of after.
- An observation that isn't engineering work stops at the gate. A promise to send a deck doesn't become an issue.
- Each observation costs a full investigation by a session with repo access, which takes tokens and time. The gate keeps that cost off the observations that aren't engineering work.
- Filing needs a Crow session. Corveil can't file a ticket headlessly, so an observation waits until someone runs a diagnosis on it.
- The standard isn't enforced by code. `/crow-diagnose` (#1415) checks its own output against it, but a ticket filed by hand can still drift.
- Raw filing doesn't go away. `/my-follow-ups` keeps its **File** action (corveil/hackathon-2026#54). A raw ticket is a deliberate choice, and it is not a diagnosed ticket.

## Alternatives considered

- **Corveil files tickets from the graph.** Corveil has the observation and its context but no checkout, so it would have to guess the repo and couldn't cite code or write verification steps.
- **The observer writes the ticket.** The observer can describe the symptom, but not the cause or how to verify a fix.
- **Keep observations in the ontology only.** The Follow-up Ledger already does this for capture, but on its own it produces no work item a coder can pick up.
- **A code-less triage repo for untriaged items.** This was suggested in the meeting. It copies observations into a second inbox without diagnosing them. It isn't ruled out as a home for untriaged items, but it doesn't replace diagnosis.
- **A dedicated triage session kind.** A Manager can already read every repo in its workspace, so v1 needs no new kind. A triage lane on the board is deferred (#1417).

## References

- Ticket: https://github.com/corveil/crow/issues/1414 (this ADR and the standard)
- Epic: https://github.com/corveil/crow/issues/1413 (the triage pipeline). Builds on this: corveil/crow#1415 (`/crow-diagnose`), corveil/crow#1416 (Scratch Ticket runs `/crow-diagnose`), corveil/hackathon-2026#54 (`/my-follow-ups` Triage). Deferred: corveil/crow#1417 (a triage lane on the board)
- Standard: [`docs/ticket-standard.md`](../ticket-standard.md)
- Related ADRs: [0020](./0020-first-class-corveil-integration.md), [0026](./0026-native-pre-ticket-idea-list.md), [0029](./0029-scratch-ticket-opens-a-manager.md)
- Code and skills: `Packages/CrowEngine/Sources/CrowEngine/TodoRPCSupport.swift`, `skills/crow-create-ticket/SKILL.md`, `skills/crow-cascade-epic/SKILL.md`, `skills/crow-release-review/SKILL.md`
- Source: Corveil FollowUp `05d9dcd9-e6a3-4450-a3be-34665e204be7` · meeting `3e695928-34ef-49fd-8e12-2e442ef43058` (2026-11-06, 15:41–15:59)
