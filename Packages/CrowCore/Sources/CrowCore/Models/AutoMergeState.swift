import Foundation

/// What Crow's auto-merge watcher concluded about one session's PR on the most
/// recent poll.
///
/// Before #888 this verdict existed only as a line in
/// `~/Library/Logs/crow/crowd-automation.log`. A user who applied `crow:merge`
/// and watched nothing happen had no in-app way to tell "queued, waiting on
/// GitHub" from "permanently gave up an hour ago" — the sidebar rendered both
/// identically. This type is the verdict made publishable: `reason` is the same
/// grep-stable token the log carries, and `message` is the sentence a UI can
/// render verbatim.
///
/// Deliberately NOT a field on `PRStatus`. `PRStatus` mirrors what the *forge*
/// says about a pull request; this is what *Crow* decided about it, and the two
/// have different lifetimes — a PR missing from the viewer fetch has no
/// `PRStatus` at all, yet that absence is itself a verdict worth showing.
public struct AutoMergeState: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// Crow called `enableAutoMerge` and the host accepted; the merge is
        /// queued behind the host's own checks/reviews gate. Nothing is wrong —
        /// but "waiting on GitHub" and "blocked" must not look the same.
        case enabled
        /// Crow merged the PR itself, because the repo forbids the host's
        /// auto-merge queue and the PR was verifiably green (#888).
        case merged
        /// Crow has stopped trying and a later poll will not change that. Needs
        /// a human: flip a repo setting, add the Crow trailer, switch backends.
        case blocked
        /// Not a candidate right now, but a later poll may well make it one.
        case stalled
        /// The PR carries `crow:merge` but the watcher itself is switched off,
        /// so nothing will ever look at it. Distinct from `blocked`: the fix is
        /// one toggle, and the user chose this state.
        case off
    }

    public var phase: Phase
    /// Stable machine token, identical to the string in the automation log.
    public var reason: String
    /// One human-readable sentence, terminal-punctuated, safe to render as-is.
    public var message: String
    /// Whether retrying could change the outcome. Drives whether a client warns
    /// loudly (permanent) or merely notes a wait (transient).
    public var permanent: Bool

    public init(phase: Phase, reason: String, message: String, permanent: Bool) {
        self.phase = phase
        self.reason = reason
        self.message = message
        self.permanent = permanent
    }
}
