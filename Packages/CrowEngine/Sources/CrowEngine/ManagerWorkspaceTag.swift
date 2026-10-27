import CrowCore
import CrowIPC
import Foundation

/// Decide which workspace a new extra Manager is tagged with (CROW-1382).
///
/// Shared by every surface that creates one — `create-manager` (CLI and the
/// web "+" button) — so "absent means the default, `none` means untagged" has
/// one implementation. Pure: config in, decision out.
public enum ManagerWorkspaceTag {
    /// The spelling that asks for an untagged (cross-workspace) Manager even
    /// when `defaults.managerWorkspace` is set. Matched case-insensitively; a
    /// blank string means the same thing.
    public static let noneKeyword = "none"

    public struct Decision: Equatable, Sendable {
        /// The workspace to tag with, or nil for untagged.
        public var workspaceID: UUID?
        public var workspaceName: String?
        /// Set when the configured default names no workspace any more, so the
        /// Manager was created untagged instead. Advisory, never an error: the
        /// default is set once and outlives renames, and refusing to create a
        /// Manager over it would break the "+" button.
        public var warning: String?
    }

    /// - Parameter requested: the caller's `workspace` param. `nil` (absent)
    ///   falls back to `config.defaults.managerWorkspace`; `""` or `none` asks
    ///   for an untagged Manager; anything else is a workspace name
    ///   (case-insensitive) or UUID.
    /// - Throws: `RPCError.invalidParams` when an explicit `requested` matches
    ///   no workspace, or several.
    public static func resolve(requested: String?, config: AppConfig) throws -> Decision {
        if let raw = requested?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if raw.isEmpty || raw.lowercased() == noneKeyword {
                return Decision(workspaceID: nil, workspaceName: nil, warning: nil)
            }
            let workspace = config.workspaces[try WorkspaceRPC.resolveIndex(raw, in: config)]
            return Decision(workspaceID: workspace.id, workspaceName: workspace.name, warning: nil)
        }
        guard let fallback = config.defaults.managerWorkspace?
            .trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty
        else { return Decision(workspaceID: nil, workspaceName: nil, warning: nil) }
        guard let workspace = config.workspaces.first(where: {
            $0.name.lowercased() == fallback.lowercased()
        }) else {
            return Decision(
                workspaceID: nil, workspaceName: nil,
                warning: "defaults.managerWorkspace names '\(fallback)', which is not a workspace — "
                    + "created an untagged Manager. Fix it with `crow defaults set --manager-workspace`.")
        }
        return Decision(workspaceID: workspace.id, workspaceName: workspace.name, warning: nil)
    }
}
