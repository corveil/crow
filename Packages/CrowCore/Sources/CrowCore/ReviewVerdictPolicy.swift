import Foundation

/// A `crow-review-pr` finding severity (CROW-963).
///
/// The taxonomy is fixed at three levels. Which of them *gate the verdict* is
/// per-workspace configuration (``WorkspaceInfo/reviewBlockingSeverities``);
/// renaming a level or adding a fourth is deliberately out of scope, because the
/// skill's required output format and summary table both assume exactly these.
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

    /// Capitalized label as it appears in the skill body and the summary table.
    public var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// The "Meaning" column of the skill's summary table.
    public var meaning: String {
        switch self {
        case .red: return "Must fix"
        case .yellow: return "Should fix"
        case .green: return "Consider"
        }
    }
}

/// Renders a workspace's review-verdict policy into the bundled `crow-review-pr`
/// SKILL body (CROW-963).
///
/// The skill carries three placeholders — the Step 5 verdict rule, the summary
/// table's data rows, and the two reinforcing bullets under Important Notes. All
/// three must agree, or the agent is handed a brief that contradicts itself.
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
    public static let tablePlaceholder = "{{CROW_REVIEW_VERDICT_TABLE}}"
    public static let notesPlaceholder = "{{CROW_REVIEW_VERDICT_NOTES}}"

    // MARK: - Expansion

    /// Substitute the three verdict placeholders for `blocking`.
    ///
    /// Idempotent: a body with no placeholders left (already expanded, or the
    /// test-environment stub from `Scaffolder.bundledReviewSkill()`) passes
    /// through unchanged. That is what lets the review path pre-expand once
    /// before its launch paths diverge and still route through
    /// `CrowAttribution.expandSkillBody`, which expands again with the default.
    public static func expand(_ body: String, blocking: [ReviewSeverity]) -> String {
        let canonical = ReviewSeverity.canonicalize(blocking)
        return body
            .replacingOccurrences(of: rulePlaceholder, with: ruleBlock(blocking: canonical))
            .replacingOccurrences(of: tablePlaceholder, with: tableRows(blocking: canonical))
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

    /// The summary table's three data rows (header and separator stay static in
    /// the skill). Column widths match the checked-in table: 6 / 12 / 26.
    ///
    /// A non-blocking severity reads `Approve allowed`, never anything suggesting
    /// it may be dropped — the finding is still reported either way.
    public static func tableRows(blocking: [ReviewSeverity]) -> String {
        ReviewSeverity.allCases.map { severity in
            let effect = blocking.contains(severity) ? "Request changes" : "Approve allowed"
            return "| \(pad(severity.displayName, 6)) | \(pad(severity.meaning, 12)) | \(pad(effect, 26))|"
        }.joined(separator: "\n")
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

    // MARK: - Helpers

    /// `[red]` → `Red`; `[red, yellow]` → `Red or Yellow`; `[red, yellow, green]`
    /// → `Red, Yellow or Green`. No serial comma, matching the skill's prose.
    private static func joined(_ severities: [ReviewSeverity], separator: String) -> String {
        let names = severities.map(\.displayName)
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + separator + last
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
