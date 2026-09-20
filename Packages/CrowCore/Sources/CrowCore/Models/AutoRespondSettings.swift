import Foundation

/// Opt-in settings that let Crow type instructions into a session's managed
/// Claude Code terminal when a watched PR transitions into a state that
/// usually requires action.
///
/// `respondToChangesRequested` defaults **on** as of CROW-505 — auto-refine
/// is the answer to the user's complaint that a PR sitting in
/// CHANGES_REQUESTED with an idle agent never re-prompts. Existing users'
/// explicit choices stay sticky: `decodeIfPresent` returns whatever was
/// previously written, so a user who turned this off keeps it off across
/// the upgrade. `respondToFailedChecks` still defaults off — typing into a
/// terminal unprompted is intrusive, and CI flakes shouldn't auto-trigger
/// a fix-attempt.
public struct AutoRespondSettings: Codable, Sendable, Equatable {
    /// Inject a "fix the review feedback" prompt when a PR transitions into
    /// `reviewStatus == .changesRequested`.
    public var respondToChangesRequested: Bool
    /// Inject a "fix the failing checks" prompt when a PR transitions into
    /// `checksPass == .failing` (keyed on the head SHA, so re-runs of the
    /// same commit don't re-fire).
    public var respondToFailedChecks: Bool
    /// Auto-rebase Crow-authored PR branches that fall BEHIND base or become
    /// CONFLICTING: rebase onto base and force-push (`--force-with-lease`);
    /// when the rebase hits conflicts, inject the fixConflicts prompt into the
    /// session's managed terminal so Claude resolves them. Force-push-bearing,
    /// so opt-in: defaults to false (CROW-551; formerly the top-level
    /// `autoRebaseWatcherEnabled`, CROW-318).
    public var autoRebaseAndResolveConflicts: Bool
    /// Re-request review automatically when a CHANGES_REQUESTED PR's findings
    /// have been addressed and nobody has been asked to look again (CROW-921).
    /// Runs `gh pr edit --add-reviewer` from the daemon rather than asking the
    /// agent to do it, so it works no matter which path fixed the PR.
    ///
    /// Defaults to **true**, alongside `respondToChangesRequested`: the
    /// `addressChanges` prompt has always instructed the agent to re-request,
    /// so this completes behaviour users already expect rather than adding a
    /// new one. (Contrast `autoRebaseAndResolveConflicts`, which defaults off
    /// because it force-pushes.) Re-requesting is idempotent and reversible.
    public var autoReRequestReview: Bool

    public init(
        respondToChangesRequested: Bool = true,
        respondToFailedChecks: Bool = false,
        autoRebaseAndResolveConflicts: Bool = false,
        autoReRequestReview: Bool = true
    ) {
        self.respondToChangesRequested = respondToChangesRequested
        self.respondToFailedChecks = respondToFailedChecks
        self.autoRebaseAndResolveConflicts = autoRebaseAndResolveConflicts
        self.autoReRequestReview = autoReRequestReview
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        respondToChangesRequested = try c.decodeIfPresent(Bool.self, forKey: .respondToChangesRequested) ?? true
        respondToFailedChecks = try c.decodeIfPresent(Bool.self, forKey: .respondToFailedChecks) ?? false
        autoRebaseAndResolveConflicts = try c.decodeIfPresent(Bool.self, forKey: .autoRebaseAndResolveConflicts) ?? false
        autoReRequestReview = try c.decodeIfPresent(Bool.self, forKey: .autoReRequestReview) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case respondToChangesRequested, respondToFailedChecks, autoRebaseAndResolveConflicts
        case autoReRequestReview
    }
}
