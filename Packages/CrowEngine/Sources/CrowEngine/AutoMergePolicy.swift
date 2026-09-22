import Foundation
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider

// MARK: - Auto-merge eligibility policy (CROW-1286)
//
// Pure eligibility policy for the auto-merge watcher, split out of
// `AutoMergeController` so a policy change (the skip-reason vocabulary, the
// direct-merge gates, the `BEHIND` update-branch predicate, the authorship and
// retry helpers) reviews apart from the poll loop and the three irreversible
// attempt paths. Everything here is `nonisolated static` — no state, no side
// effects. Declared on `AutoMergeController` so the nested-type spellings
// (`AutoMergeController.AutoMergeSkipReason` / `.AutoMergeOutcome`) and the
// `@testable` / `IssueTracker.*` facade call sites stay put.
extension AutoMergeController {
    nonisolated static func shouldAttemptAutoMerge(pr: ViewerPR, session: Session) -> Bool {
        autoMergeSkipReason(pr: pr, session: session) == nil
    }

    /// Why `pr` is not an auto-merge candidate, or `nil` when it is one.
    ///
    /// The reason exists so a skip leaves a trace: `shouldAttemptAutoMerge`
    /// used to collapse six distinct guards into a bare `false`, which is why
    /// "why wasn't this PR merged?" was unanswerable after the fact (CROW-782).
    /// `applyAutoMerge` logs the reason per PR each poll; the boolean helper
    /// above is derived from this one so the two can never disagree.
    ///
    /// Raw values are the strings that land in the automation log — keep them
    /// stable enough to grep for. The first six are the pure eligibility
    /// guards `autoMergeSkipReason` evaluates; the rest are runtime outcomes
    /// that used to live as bare string literals scattered across
    /// `applyAutoMerge` and `attemptEnableAutoMerge`. Folding them into one
    /// type is what lets a reason carry a human sentence and a permanence flag
    /// to the UI instead of dying in the log file (#888).
    enum AutoMergeSkipReason: String, Sendable {
        case alreadyEnabled = "already-enabled"
        case notOpen = "not-open"
        case draft = "draft"
        case noMergeLabel = "no-crow-merge-label"
        case conflicting = "conflicting"
        case changesRequested = "changes-requested"
        case inFlight = "in-flight"
        case notInViewerPRs = "not-in-viewer-prs"
        case updateBranchAlreadyAttempted = "update-branch-already-attempted-for-head"
        case noCrowSessionTrailer = "no-crow-session-trailer"
        case backendLacksAutoMerge = "backend-lacks-auto-merge-capability"
        case repoDisallowsAutoMerge = "repo-disallows-auto-merge"
        /// The repo forbids the host's auto-merge queue, so `--auto` can never
        /// succeed — but the PR isn't green enough for the direct-merge
        /// fallback *yet*. Transient by design: labels are usually applied
        /// while CI is still running, and latching here would freeze the PR
        /// before it could ever qualify. New with #888.
        case repoDisallowsAutoMergePending = "repo-disallows-auto-merge-not-yet-mergeable"
        /// The PR asks for auto-merge but the watcher itself is switched off, so
        /// nothing will ever look at it. New with #888: `applyAutoMerge`'s first
        /// guard returns before any per-PR bookkeeping, so this state was
        /// previously invisible except as one hourly global log line.
        case watcherOff = "watcher-off"
        /// The repo forbids the host's auto-merge queue and Crow's direct-merge
        /// fallback also failed. New with #888.
        case directMergeFailed = "direct-merge-failed"

        /// Whether retrying could change the outcome. Drives whether the UI
        /// warns loudly and whether a notification fires at all.
        var isPermanent: Bool {
            switch self {
            case .noCrowSessionTrailer, .backendLacksAutoMerge,
                 .repoDisallowsAutoMerge, .directMergeFailed:
                true
            case .alreadyEnabled, .notOpen, .draft, .noMergeLabel, .conflicting,
                 .changesRequested, .inFlight, .notInViewerPRs,
                 .updateBranchAlreadyAttempted, .watcherOff, .repoDisallowsAutoMergePending:
                false
            }
        }

        /// The verdict to publish for the UI, or `nil` to stay quiet.
        ///
        /// Deliberately silent for everything the PR pill *already* renders —
        /// a conflicting PR draws the conflict chip, a CHANGES_REQUESTED one
        /// draws a red review chip, an unlabeled one simply has no 🏷. Adding
        /// a second chip saying the same thing would be the exact "two surfaces
        /// disagreeing" failure CROW-773 consolidated the vocabulary to avoid.
        /// What's published is only what nothing else on screen can tell you.
        func state(repo: String) -> AutoMergeState? {
            switch self {
            case .notOpen, .draft, .noMergeLabel, .conflicting, .changesRequested:
                return nil
            case .alreadyEnabled:
                return AutoMergeState(
                    phase: .enabled, reason: rawValue,
                    message: "Auto-merge is enabled. GitHub will merge this PR once required "
                        + "reviews and checks pass.",
                    permanent: false)
            case .watcherOff:
                return AutoMergeState(
                    phase: .off, reason: rawValue,
                    message: "This PR is labeled crow:merge, but the auto-merge watcher is off, "
                        + "so nothing will merge it. Turn it on in Settings → Automation.",
                    permanent: false)
            case .inFlight:
                return AutoMergeState(
                    phase: .stalled, reason: rawValue,
                    message: "Crow is working on this PR's auto-merge right now.",
                    permanent: false)
            case .notInViewerPRs:
                return AutoMergeState(
                    phase: .stalled, reason: rawValue,
                    message: "This PR didn't appear in the last provider fetch, so Crow can't "
                        + "evaluate it. Usually a scope or rate-limit problem, not the PR itself.",
                    permanent: false)
            case .updateBranchAlreadyAttempted:
                return AutoMergeState(
                    phase: .stalled, reason: rawValue,
                    message: "Crow already tried to update this branch from its base at the "
                        + "current commit. It will re-evaluate once the branch moves.",
                    permanent: false)
            case .noCrowSessionTrailer:
                return AutoMergeState(
                    phase: .blocked, reason: rawValue,
                    message: "No commit on this PR carries a Crow-Session trailer matching a "
                        + "known session, so Crow won't merge it.",
                    permanent: true)
            case .backendLacksAutoMerge:
                return AutoMergeState(
                    phase: .blocked, reason: rawValue,
                    message: "This session's provider backend can't enable auto-merge.",
                    permanent: true)
            case .repoDisallowsAutoMergePending:
                return AutoMergeState(
                    phase: .stalled, reason: rawValue,
                    message: "\(repo.isEmpty ? "This repository" : repo) has GitHub's "
                        + "\"Allow auto-merge\" setting turned off, so Crow will merge this PR "
                        + "itself once checks pass and it's approved.",
                    permanent: false)
            case .repoDisallowsAutoMerge:
                return AutoMergeState(
                    phase: .blocked, reason: rawValue,
                    message: "\(repo.isEmpty ? "This repository" : repo) has GitHub's "
                        + "\"Allow auto-merge\" setting turned off, and the PR isn't in a state "
                        + "Crow can safely merge directly. Enable it in the repo's "
                        + "Settings → General, or merge by hand.",
                    permanent: true)
            case .directMergeFailed:
                return AutoMergeState(
                    phase: .blocked, reason: rawValue,
                    message: "\(repo.isEmpty ? "This repository" : repo) forbids GitHub "
                        + "auto-merge and Crow's direct merge failed. Check the PR on GitHub — "
                        + "Crow will not retry.",
                    permanent: true)
            }
        }
    }

    nonisolated static func autoMergeSkipReason(pr: ViewerPR, session: Session) -> AutoMergeSkipReason? {
        guard session.autoMergeEnabledAt == nil else { return .alreadyEnabled }
        guard pr.state == "OPEN" else { return .notOpen }
        guard !pr.isDraft else { return .draft }
        guard pr.labels.contains(where: { $0.name.caseInsensitiveCompare(autoMergeLabel) == .orderedSame }) else { return .noMergeLabel }
        guard pr.mergeable != "CONFLICTING" else { return .conflicting }
        guard pr.reviewDecision != "CHANGES_REQUESTED" else { return .changesRequested }
        return nil
    }

    /// Whether `pr` carries the `crow:merge` label. Split out of
    /// `autoMergeSkipReason` so the watcher-off path can tell "the user asked
    /// for auto-merge and nothing is listening" apart from "this PR was never
    /// labeled", without re-running the whole guard chain (#888).
    nonisolated static func hasAutoMergeLabel(pr: ViewerPR) -> Bool {
        pr.labels.contains { $0.name.caseInsensitiveCompare(autoMergeLabel) == .orderedSame }
    }

    /// True when `gh pr merge --auto` failed for a permanent repo/policy
    /// reason that will not clear on retry — specifically when the repo has
    /// GitHub "Allow auto-merge" disabled. Keyed on the policy phrase only:
    /// `gh` embeds the GraphQL mutation name `enablePullRequestAutoMerge` in
    /// *every* error from that mutation (including transient ones like
    /// "Pull request is in clean status"), so matching the bare field name
    /// would freeze retryable cases for the process lifetime (CROW-621).
    nonisolated static func isPermanentAutoMergeFailure(_ error: Error) -> Bool {
        let message: String
        if case ShellRunnerError.nonZeroExit(_, let output) = error {
            message = output
        } else {
            message = error.localizedDescription
        }
        return message.localizedCaseInsensitiveContains("Auto merge is not allowed for this repository")
    }

    /// The green-state gates a PR must clear before Crow will merge it *itself*.
    ///
    /// `shouldAttemptAutoMerge` is a much weaker bar on purpose: that path hands
    /// GitHub a queued request and lets GitHub enforce required checks and
    /// reviews before anything lands. A direct merge has no such backstop — it
    /// merges now — so every gate GitHub would have applied has to be re-checked
    /// here (#888).
    ///
    /// `mergeStateStatus == "CLEAN"` is GitHub's own "the merge button is
    /// green", which already excludes `BLOCKED`, `UNSTABLE`, `BEHIND`,
    /// `HAS_HOOKS` and `DIRTY`. The other three gates are deliberate belt and
    /// braces: this predicate is the only thing standing between a labeled PR
    /// and an irreversible merge, so it re-states rather than infers.
    ///
    /// Known narrowing: a repo with no required reviewers reports
    /// `reviewDecision == ""`, so the fallback stays out of its way entirely.
    /// Refusing to merge something a human never approved is the right side to
    /// err on.
    nonisolated static func directMergeGatesPass(pr: ViewerPR, session: Session) -> Bool {
        guard shouldAttemptAutoMerge(pr: pr, session: session) else { return false }
        guard pr.mergeStateStatus == "CLEAN" else { return false }
        guard pr.mergeable == "MERGEABLE" else { return false }
        guard pr.checksState == "SUCCESS" else { return false }
        guard pr.reviewDecision == "APPROVED" else { return false }
        return true
    }

    /// Whether Crow should merge `pr` directly instead of enabling auto-merge,
    /// because the repo has GitHub's "Allow auto-merge" setting off.
    ///
    /// Gated on an *explicit* `false`: `repoAutoMergeAllowed` is `nil` whenever
    /// the field wasn't fetched (GitLab, a partial SAML recovery, a cached
    /// record from before #888), and treating unknown as "forbidden" would turn
    /// every such PR into a direct merge — precisely the blast radius this
    /// feature must not have.
    nonisolated static func shouldDirectMerge(pr: ViewerPR, session: Session) -> Bool {
        guard pr.repoAutoMergeAllowed == false else { return false }
        return directMergeGatesPass(pr: pr, session: session)
    }

    /// Decide whether a merge candidate should have its branch updated from
    /// base *before* merging. True only when the PR is otherwise mergeable
    /// (`shouldAttemptAutoMerge`) but GitHub reports it `BEHIND` its base —
    /// the "out-of-date with the base branch" state that makes `gh pr merge`
    /// fail with HTTP 422. Real conflicts never qualify: `CONFLICTING` is
    /// already gated by `shouldAttemptAutoMerge`, and `DIRTY` is not `BEHIND`.
    nonisolated static func shouldUpdateBranchBeforeMerge(pr: ViewerPR, session: Session) -> Bool {
        guard shouldAttemptAutoMerge(pr: pr, session: session) else { return false }
        return pr.mergeStateStatus == "BEHIND"
    }

    /// Return true when at least one of the supplied commit messages
    /// carries a `Crow-Session: <uuid>` trailer whose UUID matches a
    /// session in `knownSessionIDs`. Trailer-with-unknown-session is
    /// treated as NOT Crow-authored (acceptance criterion #4).
    nonisolated static func crowAuthored(commitMessages: [String], knownSessionIDs: Set<UUID>) -> Bool {
        for message in commitMessages {
            for uuid in PRAttributionRecorder.extractCrowSessionUUIDs(from: message) {
                if knownSessionIDs.contains(uuid) { return true }
            }
        }
        return false
    }

    /// Max consecutive failed `gh pr update-branch` calls per head state before
    /// the watcher gives up until the head commit changes.
    nonisolated static let maxAutoUpdateBranchFailureRetries = 3

    /// Whether a failed `updateBranch` should be retried on the next poll.
    /// Pure so the policy is unit-testable, matching `shouldRetryFailedRebase`.
    nonisolated static func shouldRetryFailedUpdateBranch(failureCount: Int) -> Bool {
        failureCount < maxAutoUpdateBranchFailureRetries
    }

    /// What one session's auto-merge evaluation did. Returned by
    /// ``evaluateAutoMerge(session:byURL:)`` so the per-poll caller can keep its
    /// aggregate summary line without the loop body reaching into the caller's
    /// counters — the single-session caller has no counters at all.
    struct AutoMergeOutcome {
        enum Dispatch: String { case none, enable, updateBranch, directMerge }
        var dispatch: Dispatch = .none
        /// Pre-formatted `<key>:<reason>` token for the per-poll summary line.
        /// `nil` when the session was never a candidate (no `.pr` link) — that
        /// is not a skip, it's a session the watcher doesn't speak about.
        var skip: String?
    }
}
