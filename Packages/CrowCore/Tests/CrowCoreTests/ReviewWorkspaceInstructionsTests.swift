import Foundation
import Testing
@testable import CrowCore

/// `ReviewWorkspaceInstructions` and its `expandSkillBody` hook (CROW-1340).
///
/// The two properties that matter: an unset field leaves the brief
/// **byte-identical** to one rendered before the field existed, and a set
/// field reaches the agent **verbatim** — untouched by the `$ARGUMENTS`,
/// attribution and verdict-policy rewrites that run over the rest of the body.
@Suite("Review workspace instructions")
struct ReviewWorkspaceInstructionsTests {

    /// The skill's shape around the placeholder: end of Step 3, blank line,
    /// placeholder on its own line, next step heading.
    private static let withPlaceholder = """
    ### Step 3: Review the Code

    - Missing tests for new code

    \(ReviewWorkspaceInstructions.placeholder)
    ### Step 4: Run Static Analysis
    """

    /// The same body as it read before CROW-1340 added the placeholder.
    private static let beforeThisField = """
    ### Step 3: Review the Code

    - Missing tests for new code

    ### Step 4: Run Static Analysis
    """

    @Test func unsetInstructionsRemoveThePlaceholderLineExactly() {
        for unset: String? in [nil, "", "   \n\t  "] {
            #expect(ReviewWorkspaceInstructions.expand(Self.withPlaceholder, instructions: unset)
                    == Self.beforeThisField)
        }
    }

    @Test func setInstructionsRenderAHeadedSectionBeforeTheNextStep() {
        let text = "Flag any schema change that ships without a migration.\n\n- Force-unwraps are fine in tests."
        let out = ReviewWorkspaceInstructions.expand(Self.withPlaceholder, instructions: "\n\(text)\n  ")

        #expect(out == """
        ### Step 3: Review the Code

        - Missing tests for new code

        \(ReviewWorkspaceInstructions.heading)

        \(ReviewWorkspaceInstructions.preamble)

        \(text)

        ### Step 4: Run Static Analysis
        """)
    }

    /// Precedence is part of the contract: the section must say it cannot relax
    /// the verdict gate or the posting requirement.
    @Test func preambleStatesTheInstructionsDoNotOverrideTheVerdict() {
        let preamble = ReviewWorkspaceInstructions.preamble
        #expect(preamble.contains("do **not** change the verdict rule"))
        #expect(preamble.contains("cross-tenant floor"))
        #expect(preamble.contains("`gh pr review`"))
    }

    @Test func expandIsIdempotentOnABodyWithoutThePlaceholder() {
        #expect(ReviewWorkspaceInstructions.expand(Self.beforeThisField, instructions: "x")
                == Self.beforeThisField)
    }

    /// The instructions are rendered after every other substitution, so text the
    /// operator wrote that *looks* like a placeholder survives as written.
    @Test func expandSkillBodyKeepsTheInstructionsVerbatim() {
        let text = "Check $ARGUMENTS against via Claude Code and {{CROW_REVIEW_VERDICT_RULE}} literally."
        let body = "Review $ARGUMENTS via Claude Code.\n\n\(ReviewWorkspaceInstructions.placeholder)\nEnd."
        let out = CrowAttribution.expandSkillBody(body, agentKind: .cursor, reviewInstructions: text)

        #expect(out.contains(text))
        #expect(out.contains("Review $ARGUMENTS via Cursor."), "the rest of the body is still rewritten")
        #expect(!out.contains(ReviewWorkspaceInstructions.placeholder))
    }

    /// Every other `expandSkillBody` caller (the Manager's scaffolded skill copy)
    /// passes no instructions; the placeholder must not reach disk literally.
    @Test func expandSkillBodyDropsThePlaceholderByDefault() {
        let out = CrowAttribution.expandSkillBody(Self.withPlaceholder, agentKind: .claudeCode)
        #expect(out == Self.beforeThisField)
    }

    @Test func singleLineJoinsLinesAndDropsControlCharacters() {
        let line = ReviewWorkspaceInstructions.singleLine("  First rule.\n\n\tSecond\u{07} rule.\r\nThird.  ")
        #expect(line == "First rule. / Second rule. / Third.")
        #expect(ReviewWorkspaceInstructions.singleLine(nil) == nil)
        #expect(ReviewWorkspaceInstructions.singleLine(" \n ") == nil)
    }

    // MARK: - Model

    @Test func workspaceDecodesABlankReviewInstructionsAsUnset() throws {
        let json = #"{"workspaces":[{"id":"\#(UUID().uuidString)","name":"Org","provider":"github","cli":"gh","reviewInstructions":"  "}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.workspaces[0].reviewInstructions == nil)
    }

    @Test func workspaceRoundTripsReviewInstructionsSeparatelyFromCustomInstructions() throws {
        let config = AppConfig(workspaces: [
            WorkspaceInfo(name: "Org", customInstructions: "work only", reviewInstructions: "review only")
        ])
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.workspaces[0].customInstructions == "work only")
        #expect(decoded.workspaces[0].reviewInstructions == "review only")
    }

    @Test func unsetReviewInstructionsAreNotWrittenToConfig() throws {
        let data = try JSONEncoder().encode(AppConfig(workspaces: [WorkspaceInfo(name: "Org")]))
        #expect(!String(decoding: data, as: UTF8.self).contains("reviewInstructions"))
    }

    /// The kickoff and re-review paths resolve the workspace by repo slug — the
    /// same lookup the verdict policy uses — and a repo no workspace claims gets
    /// nothing.
    @Test func slugLookupFindsTheClaimingWorkspacesReviewInstructions() {
        let config = AppConfig(workspaces: [
            WorkspaceInfo(name: "Other", alwaysInclude: ["other/repo"], reviewInstructions: "other"),
            WorkspaceInfo(name: "Acme", alwaysInclude: ["acme/*"],
                          customInstructions: "work only", reviewInstructions: "acme review"),
        ])
        #expect(config.workspace(forRepoSlug: "acme/api")?.reviewInstructions == "acme review")
        #expect(config.workspace(forRepoSlug: "nobody/claims-this")?.reviewInstructions == nil)
    }

    // MARK: - The bundled skill

    /// On the real skill: the placeholder sits on its own line at the end of
    /// Step 3, once, in both halves; and an unset field renders exactly the text
    /// the file carried before CROW-1340 (the same skill minus that one line).
    @Test func theRealSkillCarriesThePlaceholderOnceAndUnsetLeavesItUnchanged() throws {
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

        for path in ["skills/crow-review-pr/SKILL.md", "Resources/crow-review-pr-SKILL.md.template"] {
            let skill = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            let line = ReviewWorkspaceInstructions.placeholder + "\n"
            #expect(skill.components(separatedBy: ReviewWorkspaceInstructions.placeholder).count == 2,
                    "\(path) must carry the placeholder exactly once")
            #expect(skill.contains("- Missing tests for new code\n\n" + line + "### Step 4:"),
                    "\(path): the placeholder belongs on its own line at the end of Step 3")

            let unset = ReviewWorkspaceInstructions.expand(skill, instructions: nil)
            #expect(unset == skill.replacingOccurrences(of: line, with: ""))

            let set = ReviewWorkspaceInstructions.expand(skill, instructions: "Check RLS on every new table.")
            let section = try #require(set.range(of: ReviewWorkspaceInstructions.heading))
            let step4 = try #require(set.range(of: "### Step 4: Run Static Analysis"))
            #expect(section.lowerBound < step4.lowerBound)
            #expect(set.contains("Check RLS on every new table.\n\n### Step 4:"))
        }
    }
}
