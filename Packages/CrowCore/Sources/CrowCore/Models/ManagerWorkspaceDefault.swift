import Foundation

/// Keep `defaults.managerWorkspace` pointing at a real workspace across
/// workspace renames and removals (CROW-1386).
///
/// The default is stored by canonical name, so without this a rename or a
/// delete would leave it naming nothing. Every path that changes
/// `workspaces` — `workspace-edit`, `workspace-remove` and the web Settings
/// save (`set-config`) — runs this one rule against the workspaces as they
/// were before the write.
public enum ManagerWorkspaceDefaultChange: Equatable, Sendable {
    /// The workspace the default named was removed, so the default was cleared.
    case cleared(was: String)
    /// The workspace the default named was renamed, so the default followed it.
    case renamed(from: String, to: String)
}

extension AppConfig {
    /// Reconcile `defaults.managerWorkspace` with `workspaces` after a write.
    ///
    /// - Parameter previousWorkspaces: `workspaces` before the write. The
    ///   default is matched against them by name (case-insensitive) and then
    ///   followed by id, which is what tells a rename from a removal.
    /// - Returns: what changed, or nil when nothing did — including a default
    ///   that matched no previous workspace either (already stale; creation
    ///   treats it as unset, and nothing here can tell what it meant).
    @discardableResult
    public mutating func reconcileManagerWorkspaceDefault(
        previousWorkspaces: [WorkspaceInfo]
    ) -> ManagerWorkspaceDefaultChange? {
        guard let stored = defaults.managerWorkspace?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty,
            let before = previousWorkspaces.first(where: {
                $0.name.lowercased() == stored.lowercased()
            })
        else { return nil }
        guard let after = workspaces.first(where: { $0.id == before.id }) else {
            defaults.managerWorkspace = nil
            return .cleared(was: stored)
        }
        guard after.name.lowercased() != stored.lowercased() else { return nil }
        defaults.managerWorkspace = after.name
        return .renamed(from: stored, to: after.name)
    }
}
