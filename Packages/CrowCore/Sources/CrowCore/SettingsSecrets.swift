import Foundation

/// Credential handling for the cross-platform web Settings UI (CROW-581).
///
/// The desktop app edits `AppConfig` in-process, so its credential fields never
/// leave the machine. The web Settings modal, however, ships the whole config to
/// a browser to render the form. Three fields hold secrets that must **not** be
/// sent as plaintext, and — per the product decision — are **desktop-only,
/// read-only on the web**:
///   - `jiraCredential.tokenRef` (Jira API token — `op://` ref or plaintext)
///   - `managerGateway.customHeaders` values (AI-gateway auth headers)
///   - each `workspaces[].gateway.customHeaders` value (per-workspace gateway auth)
///
/// So the web round-trip is deliberately trivial: **strip** the credential values
/// on the way out (the browser shows names/URLs/username read-only but never the
/// value), and on the way back **restore** the currently-stored credential fields
/// verbatim — the browser can neither change nor clear them. There is no merge,
/// no sentinel, and no path by which a web write can blank a stored `op://` ref.
public enum SettingsSecrets {
    /// Return a copy of `config` with every credential **value** blanked, safe to
    /// serialize to the browser.
    ///
    /// Only the values are cleared, not the surrounding structure: the Jira
    /// `username`, each gateway `baseURL`, and the gateway header **names** pass
    /// through so the read-only web view can show what's configured. Blanking only
    /// the header values (leaving the keys) keeps `WorkspaceGateway`'s
    /// both-or-neither decode invariant satisfied — a stripped gateway still has a
    /// non-empty `customHeaders` dict and a non-empty `baseURL`, so it round-trips
    /// through `JSONDecoder` unchanged in shape.
    public static func strippedForTransport(_ config: AppConfig) -> AppConfig {
        var c = config
        if c.jiraCredential != nil { c.jiraCredential?.tokenRef = "" }
        if let gateway = c.managerGateway { c.managerGateway = stripHeaderValues(gateway) }
        c.workspaces = c.workspaces.map { workspace in
            var w = workspace
            if let gateway = w.gateway { w.gateway = stripHeaderValues(gateway) }
            return w
        }
        return c
    }

    /// Return `incoming` (a browser-edited config) with its three credential
    /// fields overwritten by the values currently stored in `current` — the
    /// authoritative source. Because the credentials are read-only on the web,
    /// whatever the browser sent for them is ignored entirely and the stored
    /// values win: an untouched round-trip is a no-op, and a buggy or hostile
    /// client can neither replace nor erase a stored token/header.
    ///
    /// Per-workspace gateways are matched to `current` by workspace `id`. A
    /// workspace present in `incoming` but not in `current` (e.g. one just added
    /// from the web) keeps whatever gateway it arrived with — which is `nil`,
    /// since the web can't author a gateway.
    public static func preservingSecrets(incoming: AppConfig, current: AppConfig?) -> AppConfig {
        var result = incoming
        result.jiraCredential = current?.jiraCredential
        result.managerGateway = current?.managerGateway
        if let current {
            let currentGatewaysByID = Dictionary(
                current.workspaces.map { ($0.id, $0.gateway) },
                uniquingKeysWith: { first, _ in first })
            result.workspaces = result.workspaces.map { workspace in
                guard let storedGateway = currentGatewaysByID[workspace.id] else { return workspace }
                var w = workspace
                w.gateway = storedGateway
                return w
            }
        } else {
            // No stored config to restore from — drop any gateway the browser
            // sent so a plaintext value can't be introduced via the web path.
            result.workspaces = result.workspaces.map { workspace in
                var w = workspace
                w.gateway = nil
                return w
            }
        }
        return result
    }

    /// Blank a gateway's header values while keeping its keys and `baseURL`.
    private static func stripHeaderValues(_ gateway: WorkspaceGateway) -> WorkspaceGateway {
        WorkspaceGateway(
            baseURL: gateway.baseURL,
            customHeaders: gateway.customHeaders.mapValues { _ in "" })
    }
}
