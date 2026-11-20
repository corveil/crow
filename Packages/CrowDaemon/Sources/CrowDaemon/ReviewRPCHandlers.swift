import CrowCore
import CrowEngine
import CrowIPC
import Foundation

/// Review-clone verbs (CROW-1492).
///
/// `review-restrip` removes PR-supplied harness config from a review session's
/// clone after `gh pr checkout` restored it (CROW-960). It runs here, in
/// `crowd`, because the agent's own `rm` runs inside the agent's sandbox, and
/// Claude Code's sandbox denies writes to `.claude/settings*.json`. The
/// guardrails live in `ReviewRestripRPC`.
func makeReviewHandlers(
    appState: AppState,
    devRoot: String
) -> [String: CommandRouter.Handler] {
    let handlers: [String: CommandRouter.Handler] = [
        "review-restrip": { params in
            guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required (a session UUID)")
            }
            return try await mapRPCError { () async throws -> [String: JSONValue] in
                let (session, worktree) = await MainActor.run {
                    (appState.sessions.first { $0.id == sessionID },
                     appState.primaryWorktree(for: sessionID))
                }
                let clonePath = try ReviewRestripRPC.clonePath(
                    session: session, worktree: worktree, devRoot: devRoot)
                let report = ReviewRestripRPC.restrip(clonePath: clonePath)
                guard report.isComplete else {
                    throw RPCError.applicationError(ReviewRestripRPC.incompleteMessage(report))
                }
                return [
                    "ok": .bool(true),
                    "session_id": .string(sessionID.uuidString),
                    "clone_path": .string(report.clonePath),
                    "removed": .array(report.removed.map { .string($0) }),
                ]
            }
        },
    ]
    return handlers
}
