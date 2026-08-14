# MCP

Crow serves a **read-only** MCP surface, so clients that speak the Model Context
Protocol — Cowork, a Grok bot, Claude Desktop — can read the board without a
Crow-launched agent session.

> **Scope.** This page is about `crowd` *serving* MCP. It is a different axis from
> Crow *provisioning* MCP servers into coding agents, which Crow deliberately does
> not do — the user configures `mcpServers` in `~/.claude.json` and Crow only
> mirrors it into other harnesses (CROW-528, [configuration.md](configuration.md)).
> See [ADR 0019](adr/0019-read-only-mcp-server.md) for why the two coexist.

## What it can and cannot do

**Read-only, and structurally so.** The tool catalog is a closed allowlist of six
tools over five read RPC methods. There is no passthrough tool and no way to name an
RPC method from the wire, so the local-only surfaces — gateways, the web password,
MCP tokens themselves, `run-setup`, hook events, host-app launches, the Corveil CLI
verify/reinstall actions — are unreachable regardless of transport or scope.

There is **no prompt-send**: nothing here can type into an agent's terminal, create
a session, change a status, or write config. That is deliberate and enforced by a
build gate (`MCPLedgerExportTests`), not by convention.

## Transports

| Transport | How | Credential | For |
| --- | --- | --- | --- |
| stdio | `crow mcp serve` | none | a client on the machine running `crowd` |
| HTTP | `POST /mcp` | `Authorization: Bearer crow_mcp_…` | an off-box client |

The split is the trust model. A caller who can run `crow mcp serve` can already run
every other `crow` verb against the 0600 Unix socket, so a token there would gate
nothing. A caller arriving over HTTP has proven nothing, so it presents a scoped,
expiring token.

## Scopes

| Scope | Grants |
| --- | --- |
| `sessions:read` | `get_board_summary`, `list_sessions`, `get_session`, `list_stuck_sessions` |
| `board:read` | `list_tickets`, `list_reviews` |

There is no `sessions:write`, no `prompt:send`, and no `admin` — not "not yet
implemented" but *not defined*, so a token cannot name a capability the server might
later grow into.

`tools/list` is **filtered by the presented token**, not merely enforced at call
time: a `board:read` token never sees that the session tools exist. A
deny-after-call would still teach the model that they do.

## Tools

| Tool | Scope | Answers |
| --- | --- | --- |
| `get_board_summary` | `sessions:read` | Counts by status, with the session names under each |
| `list_sessions` | `sessions:read` | Sessions, filterable by status and kind |
| `get_session` | `sessions:read` | One session in full, by UUID |
| `list_stuck_sessions` | `sessions:read` | What needs a human, and why |
| `list_tickets` | `board:read` | The ticket board (issue bodies omitted) |
| `list_reviews` | `board:read` | The reviews board, by group |

`list_stuck_sessions` is the one worth knowing about. It joins two payloads that are
disjoint on their own — `list-sessions` carries the agent's activity and pending
attention, `list-sessions-live` carries PR checks and the auto-merge / auto-rebase
watcher verdicts — and reports each reason with its underlying message:

`waiting_on_input` · `idle_too_long` · `checks_failing` · `auto_merge_stuck` ·
`auto_rebase_stuck`

`list_tickets` drops the issue `body`, the only unbounded field in that payload; one
long issue would otherwise crowd the rest of the board out of the model's context.
Open the row's `url` for the full text.

## Local client (stdio)

Point any MCP client at the `crow` binary:

```json
{
  "mcpServers": {
    "crow": {
      "command": "crow",
      "args": ["mcp", "serve"]
    }
  }
}
```

Narrow it if the client only needs one half:

```json
{ "command": "crow", "args": ["mcp", "serve", "--scope", "board:read"] }
```

`crowd` must be running — `crow mcp serve` is a bridge to it, not a second copy of
the engine. If the daemon is down, tool calls come back as `isError` results saying
so rather than dropping the connection.

## Remote client (HTTP)

Mint a token on the machine running `crowd` — minting is local-only, so this cannot
be done from a remote browser or over `/rpc`:

```bash
crow mcp token mint --name grok-bot --scope board:read
```

```json
{
  "saved": true,
  "token": "crow_mcp_kJ8x…",
  "warning": "This token is shown once and cannot be recovered.",
  "record": { "id": "…", "name": "grok-bot", "prefix": "kJ8x…", "expires_at": "…" }
}
```

Copy it now. Only a SHA-256 hash is stored, so there is no `--reveal` to come back
to; a lost token is replaced, not recovered.

Then point the client at the endpoint:

```json
{
  "mcpServers": {
    "crow": {
      "url": "https://crow.example.ts.net/mcp",
      "headers": { "Authorization": "Bearer crow_mcp_kJ8x…" }
    }
  }
}
```

Or by hand:

```bash
curl -s https://crow.example.ts.net/mcp \
  -H 'Authorization: Bearer crow_mcp_kJ8x…' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

**Expose it the same way you expose the web UI**: bind `crowd` to loopback and put
an HTTPS proxy (Tailscale serve, ngrok) in front. `/mcp` does not require the web
password — a bearer token replaces it — but it does not create a way in that the
proxy has not already permitted.

Tokens are listed and revoked from either side:

```bash
crow mcp token list
crow mcp token revoke --name grok-bot
```

Settings → Web access has the same controls, local browser only.

## Protocol support

Crow is **dual-era**: it answers both the current stateless revision and the older
handshake, on one endpoint, deciding per request.

| Revision | How a request identifies itself | Supported |
| --- | --- | --- |
| `2026-07-28` | `_meta["io.modelcontextprotocol/protocolVersion"]` + `MCP-Protocol-Version` header | yes — including the mandatory `server/discover` |
| `2025-11-25`, `2025-06-18`, `2025-03-26` | an `initialize` handshake | yes |

That matters because `2026-07-28` removed the `initialize` handshake, protocol-level
sessions, and the GET stream only recently, and most shipping clients still open with
the handshake. A client needs to know nothing about this.

HTTP specifics, for anyone debugging with `curl`:

| Situation | Response |
| --- | --- |
| No or bad token | `401` + `WWW-Authenticate: Bearer` |
| Invalid `Origin` | `403` |
| `GET` / `DELETE /mcp` | `405` — this revision has no GET stream or sessions |
| Unknown method | `404` + JSON-RPC `-32601` |
| Unsupported protocol version | `400` + `-32022`, carrying the `supported` list |
| Header disagrees with body | `400` + `-32020` |
| Notification (no `id`) | `202`, no body |

## See also

- [ADR 0019](adr/0019-read-only-mcp-server.md) — why the surface is task-shaped
  rather than one tool per RPC, and how it relates to CROW-528
- [ADR 0016](adr/0016-cli-control-plane-parity.md) — the ledger that gates which
  RPCs may be exported
- [cli-reference.md](cli-reference.md#mcp-commands) — the `crow mcp` verbs
