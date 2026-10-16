import Foundation

/// Renders a workspace's ``WorkspaceInfo/reviewInstructions`` into the
/// `crow-review-pr` brief (CROW-1340).
///
/// The skill carries one placeholder, on its own line at the end of Step 3
/// (Review the Code). ``expand(_:instructions:)`` replaces it with a
/// `### Workspace Review Instructions` section, or — when the workspace has no
/// instructions — deletes the placeholder line outright, so a repo claimed by
/// no workspace gets a brief **byte-identical** to the one before this field
/// existed.
///
/// One rendering reaches every harness. `CrowAttribution.expandSkillBody` runs
/// it as its **last** substitution, which covers both review launch paths: the
/// copied `.claude/skills/crow-review-pr/SKILL.md` that Claude's
/// `/crow-review-pr` loads, and the inlined body Cursor / OpenCode / Codex /
/// Grok / Antigravity / Muse receive as their prompt. Running last is what keeps
/// the operator's text verbatim — the earlier passes rewrite `$ARGUMENTS`,
/// `via Claude Code` and the verdict placeholders, and none of them may touch
/// what the operator wrote.
///
/// The instructions **add to** the review rubric. The rendered preamble says
/// so: they cannot relax the verdict rule, the grading discipline (including
/// the cross-tenant floor), or the requirement to post a verdict with
/// `gh pr review`.
public enum ReviewWorkspaceInstructions {

    public static let placeholder = "{{CROW_REVIEW_WORKSPACE_INSTRUCTIONS}}"

    public static let heading = "### Workspace Review Instructions"

    /// The fixed preamble placed between the heading and the operator's text.
    public static let preamble = """
    This workspace's Crow configuration adds the instructions below to the review. Apply them while you review the code, and report what they turn up as findings graded under the same rules as every other finding. They add to this review's rubric — they do **not** change the verdict rule, the grading discipline (including the cross-tenant floor), the pre-submit guardrails, or the requirement to finish by posting a verdict with `gh pr review` in Step 5.
    """

    /// The trimmed instructions, or `nil` when unset or blank.
    public static func normalized(_ instructions: String?) -> String? {
        guard let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The section that replaces the placeholder line — empty when there is
    /// nothing to say. Ends in a blank line so the next step heading keeps the
    /// spacing the template gives it.
    public static func block(_ instructions: String?) -> String {
        guard let text = normalized(instructions) else { return "" }
        return "\(heading)\n\n\(preamble)\n\n\(text)\n\n"
    }

    /// Substitute the placeholder in `body`.
    ///
    /// The placeholder *line* (with its newline) is what gets replaced, so the
    /// unset case leaves no stray blank line behind. A bare placeholder with no
    /// trailing newline is handled too. Idempotent: a body with no placeholder
    /// passes through unchanged.
    public static func expand(_ body: String, instructions: String?) -> String {
        let rendered = block(instructions)
        return body
            .replacingOccurrences(of: placeholder + "\n", with: rendered)
            .replacingOccurrences(of: placeholder, with: rendered)
    }

    /// A single-line form for the re-review prompt.
    ///
    /// Re-review prompts are typed into a live terminal, where every `\n` is a
    /// Return keypress (`TmuxBackend.sendText`), so they must be one line. The
    /// full multi-line section already reached the agent at kickoff; this
    /// restates it so a re-review round still carries it after context
    /// compaction. Lines are trimmed and joined with ` / `; control characters
    /// are dropped.
    public static func singleLine(_ instructions: String?) -> String? {
        guard let text = normalized(instructions) else { return nil }
        let lines = text
            .components(separatedBy: .newlines)
            .map { line in
                String(String.UnicodeScalarView(line.unicodeScalars.filter {
                    !CharacterSet.controlCharacters.contains($0)
                })).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: " / ")
    }
}
