import Foundation

/// The `corveil/corveil` label-gated CI convention Crow has to drive and read
/// (ADR 0082, CROW-3716).
///
/// On `corveil/corveil` the whole `test.yml` suite is gated behind a persistent
/// `ci:full` label, and the single merge-blocking required check is one
/// always-running, **fail-closed** `CI Gate` context. When `ci:full` is absent
/// the six worker jobs skip and `CI Gate` reports red **on purpose** — that red
/// means "CI has not run yet", not a real failure. So Crow must:
///
///  1. add `ci:full` alongside `crow:merge` when it labels a PR for merge, or
///     the suite never runs and the fail-closed gate keeps the PR red forever;
///  2. never strip `ci:full` on auto-rebase (the strict up-to-date policy needs
///     the suite to re-run on the rebased tip, which only happens while the
///     label is present);
///  3. treat `CI Gate` like any other required check in the auto-merge watcher —
///     wait for it to go green rather than merging early or bailing; and
///  4. **not** chase a `CI Gate` red that is the expected pre-approval /
///     in-flight state (decision 5 of the ADR).
///
/// This convention is deliberately **self-gating on the check name**: nothing
/// here fires unless a PR actually carries a check context named exactly
/// `CI Gate`, so repos without the convention (the crow repo's own CI, every
/// other workspace) are untouched — no repo hardcoding required.
public enum CIGateConvention {
    /// The single fail-closed aggregate required check on `corveil/corveil`
    /// (ADR 0082 decision 2). Its presence on a PR is how Crow detects the
    /// label-gated-CI convention without keying off the repository name.
    public static let checkName = "CI Gate"

    /// The persistent label that makes the `test.yml` suite run (ADR 0082
    /// decision 1). Dedicated on purpose — *not* `crow:merge`: "run the full
    /// suite" and "merge this PR" are distinct intents and must be separately
    /// expressible.
    public static let fullSuiteLabel = "ci:full"

    /// Whether `labels` carries the `ci:full` label (case-insensitive, matching
    /// how `crow:merge` is matched elsewhere).
    public static func hasFullSuiteLabel(_ labels: [LabelInfo]) -> Bool {
        labels.contains { $0.name.caseInsensitiveCompare(fullSuiteLabel) == .orderedSame }
    }

    /// Filter an **expected** (non-actionable) `CI Gate` red out of the raw
    /// failing-check names, so Crow neither reports it as a regression nor
    /// chases it with respond-to-failed-checks (ADR 0082 decision 5).
    ///
    /// A `CI Gate` red is a **real, actionable** failure only when all three
    /// hold — otherwise it is the fail-closed "CI not run" / in-flight state and
    /// the name is dropped:
    ///
    ///  - `ciFullPresent` — the suite was actually requested. Absent ⇒ the red
    ///    is the pre-approval fail-closed state (expected; the PR is blocked by
    ///    the missing approval anyway).
    ///  - `!anyCheckPending` — the run has settled. A pending/in-progress check
    ///    means the post-label suite is still in flight, and its `CI Gate` has
    ///    not posted its real conclusion yet (the in-flight window). Acting now
    ///    would `synchronize` the PR and `cancel-in-progress` the very run about
    ///    to go green — the exact loop the ADR warns against.
    ///  - a **non-`CI Gate`** check is itself failing — `CI Gate` is only the
    ///    aggregate of the gated jobs, so a genuine failure shows up as one of
    ///    those jobs' own red. If every other check is green/skipped, a lone
    ///    `CI Gate` red is a stale conclusion from an earlier run (e.g. the
    ///    brief window after the workers finish but before the post-label gate
    ///    is recreated), not a real failure.
    ///
    /// When `rawFailed` contains no `CI Gate` entry this is a no-op that returns
    /// the input unchanged — which is every repo without the convention.
    public static func actionableFailedChecks(
        rawFailed: [String],
        ciFullPresent: Bool,
        anyCheckPending: Bool
    ) -> [String] {
        guard rawFailed.contains(checkName) else { return rawFailed }
        let others = rawFailed.filter { $0 != checkName }
        let ciGateIsRealFailure = ciFullPresent && !anyCheckPending && !others.isEmpty
        return ciGateIsRealFailure ? rawFailed : others
    }
}
