import Foundation

/// What Crow's auto-rebase watcher concluded about one session's branch on the
/// most recent attempt.
///
/// The auto-rebase twin of ``AutoMergeState``, added by #944 for a sharper
/// reason than auto-merge had: `PRStatus` — and therefore the PR pill — never
/// carries `mergeStateStatus` at all. A branch wedged in
/// `deferred:out-of-sync-diverged` renders as a *fully green* PR, and the only
/// trace of it is a line in `~/Library/Logs/crow/crowd-automation.log` that
/// repeats every 15 minutes forever. `reason` is that log line's grep-stable
/// token; `message` is the sentence a UI can render verbatim.
///
/// Deliberately NOT a field on `PRStatus`, for the same reason `AutoMergeState`
/// isn't: `PRStatus` mirrors what the *forge* says about a pull request, and
/// this is what *Crow* decided about it.
///
/// **Silence is the default, and it means "fine".** Unlike auto-merge, no PR
/// opts into auto-rebase — there is no `crow:merge` equivalent — so there is no
/// `enabled` phase and no `off` phase. An `off` chip would appear on every
/// not-yet-current PR the moment someone flipped the toggle, vocabulary those
/// PRs never asked for. A published state here only ever means "Crow tried and
/// couldn't".
public struct AutoRebaseState: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// The attempt deferred and a later poll will retry it on a backoff.
        /// Usually nothing is wrong — an agent mid-edit is the common case —
        /// but "waiting to retry" and "wedged" must not look the same, and the
        /// PR pill can't tell them apart because it never renders BEHIND.
        case stalled
        /// Retrying alone will not change the outcome: either the failure cap
        /// is exhausted (nothing further until the head commit moves), or the
        /// deferral backoff has saturated and Crow is asking the same question
        /// every 15 minutes and getting the same answer. Needs a human —
        /// commit or stash the worktree, push or drop the local commits,
        /// reconcile the divergence.
        case blocked
    }

    public var phase: Phase
    /// Stable machine token, identical to the string in the automation log.
    public var reason: String
    /// One human-readable sentence, terminal-punctuated, safe to render as-is.
    public var message: String
    /// Whether retrying could change the outcome. Always equal to
    /// `phase == .blocked` here, but kept as its own field so the wire shape
    /// matches `AutoMergeState` byte for byte and the web can share one
    /// renderer between the two watchers.
    public var permanent: Bool

    public init(phase: Phase, reason: String, message: String, permanent: Bool) {
        self.phase = phase
        self.reason = reason
        self.message = message
        self.permanent = permanent
    }
}
