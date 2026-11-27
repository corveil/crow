import Foundation
import Testing
@testable import CrowCore

// MARK: - Skills use `crow attribution` (CROW-1533)
//
// The model can't be baked into a skill at scaffold time, so every skill that
// posts a Crow footer must run `crow attribution` when it posts, keep the
// static line as the fallback, and pass the body by file. These pin that for
// each skill and its `Resources/*.template` twin, so a later edit to one
// can't quietly go back to the static-only footer.

private func repoRoot() throws -> URL {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("skills/crow-attribution/FOOTER.md").path) {
            return dir
        }
        dir = dir.deletingLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}

private func read(_ path: String) throws -> String {
    try String(contentsOf: try repoRoot().appendingPathComponent(path), encoding: .utf8)
}

/// A skill and its release-build twin.
struct AttributionSkillPair: CustomTestStringConvertible, Sendable {
    let name: String
    let kind: CrowAttribution.FooterKind
    var skill: String { "skills/\(name)/SKILL.md" }
    var template: String { "Resources/\(name)-SKILL.md.template" }
    var testDescription: String { name }
}

/// The skills that post a footer themselves.
let attributionPostingSkills = [
    AttributionSkillPair(name: "crow-review-pr", kind: .review),
    AttributionSkillPair(name: "crow-create-ticket", kind: .created),
    AttributionSkillPair(name: "crow-diagnose", kind: .created),
]

/// The skills whose seeded prompt tells a coder how to open a PR.
let attributionPRSeedSkills = [
    AttributionSkillPair(name: "crow-workspace", kind: .created),
    AttributionSkillPair(name: "crow-cascade-epic", kind: .created),
]

private let placeholder = CrowAttribution.skillAgentPlaceholder

@Test(arguments: attributionPostingSkills + attributionPRSeedSkills)
func skillMatchesItsTemplate(_ pair: AttributionSkillPair) throws {
    #expect(try read(pair.skill) == read(pair.template), "\(pair.skill) and \(pair.template) drifted")
}

@Test(arguments: attributionPostingSkills + attributionPRSeedSkills)
func skillRunsTheAttributionVerb(_ pair: AttributionSkillPair) throws {
    let body = try read(pair.skill)
    #expect(body.contains("crow attribution --kind \(pair.kind.rawValue)"))
    // Pasted as text, never expanded by the shell (#447). The skills may
    // name `$(crow attribution …)` to forbid it, but never invoke it.
    #expect(!body.contains("$(crow attribution --"))
}

/// The static line stays as the fallback for when the verb fails (an older
/// `crow` on PATH exits 64 on `--kind`), in the exact shape `CrowAttribution`
/// builds. The PR seeds too: a PR must never ship with no Crow line.
@Test(arguments: attributionPostingSkills + attributionPRSeedSkills)
func postingSkillKeepsTheStaticFallback(_ pair: AttributionSkillPair) throws {
    let body = try read(pair.skill)
    #expect(body.contains(CrowAttribution.footer(kind: pair.kind, agentDisplayName: placeholder)))
}

/// The example a skill shows is what the verb prints, so the code's format
/// and the skill's text can't drift apart.
@Test(arguments: [attributionPostingSkills[0], attributionPostingSkills[1]])
func postingSkillExampleMatchesTheVerbFormat(_ pair: AttributionSkillPair) throws {
    let body = try read(pair.skill)
    let example = CrowAttribution.footer(kind: pair.kind, agentDisplayName: placeholder, model: "claude-opus-5-5")
    #expect(body.contains(example), "\(pair.skill) should show \(example)")
}

/// Bodies go through a file, never an inline `--body "…"` the shell expands.
@Test func reviewAndTicketSkillsPassBodiesByFile() throws {
    let review = try read("skills/crow-review-pr/SKILL.md")
    #expect(review.contains("gh pr review \"$PR\" --approve --body-file"))
    #expect(review.contains("gh pr review \"$PR\" --request-changes --body-file"))
    #expect(!review.contains("--body \"YOUR_REVIEW_HERE\""))

    let ticket = try read("skills/crow-create-ticket/SKILL.md")
    #expect(ticket.contains("--body-file \"$TMPDIR/crow-ticket-body.md\""))
    #expect(!ticket.contains("--body \"BODY"))
    #expect(!ticket.contains("--description \"BODY"))

    for seed in attributionPRSeedSkills {
        let body = try read(seed.skill)
        #expect(body.contains("gh pr create --title \"<summary>\" --body-file \"$TMPDIR/pr-body.md\""), "\(seed.name)")
    }
}

@Test func footerDocDescribesTheVerbAndTheOptOut() throws {
    let footer = try read("skills/crow-attribution/FOOTER.md")
    #expect(footer.contains("crow attribution --kind review"))
    #expect(footer.contains("crow attribution --kind created"))
    #expect(footer.contains("--attribution-model false"))
    #expect(footer.contains("--no-model"))
    #expect(try footer == read("Resources/crow-attribution-FOOTER.md.template"))
}
