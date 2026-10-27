import CrowCore
import CrowIPC
import Foundation

/// Decide which workspace a new extra Manager is tagged with (CROW-1382,
/// CROW-1386).
///
/// Shared by every surface that creates one — `create-manager` (CLI and the
/// web "+" button) and Scratch `todo explore` / `todo ticket` — so the rule
/// has one implementation. Pure: config in, decision out.
///
/// Every new extra Manager has a workspace (CROW-1386). Crow never guesses
/// one: it comes from, in order,
/// 1. the caller's explicit choice (`--workspace`, the dialog);
/// 2. the context the Manager is created from (a Scratch item's workspace,
///    or the tagged Manager the request came from);
/// 3. `defaults.managerWorkspace`.
/// If none of them names a workspace that exists, creation is refused. Only
/// the primary Manager is untagged, and it is never created here.
public enum ManagerWorkspaceTag {
    public struct Decision: Equatable, Sendable {
        public var workspaceID: UUID
        public var workspaceName: String
    }

    /// The hint every refusal ends with, so the CLI and the web read the same.
    static let fixHint =
        "Pass --workspace NAME, or set a default with `crow defaults set --manager-workspace NAME`."

    /// - Parameters:
    ///   - requested: the caller's `workspace` param — a workspace name
    ///     (case-insensitive) or UUID. Nil means "not chosen".
    ///   - context: the workspace of whatever the Manager is created from, by
    ///     name or UUID. A context that no longer resolves (a renamed or
    ///     removed workspace) is skipped, like a stale default.
    /// - Throws: `RPCError.invalidParams` when `requested` matches no
    ///   workspace (or several), and when nothing resolves at all.
    public static func resolve(
        requested: String?, context: String? = nil, config: AppConfig
    ) throws -> Decision {
        guard !config.workspaces.isEmpty else {
            throw RPCError.invalidParams(
                "No workspaces are configured, and every extra Manager needs one. "
                    + "Add a workspace first (`crow workspace add --name NAME` or Settings → Workspaces).")
        }
        if let raw = trimmed(requested) {
            if raw.lowercased() == "none", lenient(raw, in: config) == nil {
                throw RPCError.invalidParams(
                    "Untagged extra Managers are no longer supported — every extra Manager needs a workspace. "
                        + fixHint)
            }
            let workspace = config.workspaces[try WorkspaceRPC.resolveIndex(raw, in: config)]
            return Decision(workspaceID: workspace.id, workspaceName: workspace.name)
        }
        for candidate in [context, config.defaults.managerWorkspace] {
            if let workspace = trimmed(candidate).flatMap({ lenient($0, in: config) }) {
                return Decision(workspaceID: workspace.id, workspaceName: workspace.name)
            }
        }
        throw RPCError.invalidParams(
            "No workspace for the new Manager: none was given and no default is set"
                + staleDefaultNote(config) + ". " + fixHint)
    }

    /// The workspace `defaults.managerWorkspace` names, or nil when it is
    /// unset or stale. The web "+" fast path keys off this: a stale default
    /// opens the dialog instead of creating.
    public static func resolvedDefault(in config: AppConfig) -> WorkspaceInfo? {
        trimmed(config.defaults.managerWorkspace).flatMap { lenient($0, in: config) }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Name (case-insensitive) or UUID, nil when it matches nothing.
    private static func lenient(_ ref: String, in config: AppConfig) -> WorkspaceInfo? {
        if let id = UUID(uuidString: ref), let match = config.workspaces.first(where: { $0.id == id }) {
            return match
        }
        return config.workspaces.first { $0.name.lowercased() == ref.lowercased() }
    }

    private static func staleDefaultNote(_ config: AppConfig) -> String {
        guard let stale = trimmed(config.defaults.managerWorkspace) else { return "" }
        return " (defaults.managerWorkspace names '\(stale)', which is not a workspace)"
    }
}
