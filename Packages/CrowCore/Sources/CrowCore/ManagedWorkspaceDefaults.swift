import Foundation

/// Managed / design-partner workspace creation defaults (CROW-2841).
///
/// The Governance story promises "one auditable request plane" that includes
/// Builder (Crow). But a workspace created with session log-sync off (today's
/// default) and no AI-gateway binding leaves no Corveil record at all — nothing
/// forces either connection. For the workspaces we *operate for customers* —
/// managed / design-partner installs — that audit-plane claim must be true by
/// default: harness traffic routes through the org's gateway, and transcripts
/// upload as session artifacts (feeding the Builder evidence ledger, #2838).
///
/// **"Managed / design-partner" is not a separate edition flag.** It is derived
/// from the state that already distinguishes an operated install from a
/// self-hosted OSS one: a first-class Corveil connection (ADR 0020) with a single
/// provisioned org whose gateway can be derived. A self-hosted OSS Crow never
/// connects, so it never matches and keeps today's opt-in (off) defaults — exactly
/// the behavior the ticket asks to preserve. This is the smallest possible signal:
/// no new config field, no new CLI verb, no parity-ledger surface.
///
/// Only *newly created* workspaces are defaulted, and only where the operator has
/// not already made a choice — an existing workspace, or one whose gateway is
/// already set, is never touched, so a later opt-out (untick the box, clear the
/// gateway) always sticks.
///
/// **The bound gateway is a credential** (it carries the org's `sk-citadel-…` key
/// inline). It is copied from a value the operator already authored through the
/// local-only Connect / org-provisioning flow, and it never crosses the wire:
/// every response path strips it (``WorkspaceRPC.workspaceJSON`` shows only the
/// base URL; ``SettingsSecrets.strippedForTransport`` blanks the header values).
/// So this materializes the operator's own managed policy on the daemon host — it
/// does not accept a credential from, or reveal one to, a caller.
public enum ManagedWorkspaceDefaults {
    /// Bind a freshly-created workspace to the managed org gateway and, when
    /// `enableUpload` is set, opt it into session log-sync (CROW-2841).
    ///
    /// The gateway is only written when the workspace has none of its own, so a
    /// caller that already bound one wins. `enableUpload` is kept separate from the
    /// gateway so the `workspace-add` CLI path can honor an explicit
    /// `--upload-session-logs false` while still binding the gateway — they are two
    /// distinct audit items (#11 gateway, #23 log-sync), and opting out of upload
    /// should not also unbind the gateway.
    ///
    /// - Returns: whether anything changed.
    @discardableResult
    public static func apply(
        to workspace: inout WorkspaceInfo, gateway: WorkspaceGateway, enableUpload: Bool
    ) -> Bool {
        let before = workspace
        if workspace.gateway?.isEmpty ?? true { workspace.gateway = gateway }
        if enableUpload { workspace.uploadSessionLogs = true }
        return workspace != before
    }

    /// Apply managed creation defaults to every workspace in `config` that is new
    /// relative to `previousWorkspaceIDs` — the `set-config` (web) write path,
    /// where a just-added workspace arrives with no gateway (the web can't author
    /// one) and `uploadSessionLogs` false.
    ///
    /// A no-op on a self-hosted OSS install (``AppConfig/managedWorkspaceGateway()``
    /// returns nil). New managed workspaces get both on unconditionally: a
    /// gateway-less new workspace's log-sync checkbox is disabled in the web form,
    /// so there is no explicit choice to override, and the next save sees the
    /// workspace as existing (its id is now in `previousWorkspaceIDs`) and leaves
    /// it alone — so a subsequent untick sticks.
    public static func applyToNewWorkspaces(
        in config: inout AppConfig, previousWorkspaceIDs: Set<UUID>
    ) {
        guard let gateway = config.managedWorkspaceGateway() else { return }
        for index in config.workspaces.indices
        where !previousWorkspaceIDs.contains(config.workspaces[index].id) {
            apply(to: &config.workspaces[index], gateway: gateway, enableUpload: true)
        }
    }
}

extension AppConfig {
    /// The AI gateway a newly-created managed / design-partner workspace binds to
    /// by default (CROW-2841), or `nil` when this install is self-hosted OSS or the
    /// choice is ambiguous.
    ///
    /// "Managed" is the state of being connected to Corveil (ADR 0020) with exactly
    /// one provisioned org whose gateway can be derived (a stored `sk-citadel-…`
    /// key + a base URL — ``CorveilConnection/derivedGateway(orgID:)``). The
    /// resolution is deliberately conservative:
    ///
    ///   - **No connection** → nil. A self-hosted OSS Crow never connects, so it
    ///     keeps today's opt-in defaults untouched.
    ///   - **Zero derivable orgs** → nil. Connected but no org key yet: there is no
    ///     gateway to bind, and log-sync without one uploads nothing anyway.
    ///   - **More than one derivable org** → nil. Which org a new workspace belongs
    ///     to is ambiguous, and binding the wrong org would route a customer's
    ///     traffic through another's gateway — so we don't guess; the operator
    ///     binds per workspace, exactly as before this default existed.
    ///
    /// Health is intentionally not consulted: the org gateway key is a separate
    /// credential from the OAuth grant, so an expired/revoked *connection* can still
    /// have a usable gateway key.
    public func managedWorkspaceGateway() -> WorkspaceGateway? {
        guard let connection = corveilConnection, !connection.isEmpty else { return nil }
        let derivable = connection.orgKeys.compactMap { connection.derivedGateway(orgID: $0.orgID) }
        guard derivable.count == 1 else { return nil }
        return derivable.first
    }
}
