# /my-follow-ups

Corveil's Follow-up Ledger turns what people commit to in meetings ("I'll do that", "let's make a ticket for that") into `FollowUp` entities in the org's knowledge graph, each assigned to whoever owes it. `/my-follow-ups` works through your share of that list from a Crow Manager:

- It lists the open FollowUps assigned to you, with each one's title, quote, meeting date and the time it was said.
- It files a GitHub issue with `gh` for each one you pick, or [triages](#triage) it into a diagnosed ticket with [`/crow-diagnose`](../skills/crow-diagnose/SKILL.md) first.
- It checks each picked FollowUp off in Corveil (`status=done`, `ticket_url`) through the Corveil MCP tool `ontology_update_entity`.

Crow writes the skill to `{devRoot}/.claude/skills/my-follow-ups/SKILL.md`, next to `/crow-diagnose`, and overwrites it on every launch. The source is [`skills/my-follow-ups/SKILL.md`](../skills/my-follow-ups/SKILL.md).

- [Prerequisites](#prerequisites)
- [Replace a personal copy](#replace-a-personal-copy)
- [Use](#use)
- [How it works](#how-it-works)
- [Triage](#triage)
- [Check who closed one](#check-who-closed-one)
- [Reopen one checked off by mistake](#reopen-one-checked-off-by-mistake)

## Prerequisites

- **`corveil` CLI** (v0.5.14 or later), signed in to your org. Sign in with `corveil login`. `corveil whoami` should then show your org.
- **`gh`**, signed in, with permission to open issues in the repo you file into.
- **`jq`**.
- **The Corveil MCP server, connected to the Manager's agent with write access.** In Claude Code, connect it one of two ways:
  - Add the Corveil connector on claude.ai. It shows up in `claude mcp list` as `claude.ai Corveil`.
  - Run `claude mcp add --transport http corveil https://corveil.io/mcp`, then run `/mcp` in Claude Code and authenticate.

  Either way, the OAuth grant needs the `mcp.write` scope.
- **On the org:**
  - The Follow-up Ledger must be set up, so that Corveil records `FollowUp` entities with an `assignee` (a canonical Person name), a `status` (`open` or `done`) and the meeting's `quote`, `meeting_date` and `said_at`.
  - The `ontology_writes` flag must be on.
  - Your role must have the `ontology.write` capability.

The skill checks the CLI and the Ledger before it shows anything. If `corveil` isn't installed, or the org has no `FollowUp` entities, it says the Follow-up Ledger isn't set up and stops without filing anything. If you aren't signed in, it asks you to run `corveil login` and stops. A missing MCP tool or a refused write shows up at the first check-off (Triage looks for the tool before it starts), and the skill stops there and lists what it already filed.

## Replace a personal copy

Before Crow shipped it, `/my-follow-ups` was installed by hand as a Claude Code command. If you have one, delete it:

```bash
rm ~/.claude/commands/my-follow-ups.md
```

Otherwise Claude Code sees two definitions with the same name, and the personal copy doesn't get Crow's updates. Copies installed before Triage existed can only file.

## Use

Run it in a Crow Manager:

```
/my-follow-ups                     # list, then it asks which to file and where
/my-follow-ups owner/repo          # file into this repo
```

Asking for your follow-ups also runs it. Reply with:

- the numbers to file, `all`, or `none`;
- `done <numbers>` for commitments you've already met. Those are checked off without a ticket;
- `triage <numbers>` to have each one diagnosed before anything is filed (see [Triage](#triage)).

One reply can mix all three, for example `1 3 triage 2 4 done 5`.

### Permissions

The skill's frontmatter pre-approves the reads that build the list: `corveil whoami`, `corveil control identity users-get`, `corveil entity`, `corveil entities --type FollowUp` and `jq`. An `allowed-tools` grant lasts only for the turn that invokes the skill, so once you reply with your picks, the filing turn asks before each command as usual, including the two writes: `gh issue create` and `ontology_update_entity`.

To skip those prompts, add these to `permissions.allow` in your own `~/.claude/settings.json`: `"Bash(corveil entity *)"`, `"Bash(jq *)"`, `"Bash(gh issue list *)"`, `"Bash(gh issue create *)"`, and the MCP tool's name from `claude mcp list`, such as `"mcp__corveil__ontology_update_entity"`. Allowing `gh issue create` is safe here because the skill never puts meeting text into a shell command (see step 3 of [How it works](#how-it-works)).

## How it works

1. **Who am I.** `corveil whoami` gives the org and your user id. `corveil control identity users-get` gives your email, and `corveil entity Person <email>` turns that into your canonical Person name, which is the value FollowUps are assigned by. If any of that fails, the skill asks for your name once.
2. **One query.** `corveil entities --type FollowUp --limit 1000 --no-capture | jq …` keeps the items where `assignee` is you and `status` is `open`. MCP can't filter by property (corveil/corveil#5242), and `--no-capture` keeps the read from being recorded as an AI chat that can turn into ActionItems (corveil/corveil#5245). 1000 is the server's maximum page size. A larger `--limit` silently returns 20 rows (corveil/corveil#5265), so the skill pages with `--offset` when `total` is larger.
3. **File.** It runs `gh issue create` in the repo you name. The body carries the quote, the meeting date, the time it was said and the FollowUp id. One command builds the issue: `corveil entity <id> | jq` produces the title and body and pipes them straight into `gh`. Meeting text is untrusted, because anyone in the room said it. This way the agent never types it into a shell command, so a quote can't break out of shell quoting or a heredoc. Before filing, the skill looks for an issue that already carries the FollowUp id, so a rerun after a failed check-off reuses the issue instead of filing a second one. That check only searches the repo you name, so rerun with the same repo.
4. **Check off.** It sends this to `ontology_update_entity`:

   ```json
   {"entity_id": "<id>", "properties": {"status": "done", "ticket_url": "<url>"}, "reason": "Filed as <owner/repo#N> by <your canonical name>"}
   ```

   The tool merges properties, so `assignee`, `kind` and `quote` stay. Don't use `corveil control knowledge ontology-entities-update` for this: the REST PATCH behind it replaces the whole property set.

## Triage

**File** files a FollowUp as it stands: the issue body is the meeting quote, and no code is read. **Triage** diagnoses it first. Reply `triage <numbers>`, and for each item the skill runs [`/crow-diagnose`](../skills/crow-diagnose/SKILL.md) on the FollowUp's id. `/crow-diagnose` reads the meeting transcript around the quote, decides whether the item is engineering work, reads the code at `origin/main` in the repos it shortlists, and checks for duplicates. Each item ends in one of the outcomes of the [ticket standard](ticket-standard.md):

| Outcome | What happens to the FollowUp |
|---|---|
| **ticket** (one ticket, or an epic) | The ticket is filed with the `triaged` label, then the FollowUp is checked off with `status=done` and `ticket_url`. |
| **duplicate** | It stays open, and the skill shows the existing issue. `/crow-diagnose` sets `ticket_url` to that issue, and comments on it with your go if the meeting adds something. Check it off with `done <number>` once you agree the issue covers it. |
| **commitment** | It stays open, and the skill says why it isn't a code change. |
| **needs info** | It stays open, and the skill shows the question to ask whoever said it. |
| **won't do** | It stays open, and the skill cites what settles it. |

`/crow-diagnose` writes only the FollowUp's `ticket_url` and leaves `status` to `/my-follow-ups`. So the check-off is the same `ontology_update_entity` write that File makes, with the reason `Triaged with /crow-diagnose and filed as <owner/repo#N> by <your name>`.

Triage needs everything File needs, plus:

- **`/crow-diagnose`.** Crow installs it in the same Manager. Where it isn't installed, `/my-follow-ups` doesn't offer Triage, and says why if you ask for it.
- **A GitHub workspace in Crow that claims the repos the work could land in.** `/crow-diagnose` shortlists from the workspace's repos, so Triage ignores the `owner/repo` argument, which only tells File where to file. Its repo, duplicate and filing steps refuse a GitLab workspace.

How a run goes:

- **One session, one item at a time.** The items share the session, so the repo clones and code already read for one item serve the next. A run triages **at most 5** items: `triage all` takes the first five, and the skill names any picks it leaves for the next run.
- **Your `triage` reply isn't the go to file.** `/crow-diagnose` shows you each draft (the outcome, the repos and titles, and the bodies) and files only on your yes. The skill doesn't pass `--yes`, because when you type `triage 3` you haven't seen the outcome, the repo it picked, or whether it will comment on or close an existing issue. The draft also quotes the meeting verbatim, and `--yes` would skip the check that asks whether a quote can go into a public repo. Your yes to a draft covers the filing, the `ticket_url` write and the check-off.
- **Filed and `done` items go first,** then triage, because triage stops at each draft.
- **Items that already have a ticket.** If an item's `ticket_url` is a raw issue that File filed earlier, `/crow-diagnose` re-diagnoses it: it files a diagnosed ticket, comments on the raw issue and offers to close it (each with your go), and the FollowUp is checked off with the new ticket. If the ticket is already diagnosed, the item comes back as a duplicate and stays open.
- **The rules carry over.** Every Corveil read passes `--no-capture`. Triage hands `/crow-diagnose` the FollowUp's id, never its text. Every FollowUp write goes through `ontology_update_entity`, and only `status` and `ticket_url` change.
- **If a check-off fails after a ticket is filed,** the skill stops and lists what it filed. Once the write works, rerun `/my-follow-ups` with the ticket's repo and reply with the item's number (File). The reuse check finds the ticket by the FollowUp id in its Provenance footer, so nothing is filed twice.

## Check who closed one

```bash
corveil history <followup-id> --no-capture |
  jq '[.items[] | select(.source == "decision")][0].decision | {action, reason, actor, diff, created_at}'
```

The newest `decision` item is the check-off. `reason` says why and who (`Filed as owner/repo#N by <name>`), `diff` shows `status` going from `open` to `done` and `ticket_url` being added, and `actor.via` is `ontology_update_entity`.

`actor` itself names the MCP OAuth client (`mcp:corveil_…`), not you (corveil/corveil#5272). That's why the skill puts your name in `reason`.

## Reopen one checked off by mistake

The decisions log **can't** undo a check-off. Undo answers `undone` but restores no properties (corveil/corveil#5301). `ontology_update_entity` can set `status` back to `open`, but it can't remove `ticket_url`: `null` and `""` are silently dropped (corveil/corveil#5300). Until those are fixed:

1. Reopen with `ontology_update_entity` (`{"status": "open"}`, with a `reason`), so the history says why.
2. To drop `ticket_url` as well, snapshot the FollowUp, then send its **whole** property set without that key, guarded by `--if-match`:

   ```bash
   corveil entity <id> --no-capture > before.json
   corveil control knowledge ontology-entities-update <id> \
     --if-match "$(jq -r .updated_at before.json)" \
     --properties "$(jq -c '.properties | del(.ticket_url) | .status = "open"' before.json)" \
     --reason "<why>"
   ```

   This is the REST PATCH that replaces the whole property set, so build the set from a fresh read and check the result against `before.json`. Do this by hand. The skill itself never reopens a FollowUp.
