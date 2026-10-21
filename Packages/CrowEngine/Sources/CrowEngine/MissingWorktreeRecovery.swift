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
///
/// `WorktreeInference.infer` runs several synchronous `git` subprocesses, so
/// it must never run on MainActor (CROW-1346, regressing CROW-1179). The
/// shape is snapshot → infer off-actor → re-check and persist on MainActor.
enum MissingWorktreeRecovery {
    /// An eligible session and the managed-terminal cwd to infer from,
    /// captured on MainActor so inference can run without touching `AppState`.
    struct Candidate: Sendable {
        let sessionID: UUID
        let cwd: String
    }

    /// `(cwd, devRoot) -> Result?`. Production uses `WorktreeInference.infer`;
    /// tests inject one to control timing and observe the calling thread.
    typealias Inferer = @Sendable (_ cwd: String, _ devRoot: String) -> WorktreeInference.Result?

    /// Scan every session and persist a primary worktree for each eligible
    /// work session that still has none. Returns the rows that were added.
    @MainActor
    static func recoverAll(
        appState: AppState,
        store: JSONStore,
        devRoot: String,
        inferer: @escaping Inferer = WorktreeInference.infer(cwd:devRoot:)
    ) async -> [SessionWorktree] {
        let candidates = appState.sessions.compactMap { candidate(session: $0, appState: appState) }
        return await recover(
            candidates, appState: appState, store: store, devRoot: devRoot, inferer: inferer)
    }

    /// Recover a single session — the `new-terminal` hook. No-ops when the
    /// session is ineligible or already has a worktree.
    @MainActor
    static func recoverIfNeeded(
        sessionID: UUID,
        appState: AppState,
        store: JSONStore,
        devRoot: String,
        inferer: @escaping Inferer = WorktreeInference.infer(cwd:devRoot:)
    ) async -> SessionWorktree? {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }),
              let candidate = candidate(session: session, appState: appState) else {
            return nil
        }
        return await recover(
            [candidate], appState: appState, store: store, devRoot: devRoot, inferer: inferer
        ).first
    }

    @MainActor
    private static func candidate(session: Session, appState: AppState) -> Candidate? {
        guard isEligible(session: session, appState: appState) else { return nil }
        let terminals = appState.terminals(for: session.id)
        guard let cwd = terminals.first(where: { $0.isManaged && !$0.cwd.isEmpty })?.cwd else {
            return nil
        }
        return Candidate(sessionID: session.id, cwd: cwd)
    }

    @MainActor
    private static func isEligible(session: Session, appState: AppState) -> Bool {
        // Jobs, reviews, and Managers get their rows at creation (or, for
        // Managers, never). Explore is still `kind == .work`; a missing row
        // there is the same bootstrap gap, and inferring is harmless because
        // we only register a checkout that already exists.
        session.kind == .work && appState.worktrees(for: session.id).isEmpty
    }

    @MainActor
    private static func recover(
        _ candidates: [Candidate],
        appState: AppState,
        store: JSONStore,
        devRoot: String,
        inferer: @escaping Inferer
    ) async -> [SessionWorktree] {
        guard !candidates.isEmpty else { return [] }
        let inferred = await infer(candidates, devRoot: devRoot, inferer: inferer)

        // Back on MainActor. Another refresh or a `new-terminal` hook may have
        // recovered (or `add-worktree` registered) the same session while we
        // were suspended, so re-check before appending. The check and the
        // append below run with no suspension point between them, which is
        // what keeps overlapping recoveries from double-appending.
        var added: [SessionWorktree] = []
        for (sessionID, result) in inferred {
            guard let session = appState.sessions.first(where: { $0.id == sessionID }),
                  isEligible(session: session, appState: appState) else {
                continue
            }
            CrowLog.info(
                "[Crow] inferred missing worktree for session \(sessionID.uuidString) "
                    + "at \(result.worktreePath) (\(result.branch))"
            )
            added.append(SessionWorktree(
                sessionID: sessionID,
                repoName: result.repoName,
                repoPath: result.repoPath,
                worktreePath: result.worktreePath,
                branch: result.branch,
                isPrimary: true
            ))
        }
        persist(added, appState: appState, store: store)
        return added
    }

    /// Run the `git` subprocesses on a detached task so they never block
    /// MainActor, whatever isolation the caller has.
    private static func infer(
        _ candidates: [Candidate],
        devRoot: String,
        inferer: @escaping Inferer
    ) async -> [(UUID, WorktreeInference.Result)] {
        await Task.detached(priority: .utility) {
            candidates.compactMap { candidate in
                inferer(candidate.cwd, devRoot)
                    .map { (candidate.sessionID, $0) }
            }
        }.value
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
