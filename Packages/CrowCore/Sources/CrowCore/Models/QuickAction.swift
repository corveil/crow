import Foundation

/// A user-triggered next step that maps 1:1 to a PR status badge on the
/// session card. Selecting the action injects a deterministic prompt into
/// the session's managed Claude Code terminal so the user can act without
/// switching focus into the session.
///
/// Mirrors the auto-respond pipeline (`AutoRespondCoordinator`) but bypasses
/// the per-toggle `AutoRespondSettings` gate — the user clicked, so intent
/// is explicit.
public enum QuickAction: String, Sendable, Equatable {
    /// `mergeable == .conflicting` — rebase onto base and resolve conflicts.
    case fixConflicts
    /// `reviewStatus == .changesRequested` — read review feedback and fix.
    case addressChanges
    /// `checksPass == .failing` — investigate failing checks and fix.
    case fixChecks
    /// `isReadyToMerge` — merge the PR.
    case mergePR
    /// `reviewStatus == .changesRequested` on a **review** session — re-run the
    /// review on the author's latest head and post a fresh verdict. The
    /// reviewer-side counterpart to `addressChanges`; never edits code (#757).
    /// Manual counterpart to the automatic head-advance re-review (#756) —
    /// both share `QuickActionPrompts.reReviewPrompt` so they can't drift.
    case reReview

    /// Whether this action modifies the code under review — commits/pushes to
    /// the PR branch. A reviewer must never do this to the branch they review
    /// (CROW-551), so `dispatchManual` refuses these on review sessions,
    /// mirroring `AutoRespondCoordinator.shouldSkipReviewSession` on the manual
    /// path (#757). `reReview` and `mergePR` are not code-modifying in this
    /// sense and stay allowed.
    public var modifiesCodeUnderReview: Bool {
        switch self {
        case .addressChanges, .fixChecks, .fixConflicts: return true
        case .mergePR, .reReview:                        return false
        }
    }
}

/// Outcome of a manual `dispatchManual(action:sessionID:)` attempt. Lets callers
/// (the daemon `quick-action` handler, the web UI) report honestly instead of
/// assuming success: `dispatchManual` silently skips — NSLog only — when there's
/// no managed terminal, the terminal surface isn't ready, or the session has no
/// PR link, which previously surfaced as a false "dispatched" echo (#730).
public enum QuickActionDispatchResult: Sendable, Equatable {
    /// The prompt was pasted into the session's managed agent terminal.
    case sent
    /// The session has no managed terminal to send the prompt to.
    case noManagedTerminal
    /// The managed terminal exists but its surface isn't initialized yet.
    case surfaceNotReady
    /// The session has no `.pr` link, so there's no PR to act on.
    case noPRLink
    /// The action modifies the code under review but the session is a **review**
    /// (reviewer) session — refused so the reviewer never commits to the branch
    /// under review, mirroring `shouldSkipReviewSession` on the manual path (#757).
    case forbiddenOnReviewSession

    public var isSent: Bool { self == .sent }

    /// User-facing reason a manual dispatch was skipped; `nil` when actually sent.
    public var skipReason: String? {
        switch self {
        case .sent:                     return nil
        case .noManagedTerminal:        return "no active agent terminal for this session"
        case .surfaceNotReady:          return "the agent terminal isn't ready yet"
        case .noPRLink:                 return "this session has no linked PR"
        case .forbiddenOnReviewSession: return "a reviewer can't modify the branch under review — use Re-review instead"
        }
    }
}
