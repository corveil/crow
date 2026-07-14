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

    public var isSent: Bool { self == .sent }

    /// User-facing reason a manual dispatch was skipped; `nil` when actually sent.
    public var skipReason: String? {
        switch self {
        case .sent:              return nil
        case .noManagedTerminal: return "no active agent terminal for this session"
        case .surfaceNotReady:   return "the agent terminal isn't ready yet"
        case .noPRLink:          return "this session has no linked PR"
        }
    }
}
