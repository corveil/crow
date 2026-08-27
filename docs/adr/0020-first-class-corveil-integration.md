# 0020 — Corveil is a first-class integration, not a manual gateway

- **Status:** Accepted
- **Date:** 2026-08-27
- **Deciders:** @dhilgaertner

## Context

Crow can route a session's `claude` launches through an AI gateway — a base URL plus
`ANTHROPIC_CUSTOM_HEADERS`, injected per workspace ([configuration.md](../configuration.md#ai-gateway),
[ADR 0005 pairing]). For **Corveil**, that gateway carried a hand-entered
`x-citadel-api-key` header holding a `sk-citadel-…` key.

That manual wiring worked but pushed real cost onto the operator:

- **Key sprawl.** Every workspace needed its own pasted key. Nothing tied a key to a
  Corveil org, nothing rotated it, and a leaked or rotated key had to be re-pasted
  everywhere it appeared.
- **No provenance.** Crow couldn't tell which org a key belonged to, whether it was
  still valid, or revoke it on disconnect — the key was an opaque string.
- **Log shipping was a second, parallel opt-in** with its own destination and
  credential, duplicating what the gateway already knew.

The epic ([corveil/crow#1117](https://github.com/corveil/crow/issues/1117)) set out
to replace this with a real connected-app experience: Connect once, and Crow learns
the user's orgs and manages the per-org key and log wiring itself. Corveil already
runs its own OAuth authorization server (the DCR flow at `/mcp/oauth/*`), so Crow can
self-register and talk to Corveil directly rather than provisioning a client by hand.

## Decision

**A first-class `corveilConnection` config block is the source of truth for Corveil
access; the AI gateway and log-shipping configs are *generated* from it.**

- **Connect is OAuth, self-registered.** Crow performs Dynamic Client Registration +
  PKCE against Corveil's authorization server with a `127.0.0.1` loopback callback,
  and stores the resulting tokens in `corveilConnection`. A background watcher keeps
  the access token fresh and surfaces a `needs_reconnect` health state.
- **One auto-provisioned key per org, reused.** On org selection Crow mints exactly
  one `sk-citadel-…` key per org via `POST /api/keys` and reuses it across every
  workspace bound to that org. The backend deactivates the prior key on each mint, so
  Crow reuses the stored value and re-mints only on an explicit rotate.
- **Gateways are derived, not stored twice.** `CorveilConnection.derivedGateway(orgID:)`
  produces an ordinary `WorkspaceGateway` (`baseURL` + `x-citadel-api-key`), which
  `GatewayResolver` and the log collector consume unchanged. The org picker writes the
  binding; the credential never leaves the daemon host.
- **The whole surface is local-only.** Connect, org provisioning, and the migration
  verbs are authored only over the local Unix socket or a local-direct browser POST,
  alongside the other credential surfaces (`gateway`, `web-password`, `mcp token`). A
  remote web session gets a read-only view with tokens and key values stripped.
- **Manual gateways remain supported and are migrated by *adoption*.** A hand-entered
  `x-citadel-api-key` gateway still works (and is the right tool for any non-Corveil
  proxy). `crow corveil detect-gateways` classifies existing ones, and
  `crow corveil link-gateway` adopts a plaintext key into the connection as a
  user-named org's key — offline (the Corveil backend has no key→org lookup) and
  non-disruptive. An adopted key carries no key id, so a later `select-org` mints a
  real, revocable managed key in its place.

## Consequences

- **Easier:** one Connect replaces per-workspace key pasting; a key is tied to an org,
  kept fresh, and revocable on disconnect; log shipping reuses the gateway credential
  instead of a second opt-in; future Corveil features have a connection to build on.
- **Harder / to live with:** Crow now holds a cross-org, user-scoped token that can
  mint gateway keys in any org the user belongs to — a genuine trust extension that
  required a Corveil-side ADR and security review (per-call membership enforcement;
  minted keys tagged with the client id so disconnect can cascade-revoke). Connect is
  bound to the crowd host (loopback callback), so it can't be driven from a remote web
  session — the same constraint the gateway editor already had.
- **Migration is a bridge, not automatic.** Because the backend can't map a key back
  to an org, `link-gateway` needs the org from the user, and adopted keys are only
  fully "managed" (revocable) after a subsequent `select-org`. Manual gateways are
  never rewritten behind the user's back.

## Alternatives considered

- **Keep manual-only.** Rejected: the key sprawl and lack of provenance were the whole
  problem; a first-class connection is what removes them.
- **A thin / phased token path.** Rejected in design review in favour of building the
  real DCR-based Connected App now, so there is one connection model rather than a
  temporary one to migrate off later.
- **Talk to WorkOS directly for auth.** Rejected: Corveil already runs its own OAuth
  server, so Crow self-registers against Corveil (WorkOS is only the human login
  *inside* the authorize step) — no WorkOS redirect-URI change or manual client
  provisioning.
- **Auto-map manual keys to orgs during migration.** Not possible: the backend exposes
  no key→org lookup, so adoption takes the org from the user ("where possible").

## References

- Epic: [corveil/crow#1117](https://github.com/corveil/crow/issues/1117)
- PRs: [#1118](https://github.com/corveil/crow/issues/1118) (config model),
  [#1119](https://github.com/corveil/crow/issues/1119) (OAuth client),
  [#1120](https://github.com/corveil/crow/issues/1120) (connection door + CLI),
  [#1121](https://github.com/corveil/crow/issues/1121) (org provisioning),
  [#1122](https://github.com/corveil/crow/issues/1122) (Integrations tab),
  [#1123](https://github.com/corveil/crow/issues/1123) (org-dropdown gateway editors),
  [#1124](https://github.com/corveil/crow/issues/1124) (logsync + gateway wiring),
  [#1125](https://github.com/corveil/crow/issues/1125) (token health / reconnect),
  [#1126](https://github.com/corveil/crow/issues/1126) (docs + ADR + migration)
- Docs: [configuration.md → Corveil connection](../configuration.md#corveil-connection-first-class),
  [cli-reference.md → The Corveil connection](../cli-reference.md#the-corveil-connection)
- Code: `Packages/CrowCore/Sources/CrowCore/Models/AppConfig.swift` (`CorveilConnection`),
  `Packages/CrowCore/Sources/CrowCore/CorveilGatewayMigration.swift`,
  `Packages/CrowDaemon/Sources/CrowDaemon/Corveil*.swift`
