# 0023 — Managed / design-partner workspaces default gateway binding + log-sync on

- **Status:** Accepted
- **Date:** 2026-09-01
- **Deciders:** @dhilgaertner

## Context

The Governance story promises "one auditable request plane" that includes Builder
(Crow). But a workspace created with session log-sync off (today's default, ADR
0020 / CROW-1070) and no AI-gateway binding leaves **no** Corveil record at all:
harness traffic doesn't route through the org's gateway, and no transcript uploads
as a session artifact. Nothing forces either connection, so the audit-plane claim is
aspirational rather than true by default — and the Builder evidence ledger (#2838)
only has `AgentSession` records for workspaces that happened to opt in.

Andy's call (audit items #11 + #23, filed as
[corveil/corveil#2841](https://github.com/corveil/corveil/issues/2841)): for the
workspaces **we operate for customers** — managed / design-partner installs — both
should be **on by default**. Self-hosted OSS Crow must keep today's opt-in (off)
defaults, so this cannot be an unconditional behavior change.

That raises the real question: *how does Crow know it is a managed / design-partner
install rather than a self-hosted OSS one?* There was no edition flag, and adding
one (a new `AppConfig` field + CLI verb + web control) is a lot of surface for a
distinction the config already encodes.

## Decision

**"Managed / design-partner" is derived from the first-class Corveil connection
(ADR 0020), not a new flag.** A workspace is created with the org gateway bound and
`uploadSessionLogs` on **iff** the install has a connected `corveilConnection` with
exactly one provisioned org whose gateway can be derived. A self-hosted OSS Crow
never connects, so it never matches and its opt-in-off defaults are untouched.

- The single provisioned org's `CorveilConnection.derivedGateway(orgID:)` is bound
  as the new workspace's `gateway`, and `uploadSessionLogs` is set true — the same
  "org binding ⇒ log-sync on" pairing the org picker already applies
  (`SecretRoutes.orgSelectionEnablesLogSync`, corveil/crow#1124), now at creation
  time.
- Applied at both creation surfaces: `workspace-add` (CLI) and `set-config` (the
  web "Add workspace" path), sharing one Core helper (`ManagedWorkspaceDefaults`).
- Only **new** workspaces, and only where the field is unset: an existing workspace
  is never re-flipped, and `workspace-add` honors an explicit
  `--upload-session-logs false` (the gateway, a distinct audit item, still binds).
- Resolution is conservative: zero derivable orgs (connected, none provisioned) or
  more than one (ambiguous — binding the wrong org would route a customer's traffic
  through another's gateway) both fall back to no default.

## Consequences

- **Easier:** the audit-plane claim is true by default on the installs where it
  matters, with **zero** new config surface — no `AppConfig` field, no CLI verb, no
  parity-ledger row, no new web control. The Builder evidence ledger (#2838) gains
  `AgentSession` coverage automatically as managed workspaces are created.
- **To live with — implicit signal:** connecting Corveil and provisioning an org
  changes workspace-creation defaults. That is the intent ("true by default once
  operating within Corveil"), it is reversible (untick the box / clear the gateway),
  and it never touches existing workspaces — but it is a behavior a reader must know
  is connection-derived, hence this ADR.
- **To live with — ambiguity is a no-op:** a design partner with two provisioned
  orgs gets no auto-binding and picks per workspace, exactly as before. Safe over
  clever: we never guess which org a workspace belongs to.
- **Credential handling:** the bound gateway carries the org's `sk-citadel-…` key
  inline. It is copied from a value the operator already authored through the
  local-only Connect / org-provisioning flow, and it never crosses the wire — every
  response path strips it (`WorkspaceRPC.workspaceJSON` shows only the base URL;
  `SettingsSecrets.strippedForTransport` blanks header values). So creation from a
  remote authenticated peer materializes the operator's own managed policy on the
  daemon host; it neither accepts a credential from, nor reveals one to, the caller.

## Alternatives considered

- **A new explicit edition flag** (`defaults.managedWorkspaceDefaults`, or a
  connection field). Rejected: it is the larger surface the ticket asks to avoid
  ("propose the smallest one"), and it *still* has to resolve "which org" from the
  connection — so the connection is the real signal regardless.
- **A build / edition compile flag.** Rejected: managed vs OSS is a runtime
  deployment property, not a build one; the same binary serves both.
- **Retroactively flipping existing managed workspaces on.** Rejected: it would
  clobber a deliberate opt-out. "Default" means at creation, not a migration.
- **Binding at gateway-resolution time instead of storing the gateway.** Rejected:
  the log collector reads the materialized `WorkspaceInfo.gateway` for its upload
  credential, so the binding must be stored, not resolved lazily.

## References

- PR: (this change) — Refs [corveil/corveil#2841](https://github.com/corveil/corveil/issues/2841)
- Related ADRs: [0020](./0020-first-class-corveil-integration.md) (first-class
  Corveil integration — the connection this derives from)
- Code: `Packages/CrowCore/Sources/CrowCore/ManagedWorkspaceDefaults.swift`,
  `Packages/CrowDaemon/Sources/CrowDaemon/WorkspaceRPCHandlers.swift`
  (`workspace-add`), `Packages/CrowDaemon/Sources/CrowDaemon/SnapshotRPCHandlers.swift`
  + `Packages/CrowEngine/Sources/CrowEngine/EngineRouter.swift` (`set-config`)
