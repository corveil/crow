import Foundation
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider

// MARK: - IssueTracker compatibility surface (CROW-1094)
//
// Preserves the `IssueTracker.<symbol>` / `tracker.<member>` spelling used by
// the tests, by addMergeLabel, and by the rebase / re-review watchers
// (owner.codeBackend / owner.prHasCrowAuthoredCommit). All logic and state live
// on `AutoMergeController`. Split into its own file by CROW-1286 so the facade
// reviews apart from the watcher it forwards to.
extension IssueTracker {
    typealias AutoMergeSkipReason = AutoMergeController.AutoMergeSkipReason
    typealias AutoMergeOutcome = AutoMergeController.AutoMergeOutcome

    nonisolated static func shouldAttemptAutoMerge(pr: ViewerPR, session: Session) -> Bool {
        AutoMergeController.shouldAttemptAutoMerge(pr: pr, session: session)
    }
    nonisolated static func autoMergeSkipReason(pr: ViewerPR, session: Session) -> AutoMergeSkipReason? {
        AutoMergeController.autoMergeSkipReason(pr: pr, session: session)
    }
    nonisolated static func hasAutoMergeLabel(pr: ViewerPR) -> Bool {
        AutoMergeController.hasAutoMergeLabel(pr: pr)
    }
    nonisolated static func isPermanentAutoMergeFailure(_ error: Error) -> Bool {
        AutoMergeController.isPermanentAutoMergeFailure(error)
    }
    nonisolated static func directMergeGatesPass(pr: ViewerPR, session: Session) -> Bool {
        AutoMergeController.directMergeGatesPass(pr: pr, session: session)
    }
    nonisolated static func shouldDirectMerge(pr: ViewerPR, session: Session) -> Bool {
        AutoMergeController.shouldDirectMerge(pr: pr, session: session)
    }
    nonisolated static func shouldUpdateBranchBeforeMerge(pr: ViewerPR, session: Session) -> Bool {
        AutoMergeController.shouldUpdateBranchBeforeMerge(pr: pr, session: session)
    }
    nonisolated static func crowAuthored(commitMessages: [String], knownSessionIDs: Set<UUID>) -> Bool {
        AutoMergeController.crowAuthored(commitMessages: commitMessages, knownSessionIDs: knownSessionIDs)
    }
    nonisolated static func shouldRetryFailedUpdateBranch(failureCount: Int) -> Bool {
        AutoMergeController.shouldRetryFailedUpdateBranch(failureCount: failureCount)
    }
    nonisolated static var maxAutoUpdateBranchFailureRetries: Int {
        AutoMergeController.maxAutoUpdateBranchFailureRetries
    }

    // Shared merge helpers (also used by the rebase / re-review watchers).
    func codeBackend(for session: Session) -> CodeBackend? { autoMerge.codeBackend(for: session) }
    func prHasCrowAuthoredCommit(pr: ViewerPR, backend: CodeBackend) async -> Bool {
        await autoMerge.prHasCrowAuthoredCommit(pr: pr, backend: backend)
    }

    // Instance entry points exercised directly by tests / addMergeLabel.
    func evaluateAutoMerge(session: Session, byURL: [String: ViewerPR]) -> AutoMergeOutcome {
        autoMerge.evaluateAutoMerge(session: session, byURL: byURL)
    }
    func publishWatcherOffVerdict(session: Session, byURL: [String: ViewerPR]) {
        autoMerge.publishWatcherOffVerdict(session: session, byURL: byURL)
    }
    func attemptUpdateBranch(session: Session, pr: ViewerPR, headKey: String) async {
        await autoMerge.attemptUpdateBranch(session: session, pr: pr, headKey: headKey)
    }
    func autoMergeWarning(sessionID: UUID) -> String? { autoMerge.autoMergeWarning(sessionID: sessionID) }

    nonisolated static var autoMergeLabel: String { AutoMergeController.autoMergeLabel }

    var autoMergeInFlight: Set<String> {
        get { autoMerge.autoMergeInFlight } set { autoMerge.autoMergeInFlight = newValue }
    }
    var autoUpdateBranchAttempted: Set<String> {
        get { autoMerge.autoUpdateBranchAttempted } set { autoMerge.autoUpdateBranchAttempted = newValue }
    }
    var autoUpdateBranchFailureCounts: [String: Int] {
        get { autoMerge.autoUpdateBranchFailureCounts } set { autoMerge.autoUpdateBranchFailureCounts = newValue }
    }
}
