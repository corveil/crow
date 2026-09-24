import Foundation
import CrowCore

// MARK: - SessionService facades (CROW-1113)
//
// Moved to its own file by CROW-1302. Spellings stay on `SessionService`
// so tests and other modules call them unchanged.

extension SessionService {
    @discardableResult
    public func createReviewSession(prURL: String, selectAfterCreate: Bool = false) async -> UUID? {
        await review.createReviewSession(prURL: prURL, selectAfterCreate: selectAfterCreate)
    }

    /// Filename of the launcher's initial prompt file for a session kind
    /// (see `ReviewSessionController.initialPromptFileName`).
    nonisolated static func initialPromptFileName(for kind: SessionKind) -> String? {
        ReviewSessionController.initialPromptFileName(for: kind)
    }

    /// Build the initial prompt for a review session
    /// (see `ReviewSessionController.buildReviewPrompt`).
    nonisolated static func buildReviewPrompt(
        prURL: String, prTitle: String, repoSlug: String, prNumber: Int,
        agentKind: AgentKind, skillBody: String? = nil
    ) -> String {
        ReviewSessionController.buildReviewPrompt(
            prURL: prURL, prTitle: prTitle, repoSlug: repoSlug, prNumber: prNumber,
            agentKind: agentKind, skillBody: skillBody)
    }

    /// Inlined-SKILL substitutions for slash-command-less review agents
    /// (see `ReviewSessionController.cursorReviewPrompt`).
    nonisolated static func cursorReviewPrompt(
        skillBody: String, prURL: String, agentKind: AgentKind = .cursor
    ) -> String {
        ReviewSessionController.cursorReviewPrompt(
            skillBody: skillBody, prURL: prURL, agentKind: agentKind)
    }

    nonisolated static func shouldRefuseReviewHandoff(
        targetKind: AgentKind, sessionKind: SessionKind) -> Bool {
        ReviewSessionController.shouldRefuseReviewHandoff(
            targetKind: targetKind, sessionKind: sessionKind)
    }

    nonisolated static func shouldStripCursorReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        ReviewSessionController.shouldStripCursorReviewClone(
            agentKind: agentKind, sessionKind: sessionKind)
    }

    nonisolated static func shouldStripAntigravityReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        ReviewSessionController.shouldStripAntigravityReviewClone(
            agentKind: agentKind, sessionKind: sessionKind)
    }

    nonisolated static func shouldStripMuseReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        ReviewSessionController.shouldStripMuseReviewClone(
            agentKind: agentKind, sessionKind: sessionKind)
    }

    nonisolated static func shouldStripGrokReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        ReviewSessionController.shouldStripGrokReviewClone(
            agentKind: agentKind, sessionKind: sessionKind)
    }

    nonisolated static func stripMuseConfigFromReviewClone(clonePath: String) {
        ReviewSessionController.stripMuseConfigFromReviewClone(clonePath: clonePath)
    }

    nonisolated static func stripAntigravityConfigFromReviewClone(clonePath: String) {
        ReviewSessionController.stripAntigravityConfigFromReviewClone(clonePath: clonePath)
    }

    nonisolated static func stripCursorConfigFromReviewClone(clonePath: String) {
        ReviewSessionController.stripCursorConfigFromReviewClone(clonePath: clonePath)
    }

    nonisolated static func stripGrokConfigFromReviewClone(clonePath: String) {
        ReviewSessionController.stripGrokConfigFromReviewClone(clonePath: clonePath)
    }

    nonisolated static func stripPriorCompatHooksForGrokHandoff(worktreePath: String) {
        ReviewSessionController.stripPriorCompatHooksForGrokHandoff(worktreePath: worktreePath)
    }
}
