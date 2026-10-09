import Foundation
import Testing
@testable import CrowCore

/// CROW-963: the per-workspace review verdict severity policy.
///
/// The load-bearing property is the first test in this file: an install that
/// never sets `reviewBlockingSeverities` must receive **byte-identical**
/// instructions to the ones Crow shipped before the setting existed. The golden
/// strings below are the pre-change `skills/crow-review-pr/SKILL.md` text
/// verbatim. If a future edit rewords the default policy, this suite fails — and
/// it should, because that reword changes the verdict behaviour of every install
/// that never opted in.
@Suite("Review verdict policy")
struct ReviewVerdictPolicyTests {

    // MARK: - Golden default text (pre-CROW-963 SKILL.md, verbatim)

    private static let goldenRule = """
    Verdict rule — **only a review whose findings are entirely Green (or empty) may approve**. Any Yellow or Red finding forces `--request-changes`.

    - **Approve** (`--approve`): no Red, no Yellow, only Green or no findings.
    - **Request Changes** (`--request-changes`): any Red **or** any Yellow finding.

    Yellow findings are "should fix" — the implementing agent will address them as soon as it sees the request-changes verdict, so rejecting on Yellow lands them in the same round trip instead of a follow-up. Comment-only reviews remain forbidden; if uncertain, request changes.
    """

    private static let goldenTable = """
    | Red    | Must fix     | Request changes           |
    | Yellow | Should fix   | Request changes           |
    | Green  | Consider     | Approve allowed           |
    """

    private static let goldenNotes = """
    - Use `--approve` only when findings are entirely Green or empty (no Red, no Yellow).
    - Use `--request-changes` when there is any Red or Yellow finding.
    """

    // MARK: - Default preservation

    @Test func defaultPolicyRendersTodaysExactVerdictRule() {
        #expect(ReviewVerdictPolicy.ruleBlock(blocking: ReviewSeverity.defaultBlocking) == Self.goldenRule)
    }

    @Test func defaultPolicyRendersTodaysExactSummaryTable() {
        #expect(ReviewVerdictPolicy.tableRows(blocking: ReviewSeverity.defaultBlocking) == Self.goldenTable)
    }

    @Test func defaultPolicyRendersTodaysExactImportantNotes() {
        #expect(ReviewVerdictPolicy.notesBullets(blocking: ReviewSeverity.defaultBlocking) == Self.goldenNotes)
    }

    /// The table's three columns are 6 / 12 / 26 wide in the checked-in skill.
    /// A policy that changed a row's width would leave the rendered markdown
    /// table ragged against its static header and separator.
    @Test func everyPolicyRendersRowsAtTheCheckedInColumnWidth() {
        for blocking in [[ReviewSeverity.red], ReviewSeverity.defaultBlocking, ReviewSeverity.allCases] {
            for row in ReviewVerdictPolicy.tableRows(blocking: blocking).split(separator: "\n") {
                #expect(row.count == 53, "row \(row) is \(row.count) chars, expected 53")
            }
        }
    }

    // MARK: - Non-default policies

    @Test func redOnlyPolicyDiffersFromTheDefaultInEveryBlock() {
        let redOnly = [ReviewSeverity.red]
        #expect(ReviewVerdictPolicy.ruleBlock(blocking: redOnly) != Self.goldenRule)
        #expect(ReviewVerdictPolicy.tableRows(blocking: redOnly) != Self.goldenTable)
        #expect(ReviewVerdictPolicy.notesBullets(blocking: redOnly) != Self.goldenNotes)
    }

    /// The whole point of the setting: Yellow stops gating the verdict. It must
    /// read `Approve allowed`, and Red must be untouched.
    @Test func redOnlyPolicyReleasesYellowButNotRed() {
        let rows = ReviewVerdictPolicy.tableRows(blocking: [.red])
        #expect(rows.contains("| Red    | Must fix     | Request changes           |"))
        #expect(rows.contains("| Yellow | Should fix   | Approve allowed           |"))
        #expect(rows.contains("| Green  | Consider     | Approve allowed           |"))
    }

    /// Q4 of the ticket: a finding that stops gating the verdict must still be
    /// reported. Losing it entirely would be worse than the over-strictness the
    /// setting relaxes, so the relaxed prose says so explicitly.
    @Test func nonDefaultPolicyStillInstructsTheAgentToReportEveryFinding() {
        let rule = ReviewVerdictPolicy.ruleBlock(blocking: [.red])
        #expect(rule.contains("Report every one of them in the review body"))
        #expect(rule.contains("never which findings you report"))
    }

    @Test func notesBulletsNameOnlyTheBlockingSeverities() {
        let notes = ReviewVerdictPolicy.notesBullets(blocking: [.red])
        #expect(notes.contains("- Use `--request-changes` when there is any Red finding."))
        #expect(notes.contains("no Red"))
        #expect(!notes.contains("no Yellow"))
    }

    /// Blocking everything is legal (if unusual): only an empty review approves.
    /// There is no advisory tier left, so the prose must not dangle one.
    @Test func blockingEverySeverityLeavesNoAdvisoryTier() {
        let rule = ReviewVerdictPolicy.ruleBlock(blocking: ReviewSeverity.allCases)
        #expect(rule.contains("no findings at all"))
        #expect(!rule.contains("advisory"))
        let notes = ReviewVerdictPolicy.notesBullets(blocking: ReviewSeverity.allCases)
        #expect(notes.contains("there are no findings at all"))
    }

    /// Order is an input artifact, not a policy difference — a workspace that
    /// stored `[yellow, red]` must render exactly like the default.
    @Test func policyRenderingIsIndependentOfInputOrder() {
        #expect(ReviewVerdictPolicy.ruleBlock(blocking: [.yellow, .red]) == Self.goldenRule)
        #expect(ReviewVerdictPolicy.tableRows(blocking: [.green, .red]) ==
                ReviewVerdictPolicy.tableRows(blocking: [.red, .green]))
    }

    // MARK: - Expansion

    @Test func expandLeavesNoPlaceholderBehindForAnyPolicy() {
        let body = [
            ReviewVerdictPolicy.rulePlaceholder,
            ReviewVerdictPolicy.gradingGuidancePlaceholder,
            ReviewVerdictPolicy.tablePlaceholder,
            ReviewVerdictPolicy.notesPlaceholder,
        ].joined(separator: "\n\n")
        for blocking in [[ReviewSeverity.red], ReviewSeverity.defaultBlocking, ReviewSeverity.allCases] {
            let expanded = ReviewVerdictPolicy.expand(body, blocking: blocking)
            #expect(!expanded.contains("{{CROW_REVIEW_"))
        }
    }

    /// `SessionService.prepareReviewClone` pre-expands the policy once, then the
    /// body flows through `CrowAttribution.expandSkillBody`, which expands again
    /// with the default set. That is only safe because the second pass finds no
    /// placeholders — otherwise the default would overwrite the workspace's
    /// policy on the way to disk.
    @Test func expandIsIdempotentSoThePreExpandedReviewBodySurvivesASecondPass() {
        let body = """
        \(ReviewVerdictPolicy.rulePlaceholder)

        \(ReviewVerdictPolicy.tablePlaceholder)

        \(ReviewVerdictPolicy.notesPlaceholder)
        """
        let once = ReviewVerdictPolicy.expand(body, blocking: [.red])
        let twice = ReviewVerdictPolicy.expand(once, blocking: ReviewSeverity.defaultBlocking)
        #expect(once == twice)
        #expect(twice.contains("any Red finding"))
        #expect(!twice.contains("any Red **or** any Yellow finding"))
    }

    @Test func expandLeavesABodyWithNoPlaceholdersUnchanged() {
        let stub = "# Crow Review PR Skill\n\nNo placeholders here."
        #expect(ReviewVerdictPolicy.expand(stub, blocking: [.red]) == stub)
    }

    // MARK: - The bundled skill actually carries the placeholders

    /// Both halves of the skill must carry all three placeholders, or the policy
    /// silently stops reaching the agent for whichever build reads that half
    /// (dev reads `skills/`, release reads `Resources/*.template`). The shell
    /// gate `check-workspace-custom-instructions.sh` asserts this too; this is
    /// the version that runs in `swift test`.
    @Test func bothHalvesOfTheBundledSkillCarryEveryPlaceholder() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var root: URL?
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("skills/crow-review-pr/SKILL.md").path) {
                root = dir
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let repoRoot = try #require(root, "could not locate the repo root from \(#filePath)")

        let skill = try String(
            contentsOf: repoRoot.appendingPathComponent("skills/crow-review-pr/SKILL.md"),
            encoding: .utf8)
        let template = try String(
            contentsOf: repoRoot.appendingPathComponent("Resources/crow-review-pr-SKILL.md.template"),
            encoding: .utf8)

        #expect(skill == template, "the two halves of crow-review-pr must stay byte-identical")
        for placeholder in [
            ReviewVerdictPolicy.rulePlaceholder,
            ReviewVerdictPolicy.gradingGuidancePlaceholder,
            ReviewVerdictPolicy.tablePlaceholder,
            ReviewVerdictPolicy.notesPlaceholder,
        ] {
            #expect(skill.contains(placeholder), "SKILL.md lost \(placeholder)")
        }
    }

    /// End-to-end on the real skill: the default expansion reproduces the exact
    /// prose the file carried before CROW-963, and a red-only workspace does not.
    @Test func expandingTheRealSkillReproducesTodaysDefaultText() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("skills/crow-review-pr/SKILL.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let skill = try String(contentsOf: try #require(found), encoding: .utf8)

        let asDefault = ReviewVerdictPolicy.expand(skill, blocking: ReviewSeverity.defaultBlocking)
        #expect(asDefault.contains(Self.goldenRule))
        #expect(asDefault.contains(Self.goldenTable))
        #expect(asDefault.contains(Self.goldenNotes))
        // CROW-986: the real skill carries the grading placeholder and expands it.
        #expect(asDefault.contains("An accepted risk is not a blocker."))

        let asRedOnly = ReviewVerdictPolicy.expand(skill, blocking: [.red])
        #expect(!asRedOnly.contains(Self.goldenRule))
        #expect(asRedOnly.contains("| Yellow | Should fix   | Approve allowed           |"))
    }

    // MARK: - Severity model

    @Test func canonicalizeSortsSeverestFirstAndDropsDuplicates() {
        #expect(ReviewSeverity.canonicalize([.green, .red, .yellow]) == [.red, .yellow, .green])
        #expect(ReviewSeverity.canonicalize([.yellow, .yellow]) == [.yellow])
        #expect(ReviewSeverity.canonicalize([]) == [])
    }

    @Test func defaultBlockingIsRedAndYellow() {
        #expect(ReviewSeverity.defaultBlocking == [.red, .yellow])
    }

    // MARK: - Grading guidance (CROW-986)

    /// The grading block carries all three loop-breaking rules that let a review
    /// of a documented, accepted risk terminate in an approval.
    @Test func gradingGuidanceCarriesTheThreeLoopBreakingRules() {
        let guidance = ReviewVerdictPolicy.gradingGuidanceBlock
        #expect(guidance.contains("An accepted risk is not a blocker."))
        #expect(guidance.contains("Do not re-block a declined finding."))
        #expect(guidance.contains("Grade against the diff, not the roadmap."))
        // Each rule caps the finding at Green rather than dropping it.
        #expect(guidance.contains("at most **Green**"))
    }

    /// The guidance bounds the *grade*, not the *gate*: it must render identically
    /// no matter which severities a workspace blocks on. Expanding a body that
    /// carries only the grading placeholder proves the substituted text does not
    /// vary with `blocking`.
    @Test func gradingGuidanceIsIndependentOfTheBlockingPolicy() {
        let body = ReviewVerdictPolicy.gradingGuidancePlaceholder
        let redOnly = ReviewVerdictPolicy.expand(body, blocking: [.red])
        let byDefault = ReviewVerdictPolicy.expand(body, blocking: ReviewSeverity.defaultBlocking)
        let everything = ReviewVerdictPolicy.expand(body, blocking: ReviewSeverity.allCases)
        #expect(redOnly == byDefault)
        #expect(byDefault == everything)
        #expect(redOnly == ReviewVerdictPolicy.gradingGuidanceBlock)
    }

    // MARK: - Architecture study (CROW-1062)

    /// The Step 3 "Architecture & Existing Patterns" study step is static prose in
    /// the skill body (not a placeholder), so it must survive expansion under any
    /// workspace policy and reach every harness. Pin it on the real skill the same
    /// way `expandingTheRealSkillReproducesTodaysDefaultText` pins the verdict
    /// blocks: a reword or a dropped step fails here.
    @Test func expandedSkillCarriesTheArchitectureStudyStepForEveryPolicy() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("skills/crow-review-pr/SKILL.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let skill = try String(contentsOf: try #require(found), encoding: .utf8)

        for blocking in [ReviewSeverity.defaultBlocking, [.red], ReviewSeverity.allCases] {
            let expanded = ReviewVerdictPolicy.expand(skill, blocking: blocking)
            // The study step, its two load-bearing instructions, and the grade it
            // mandates for architectural mismatch.
            #expect(expanded.contains("Architecture & Existing Patterns (study this before scoring the diff):"),
                    "\(blocking) lost the architecture study step")
            #expect(expanded.contains("Name the existing pathway the change should have extended"),
                    "\(blocking) lost the name-the-existing-pathway instruction")
            #expect(expanded.contains("Invents a parallel mechanism where a small extension of current behavior would do."),
                    "\(blocking) lost the reinvented-pathway finding")
            #expect(expanded.contains("grade them **Yellow** (should-fix) or **Red** (must-fix), never Green"),
                    "\(blocking) lost the Yellow/Red grade for architecture findings")
            // The posted review body must carry the section too, so the study is visible.
            #expect(expanded.contains("### Architecture / Existing Patterns"),
                    "\(blocking) lost the review-body architecture section")
        }
    }

    /// The grade-side reconciliation (CROW-1062): the third grading rule now carves
    /// an architectural defect out of "roadmap", so a reviewer cannot cap a
    /// reinvented-pathway finding at Green by calling it a future refactor. Adding
    /// this must not disturb the three loop-breaking rule headers.
    @Test func gradingGuidanceLetsArchitectureDefectsBlock() {
        let guidance = ReviewVerdictPolicy.gradingGuidanceBlock
        #expect(guidance.contains("may be graded **Yellow** or **Red**, not waved through as a future refactor."))
        // The three loop-breakers survive unchanged.
        #expect(guidance.contains("An accepted risk is not a blocker."))
        #expect(guidance.contains("Do not re-block a declined finding."))
        #expect(guidance.contains("Grade against the diff, not the roadmap."))
    }

    // MARK: - Cross-tenant Red floor (CROW-1321)

    private static let floorRule = "**Cross-tenant effect or exposure is always Red.**"
    private static let acceptedRiskRule = "**An accepted risk is not a blocker.**"
    private static let declinedRule = "**Do not re-block a declined finding.**"
    private static let gradeAgainstDiffRule = "**Grade against the diff, not the roadmap.**"

    /// The bullet that opens with `header`, up to the end of its line. Each
    /// grading rule is one line, so a carve-out asserted here sits in the rule
    /// the agent is applying — not somewhere else in the block.
    private static func ruleLine(_ header: String, in text: String) -> Substring? {
        text.split(separator: "\n").first { $0.hasPrefix("- \(header)") }
    }

    /// corveil/corveil#620 graded "Org A's keyword/regex rules apply to Org B's
    /// traffic" Green under the accepted-risk rule. The floor must name both
    /// halves of the class — effect and exposure — and define effect in the
    /// ticket's terms, so a reviewer can't argue a finding out of it.
    @Test func gradingGuidanceCarriesTheCrossTenantRedFloor() {
        let guidance = ReviewVerdictPolicy.gradingGuidanceBlock
        #expect(guidance.contains(Self.floorRule))
        #expect(guidance.contains(
            "*Cross-tenant effect* means one tenant's config or data changes another tenant's requests, responses, records, limits, availability or costs."))
        #expect(guidance.contains("*Cross-tenant exposure* means one tenant can read another tenant's config or data"))
        #expect(guidance.contains("A finding of either is **Red** — never Yellow, never Green."))
        #expect(guidance.contains(
            "The accepted-risk, declined-finding and grade-against-the-diff rules below **do not apply** to it"))
    }

    /// The floor has to be read before the caps, or an agent applying the
    /// accepted-risk rule top-down never reaches it. Order is asserted on all three.
    @Test func crossTenantFloorPrecedesEveryCap() throws {
        let guidance = ReviewVerdictPolicy.gradingGuidanceBlock
        let floor = try #require(guidance.range(of: Self.floorRule))
        for cap in [Self.acceptedRiskRule, Self.declinedRule, Self.gradeAgainstDiffRule] {
            let capRange = try #require(guidance.range(of: cap), "lost \(cap)")
            #expect(floor.lowerBound < capRange.lowerBound, "\(cap) precedes the cross-tenant floor")
        }
    }

    /// Stating the floor once is not enough: the #620 reviewer applied the
    /// accepted-risk rule on its own terms. Each cap carries its own carve-out,
    /// on the same line as the cap.
    @Test func everyCapExemptsCrossTenantFindings() throws {
        let guidance = ReviewVerdictPolicy.gradingGuidanceBlock
        #expect(guidance.contains("A cross-tenant finding is exempt from all three:"))

        let acceptedRisk = try #require(Self.ruleLine(Self.acceptedRiskRule, in: guidance))
        #expect(acceptedRisk.contains("except a cross-tenant finding, which stays **Red**"))

        let declined = try #require(Self.ruleLine(Self.declinedRule, in: guidance))
        #expect(declined.contains("unless it is a cross-tenant finding, which stays **Red**"))

        let gradeAgainstDiff = try #require(Self.ruleLine(Self.gradeAgainstDiffRule, in: guidance))
        #expect(gradeAgainstDiff.contains("unless the unenforced hazard is cross-tenant, which is **Red**"))
    }

    /// A carve-out in a cap's first sentence does not qualify the sentences after
    /// it. A reviewer reads "if you remain unconvinced, leave it Green" on its own
    /// terms — the #620 failure mode — so every sentence or clause in a cap that
    /// tells the reviewer to grade Green or stand down must itself carve out a
    /// cross-tenant finding.
    @Test func everyStandDownClauseInACapCarvesOutCrossTenantFindings() throws {
        let guidance = ReviewVerdictPolicy.gradingGuidanceBlock
        let standDownMarkers = ["Green", "rather than blocking", "instead of holding up", "not permitted"]

        for cap in [Self.acceptedRiskRule, Self.declinedRule, Self.gradeAgainstDiffRule] {
            let line = try #require(Self.ruleLine(cap, in: guidance))
            let clauses = line
                .replacingOccurrences(of: "; ", with: ". ")
                .components(separatedBy: ". ")
            for clause in clauses where standDownMarkers.contains(where: clause.contains) {
                #expect(clause.contains("cross-tenant"),
                        "\(cap) stands down without a cross-tenant carve-out: \(clause)")
            }
        }
    }

    /// #620 deferred the hazard to an issue the same PR closed. All three bar
    /// items must be present, each checked by the reviewer, and a closed — or
    /// about-to-be-closed — issue must not satisfy the first.
    @Test func gradingGuidanceCarriesTheDeferralBar() {
        let guidance = ReviewVerdictPolicy.gradingGuidanceBlock
        #expect(guidance.contains("**Deferral bar.**"))
        #expect(guidance.contains("you have checked each one yourself rather than taking the PR's word for it"))
        #expect(guidance.contains("an **open** tracking issue"))
        #expect(guidance.contains("an issue this PR closes does not count"))
        #expect(guidance.contains("a `// DEFERRED(#N):` marker at the site"))
        #expect(guidance.contains("the exceptions table of the repo's tenant-isolation ADR, where the repo has one"))
        #expect(guidance.contains("When any one is missing, the finding stays **Red**."))
    }

    @Test func gradingGuidanceCarriesTheTenantEffectChecklist() {
        let guidance = ReviewVerdictPolicy.gradingGuidanceBlock
        #expect(guidance.contains("`### Tenant effect`"))
        for question in [
            "1. Which org's requests consult this state?",
            "2. Can org A's row change org B's outcome?",
            "3. Is any org argument dropped, Nil, or optional?",
            "4. Does a test pin cross-org behavior?",
        ] {
            #expect(guidance.contains(question), "lost checklist question \(question)")
        }
        #expect(guidance.contains("`n/a — <why>`"))
        // Generic: repo rules stack on the floor, never under it.
        #expect(guidance.contains("they can add to it, never lower it"))
    }

    /// End-to-end on the real skill: under every policy the floor reaches the
    /// agent ahead of the accepted-risk rule, the review body asks for the
    /// Tenant effect section, and Step 5a refuses a draft without it.
    @Test func expandedSkillCarriesTheTenantEffectGateForEveryPolicy() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("skills/crow-review-pr/SKILL.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let skill = try String(contentsOf: try #require(found), encoding: .utf8)

        for blocking in [ReviewSeverity.defaultBlocking, [.red], ReviewSeverity.allCases] {
            let expanded = ReviewVerdictPolicy.expand(skill, blocking: blocking)
            let floor = try #require(expanded.range(of: Self.floorRule), "\(blocking) lost the floor")
            let acceptedRisk = try #require(expanded.range(of: Self.acceptedRiskRule))
            #expect(floor.lowerBound < acceptedRisk.lowerBound, "\(blocking) put the floor after the accepted-risk rule")

            #expect(expanded.contains("### Tenant effect\n"), "\(blocking) lost the review-body section")
            #expect(expanded.contains("#### Tenant effect check"), "\(blocking) lost the Step 5a check")
            #expect(expanded.contains("**No section** ⇒ do not post."))
            #expect(expanded.contains("Only after **all three** checks pass"))
            // Step 4b's unverified-Red downgrade must not become a back door.
            #expect(expanded.contains("its absence is the verification — the finding stays **Red**"))
        }
    }
}
