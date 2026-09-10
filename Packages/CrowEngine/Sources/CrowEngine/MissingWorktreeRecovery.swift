import Foundation
import CrowCore
import CrowGit
import CrowPersistence

/// Register a `SessionWorktree` row from a managed terminal's cwd when a
/// work session has none (CROW-1219).
///
/// A work session can already be running with a checkout on disk while Crow's
/// store has no row — PR auto-link, merge labels, and `primaryWorktree(for:)`
/// all no-op until someone runs `crow add-worktree` by hand. The terminal cwd
/// is enough to reconstruct repo, path, and branch. This never creates a git
/// worktree; `add-worktree` already treats an existing `{path}/.git` as
/// metadata-only, and that is the failure mode here too.
enum MissingWorktreeRecovery {
    /// Scan every session and persist a primary worktree for each eligible
    /// work session that still has none. Returns the rows that were added.
    @MainActor
    static func recoverAll(appState: AppState, store: JSONStore, devRoot: String) -> [SessionWorktree] {
        var added: [SessionWorktree] = []
        for session in appState.sessions {
            if let wt = inferredWorktree(session: session, appState: appState, devRoot: devRoot) {
                added.append(wt)
            }
        }
        persist(added, appState: appState, store: store)
        return added
    }

    /// Recover a single session — the `new-terminal` hook. No-ops when the
    /// session is ineligible or already has a worktree.
    @MainActor
    static func recoverIfNeeded(
        sessionID: UUID,
        appState: AppState,
        store: JSONStore,
        devRoot: String
    ) -> SessionWorktree? {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }) else {
            return nil
        }
        guard let wt = inferredWorktree(session: session, appState: appState, devRoot: devRoot) else {
            return nil
        }
        persist([wt], appState: appState, store: store)
        return wt
    }

    @MainActor
    private static func inferredWorktree(
        session: Session,
        appState: AppState,
        devRoot: String
    ) -> SessionWorktree? {
        // Jobs, reviews, and Managers get their rows at creation (or, for
        // Managers, never). Explore is still `kind == .work`; a missing row
        // there is the same bootstrap gap, and inferring is harmless because
        // we only register a checkout that already exists.
        guard session.kind == .work else { return nil }
        guard appState.worktrees(for: session.id).isEmpty else { return nil }

        let terminals = appState.terminals(for: session.id)
        guard let cwd = terminals.first(where: { $0.isManaged && !$0.cwd.isEmpty })?.cwd else {
            return nil
        }
        guard let inferred = WorktreeInference.infer(cwd: cwd, devRoot: devRoot) else {
            return nil
        }
        CrowLog.info(
            "[Crow] inferred missing worktree for session \(session.id.uuidString) "
                + "at \(inferred.worktreePath) (\(inferred.branch))"
        )
        return SessionWorktree(
            sessionID: session.id,
            repoName: inferred.repoName,
            repoPath: inferred.repoPath,
            worktreePath: inferred.worktreePath,
            branch: inferred.branch,
            isPrimary: true
        )
    }

    @MainActor
    private static func persist(
        _ worktrees: [SessionWorktree],
        appState: AppState,
        store: JSONStore
    ) {
        guard !worktrees.isEmpty else { return }
        for wt in worktrees {
            appState.worktrees[wt.sessionID, default: []].append(wt)
        }
        store.mutate { $0.worktrees.append(contentsOf: worktrees) }
    }
}
