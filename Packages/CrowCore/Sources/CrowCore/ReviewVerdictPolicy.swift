import Foundation

/// A `crow-review-pr` finding severity (CROW-963).
///
/// The taxonomy is fixed at three levels. Which of them *gate the verdict* is
/// per-workspace configuration (``WorkspaceInfo/reviewBlockingSeverities``);
/// renaming a level or adding a fourth is deliberately out of scope, because the
/// skill's required output format and grading guidance both assume exactly these.
public enum ReviewSeverity: String, Codable, Sendable, CaseIterable {
    case red
    case yellow
    case green

    /// Crow's built-in blocking set — the rule every install had before CROW-963,
    /// and what an unset ``WorkspaceInfo/reviewBlockingSeverities`` still means.
    ///
    /// Absent must resolve here and **not** to "nothing blocks": an install that
    /// never touches the setting has to see today's behaviour exactly.
    public static let defaultBlocking: [ReviewSeverity] = [.red, .yellow]

    /// Declaration order — severest first. Used to canonicalize a stored or
    /// user-supplied list so `[yellow, red]` and `[red, yellow]` render the same
    /// prose (and compare equal to ``defaultBlocking``).
    public static func canonicalize(_ severities: [ReviewSeverity]) -> [ReviewSeverity] {
        allCases.filter(severities.contains)
    }

    /// Capitalized label as it appears in the skill body.
    public var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

/// Renders a workspace's review-verdict policy into the bundled `crow-review-pr`
/// SKILL body (CROW-963).
///
/// The skill carries three placeholders — the Step 5 verdict rule, the grading
/// guidance that bounds the severity a finding may be assigned, and the two
/// reinforcing bullets under Important Notes. All must agree, or the agent is
/// handed a brief that contradicts itself.
///
/// CROW-1511 dropped the fourth, the static `### Summary Table` legend
/// (`{{CROW_REVIEW_VERDICT_TABLE}}`): it repeated the verdict rule in every
/// posted review. The body's `**Recommendation:**` line, with its Red / Yellow /
/// Green counts, still carries the verdict, and Step 5a still checks it.
///
/// **Advisory, not enforcement.** The review agent invokes `gh pr review` itself;
/// Crow never sees the call and cannot check the posted verdict against the
/// policy it handed over. This type configures a *prompt*.
///
/// **Non-blocking findings are still reported.** Only the verdict changes — a
/// severity that stops gating still gets written into the review body. Losing the
/// finding entirely would be worse than the over-strictness this setting relaxes.
public enum ReviewVerdictPolicy {

    // MARK: - Placeholders

    public static let rulePlaceholder = "{{CROW_REVIEW_VERDICT_RULE}}"
    public static let gradingGuidancePlaceholder = "{{CROW_REVIEW_GRADING_GUIDANCE}}"
    public static let notesPlaceholder = "{{CROW_REVIEW_VERDICT_NOTES}}"

    // MARK: - Expansion

    /// Substitute the three verdict placeholders for `blocking`.
    ///
    /// Idempotent: a body with no placeholders left (already expanded, or the
    /// test-environment stub from `Scaffolder.bundledReviewSkill()`) passes
    /// through unchanged. That is what lets the review path pre-expand once
    /// before its launch paths diverge and still route through
    /// `CrowAttribution.expandSkillBody`, which expands again with the default.
    /// The grading-guidance block is policy-independent, so its second pass is a
    /// no-op regardless of which set the re-expansion uses.
    public static func expand(_ body: String, blocking: [ReviewSeverity]) -> String {
        let canonical = ReviewSeverity.canonicalize(blocking)
        return body
            .replacingOccurrences(of: rulePlaceholder, with: ruleBlock(blocking: canonical))
            .replacingOccurrences(of: gradingGuidancePlaceholder, with: gradingGuidanceBlock)
            .replacingOccurrences(of: notesPlaceholder, with: notesBullets(blocking: canonical))
    }

    // MARK: - Rendered blocks

    /// The Step 5 verdict rule.
    ///
    /// The default set returns ``defaultRuleBlock`` verbatim rather than being
    /// regenerated. That text is load-bearing — every install that never sets the
    /// field must receive byte-identical instructions — and it is not reproducible
    /// from a single join order anyway (its opening sentence reads
    /// `Yellow or Red` while the bullet below it reads `Red **or** Yellow`).
    /// Storing it beats contorting the generator to match a historical quirk.
    public static func ruleBlock(blocking: [ReviewSeverity]) -> String {
        let canonical = ReviewSeverity.canonicalize(blocking)
        guard canonical != ReviewSeverity.defaultBlocking else { return defaultRuleBlock }

        let blockingNames = joined(canonical, separator: " or ")
        let nonBlocking = ReviewSeverity.allCases.filter { !canonical.contains($0) }

        // Everything blocks: there is no advisory tier left to describe, and only
        // a review with no findings at all can approve.
        guard !nonBlocking.isEmpty else {
            return """
            Verdict rule — **only a review with no findings at all may approve**. Any finding forces `--request-changes`.

            - **Approve** (`--approve`): no findings of any severity.
            - **Request Changes** (`--request-changes`): any \(blockingNames) finding.

            Every severity gates the verdict in this workspace. Comment-only reviews remain forbidden; if uncertain, request changes.
            """
        }

        let nonBlockingNames = joined(nonBlocking, separator: " and ")
        return """
        Verdict rule — **only a review with no \(blockingNames) findings may approve**. Any \(blockingNames) finding forces `--request-changes`.

        - **Approve** (`--approve`): no \(blockingNames) findings. \(nonBlockingNames) findings do not gate the verdict.
        - **Request Changes** (`--request-changes`): any \(blockingNames) finding.

        This workspace treats \(nonBlockingNames) findings as advisory. Report every one of them in the review body exactly as you otherwise would — the policy changes only which findings gate the verdict, never which findings you report. Comment-only reviews remain forbidden; if uncertain, request changes.
        """
    }

    /// The two reinforcing bullets under Important Notes. Fully generated — the
    /// default set falls out of the same code path, byte-identical.
    public static func notesBullets(blocking: [ReviewSeverity]) -> String {
        let canonical = ReviewSeverity.canonicalize(blocking)
        let nonBlocking = ReviewSeverity.allCases.filter { !canonical.contains($0) }
        let blockingNames = joined(canonical, separator: " or ")
        let approveClause: String
        if nonBlocking.isEmpty {
            approveClause = "there are no findings at all"
        } else {
            let exclusions = canonical.map { "no \($0.displayName)" }.joined(separator: ", ")
            approveClause = "findings are entirely \(joined(nonBlocking, separator: " or ")) or empty (\(exclusions))"
        }
        return """
        - Use `--approve` only when \(approveClause).
        - Use `--request-changes` when there is any \(blockingNames) finding.
        """
    }

    // MARK: - Default text

    /// Crow's pre-CROW-963 verdict rule, verbatim. Pinned byte-for-byte by
    /// `ReviewVerdictPolicyTests`.
    public static let defaultRuleBlock = """
    Verdict rule — **only a review whose findings are entirely Green (or empty) may approve**. Any Yellow or Red finding forces `--request-changes`.

    - **Approve** (`--approve`): no Red, no Yellow, only Green or no findings.
    - **Request Changes** (`--request-changes`): any Red **or** any Yellow finding.

    Yellow findings are "should fix" — the implementing agent will address them as soon as it sees the request-changes verdict, so rejecting on Yellow lands them in the same round trip instead of a follow-up. Comment-only reviews remain forbidden; if uncertain, request changes.
    """

    /// Grading discipline (CROW-986, reworked by CROW-1511). Bounds the
    /// *severity a finding may be assigned* — a separate axis from which
    /// severities gate the verdict, so this text is constant and renders
    /// identically for every workspace policy.
    ///
    /// **The cross-tenant floor (CROW-1321) comes first.** In
    /// corveil/corveil#620 a reviewer wrote "Org A's keyword/regex rules apply to
    /// Org B's traffic", capped it at Green under the accepted-risk rule, and
    /// approved; the bug later blocked every tenant's gateway traffic
    /// (corveil/corveil#4191). The rules below it are right for a judgment call
    /// and wrong for a tenant boundary, so a cross-tenant finding is Red, each
    /// rule says it does not apply to it, and the only way it merges is the
    /// deferral bar — an open issue, a `DEFERRED(#N)` marker, and an ADR
    /// exception row, each checked by the reviewer. This is the generic form of
    /// corveil ADR 0093 invariant 10; repo-specific tenancy rules arrive through
    /// each repo's own `CLAUDE.md`.
    ///
    /// **Every other finding is graded by one principle: the consequence if the
    /// PR merges as-is.** CROW-1511 replaced the old "grade against the diff, not
    /// the roadmap" cap with it. The principle still carries the CROW-1062
    /// reconciliation: an *architectural* mismatch — a change that reinvents an
    /// existing pathway, misreads the current control flow, or assumes a
    /// behavior the codebase already has — is a defect in the shape of what is
    /// written, gradeable at Yellow/Red rather than waved through as a future
    /// refactor.
    ///
    /// **An accepted risk is still not a blocker** (CROW-986). The CROW-1511
    /// triage kept it on purpose; without it the verdict gate has no terminating
    /// condition when a finding is a risk the author has consciously documented.
    ///
    /// **A declined finding is judged on its merits** (CROW-1511). The old rule
    /// capped any finding the author "answered with a rationale" at Green, and
    /// the implementer prompt told the agent to reply instead of changing code
    /// when it disagreed, so one reply waived a real defect: the CROW-1511 audit
    /// found approvals citing the rule for an unscoped existence check, a
    /// destructive data loss, and waived "Done when" items. The reviewer now
    /// evaluates the reply. What keeps the loop terminating is the two-round
    /// hand-off to a human (`crow:needs-human`), not a cap.
    public static let gradingGuidanceBlock = """
    Grading discipline — the rules below bound the **severity you may assign** to a finding. They hold no matter which severities gate the verdict above, because they are about how to grade, not about what blocks.

    The cross-tenant floor comes first. It sets a minimum grade, and none of the rules after it can lower it:

    - **Cross-tenant effect or exposure is always Red.** A tenant is whatever the repo isolates customers by — an org, workspace, account or team. *Cross-tenant effect* means one tenant's config or data changes another tenant's requests, responses, records, limits, availability or costs. *Cross-tenant exposure* means one tenant can read another tenant's config or data, directly or through an error, a log line, a listing or a count. A finding of either is **Red** — never Yellow, never Green. The consequence, accepted-risk and declined-finding rules below **do not apply** to it: a PR that documents the hazard, calls it defense-in-depth or lower priority, or defers it in prose has not accepted the risk, and an author's reply declining the finding does not lower it. The only way such a finding merges is the deferral bar.
    - **Deferral bar.** A cross-tenant finding may merge as deferred only when all of these exist, and you have checked each one yourself rather than taking the PR's word for it:
      - an **open** tracking issue — check with `gh issue view <N> --json state`; an issue this PR closes does not count;
      - a `// DEFERRED(#N):` marker at the site, naming that issue (in the file's own comment syntax);
      - a row for the site in the exceptions table of the repo's tenant-isolation ADR, where the repo has one.

      When every one holds, list the finding in the review body's Tenant effect section as **Deferred (#N)** with what you checked; it does not gate the verdict. When any one is missing, the finding stays **Red**.
    - **Tenant effect checklist.** When the diff touches tenant-scoped code — rows keyed by a tenant id, process-wide state (caches, registries, package-level variables) built from such rows, a function that takes a tenant argument, or access scoping — the review body's `### Tenant effect` section answers these four questions, each with `file:line` or test evidence:
      1. Which org's requests consult this state?
      2. Can org A's row change org B's outcome?
      3. Is any org argument dropped, Nil, or optional?
      4. Does a test pin cross-org behavior?

      A "yes" to question 2 is a cross-tenant finding. So is a "yes" to question 3, unless you cite the code that rejects the missing org or fails closed. In a repo with no tenancy, or a diff that touches no tenant-scoped code, the section is the single line `n/a — <why>`, without the four questions. A repo's own tenancy rules (its `CLAUDE.md`, a tenant-isolation ADR) apply on top of this floor: they can add to it, never lower it.

    The three rules below grade every other finding. A cross-tenant finding is exempt from all three:

    - **Grade by the consequence if this merges as-is.** Ask what goes wrong if the PR merges exactly as written, and grade that, not how confident or polite the PR is, and not what the author intends to do later. **Red**: merging breaks something — wrong results, lost or corrupted data, a security hole, a crash, an outage — unless the finding is cross-tenant, which is **Red** under the floor above whatever this rule suggests. **Yellow**: it works on the main path, but what is written has a real defect — a missed edge case, an error swallowed, new behavior with no test, a "Done when" item of the ticket it closes left unmet, or the wrong shape for this codebase. The wrong shape is a defect in what is written: a change that reinvents a pathway the codebase already has, misreads the current control flow, or assumes a behavior the system already provides may be graded **Yellow** or **Red**, not waved through as a future refactor. **Green**: nothing goes wrong if it merges — a style point, a clearer name, an improvement you would like to see later — and never a cross-tenant finding. Grade the code that is written, not the roadmap; study the surrounding architecture before you decide whether a mismatch is a defect or a future improvement.
    - **An accepted risk is not a blocker.** A hazard the PR explicitly documents and consciously accepts is at most **Green** — except a cross-tenant finding, which stays **Red** under the floor above. When the diff is correct and the only disagreement is whether to accept a risk the author has already called out, and that risk is not cross-tenant, the acceptance is the author's decision to make — state your view in the body and let the verdict follow the grade, rather than blocking on it. A cross-tenant risk is never the author's to accept: it stays **Red**, and the verdict follows the floor.
    - **Judge a declined finding on its merits.** When the author answers a finding you raised in an earlier round with a reply instead of a code change, the reply is an argument, not a waiver: check it against the code. If it holds — it cites code, a test or a spec that shows the finding is wrong or does not apply — drop the finding or lower its grade and say in the body why it holds, unless it is a cross-tenant finding, which stays **Red** whatever the reply says until it is fixed or clears the deferral bar. If the reply does not hold, keep the grade and say why not, with `file:line` or test evidence. A preference, a restatement of the design, or a promised follow-up is not evidence and does not change the grade. After **two** rounds of disagreement on the same finding (you kept it, the author declined it again), stop re-blocking it on your own judgment — unless it is a cross-tenant finding, which is restated at **Red** every round until it is fixed or clears the deferral bar, because a follow-up issue on its own is not a deferral. To hand a finding that is not cross-tenant to a human: list it under **Needs a human** in the review body with each side's case in one line, add the `crow:needs-human` label (Step 5d), and take it out of the verdict by recording it as **Green (needs a human)** — the label, not your verdict, now holds it for a human.
    """


    // MARK: - Helpers

    /// `[red]` → `Red`; `[red, yellow]` → `Red or Yellow`; `[red, yellow, green]`
    /// → `Red, Yellow or Green`. No serial comma, matching the skill's prose.
    private static func joined(_ severities: [ReviewSeverity], separator: String) -> String {
        let names = severities.map(\.displayName)
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + separator + last
    }
}
