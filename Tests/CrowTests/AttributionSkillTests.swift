import CrowCore
import Foundation
import Testing
@testable import Crow

/// Snapshot tests for Crow skill attribution instructions (issue #443).
///
/// Skills reference `${CROW_AGENT_DISPLAY_NAME:-Claude Code}` in footers. The unit tests in
/// `Packages/CrowCore/Tests/CrowCoreTests/CrowAttributionTests.swift` verify the
/// Swift helpers and default Claude Code footers.
@Suite("Review attribution snapshot")
struct AttributionSkillTests {

    private static let canonicalRepoURL = "https://github.com/radiusmethod/crow"
    private static let shellAgentExpression = "${CROW_AGENT_DISPLAY_NAME:-Claude Code}"
    private static let agentPlaceholder = "{{CROW_AGENT_DISPLAY_NAME}}"

    /// Walk up from this test source file until we find Package.swift.
    /// Returns the repo root URL.
    private static func repoRoot(file: StaticString = #file) -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path
            ) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Package.swift walking up from \(file)")
        return URL(fileURLWithPath: "/")
    }

    private static func liveSkill() throws -> String {
        let url = repoRoot()
            .appendingPathComponent("skills/crow-review-pr/SKILL.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func bundledTemplate() throws -> String {
        let url = repoRoot()
            .appendingPathComponent("Resources/crow-review-pr-SKILL.md.template")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func liveTicketSkill() throws -> String {
        let url = repoRoot()
            .appendingPathComponent("skills/crow-create-ticket/SKILL.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func bundledTicketTemplate() throws -> String {
        let url = repoRoot()
            .appendingPathComponent("Resources/crow-create-ticket-SKILL.md.template")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func liveAttributionFooter() throws -> String {
        let url = repoRoot()
            .appendingPathComponent("skills/crow-attribution/FOOTER.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func bundledAttributionTemplate() throws -> String {
        let url = repoRoot()
            .appendingPathComponent("Resources/crow-attribution-FOOTER.md.template")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func liveSkillReferencesAgentDisplayNameEnv() throws {
        let content = try Self.liveSkill()
        #expect(content.contains(Self.shellAgentExpression))
        #expect(!content.contains(Self.agentPlaceholder))
        #expect(content.contains(Self.canonicalRepoURL))
    }

    @Test func bundledTemplateReferencesAgentDisplayNameEnv() throws {
        let content = try Self.bundledTemplate()
        #expect(content.contains(Self.shellAgentExpression))
        #expect(!content.contains(Self.agentPlaceholder))
    }

    @Test func liveSkillAndBundledTemplateAreByteIdentical() throws {
        let live = try Self.liveSkill()
        let bundled = try Self.bundledTemplate()
        #expect(live == bundled,
                "skills/crow-review-pr/SKILL.md and Resources/crow-review-pr-SKILL.md.template must stay in sync — Scaffolder.bundledReviewSkill() picks one or the other depending on build type.")
    }

    @Test func attributionFilesContainNoForkReferences() throws {
        let live = try Self.liveSkill()
        let bundled = try Self.bundledTemplate()

        #expect(!live.contains("nicholasgasior"))
        #expect(!bundled.contains("nicholasgasior"))

        // Lowercase `corveil` — to skip the unrelated `CorveilTheme.swift`
        // design-system file which uses capital `C`.
        #expect(!live.contains("corveil"))
        #expect(!bundled.contains("corveil"))
    }

    @Test func liveSkillLinksOnlyToCanonicalRepo() throws {
        // Any github.com link in the review skill must point at radiusmethod/crow.
        // This catches drift where a contributor pastes a fork URL.
        let content = try Self.liveSkill()
        let pattern = #"https://github\.com/[A-Za-z0-9._/-]+"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        #expect(!matches.isEmpty, "expected at least one github.com link (the attribution line) in the skill")
        for match in matches {
            guard let r = Range(match.range, in: content) else { continue }
            let url = String(content[r])
            #expect(url == Self.canonicalRepoURL,
                    "review skill contains non-canonical github.com link: \(url)")
        }
    }

    @Test func liveTicketSkillReferencesAgentDisplayNameEnv() throws {
        let content = try Self.liveTicketSkill()
        #expect(content.contains(Self.shellAgentExpression))
        #expect(content.contains(Self.canonicalRepoURL))
        #expect(!content.contains("Do not modify the link text"))
    }

    @Test func bundledTicketTemplateReferencesAgentDisplayNameEnv() throws {
        let content = try Self.bundledTicketTemplate()
        #expect(content.contains(Self.shellAgentExpression))
    }

    @Test func liveTicketSkillAndBundledTemplateAreByteIdentical() throws {
        let live = try Self.liveTicketSkill()
        let bundled = try Self.bundledTicketTemplate()
        #expect(live == bundled,
                "skills/crow-create-ticket/SKILL.md and Resources/crow-create-ticket-SKILL.md.template must stay in sync — Scaffolder.bundledCreateTicketSkill() picks one or the other depending on build type.")
    }

    @Test func ticketSkillLinksOnlyToCanonicalRepo() throws {
        // Any github.com link in the create-ticket skill must point at radiusmethod/crow.
        let content = try Self.liveTicketSkill()
        let pattern = #"https://github\.com/[A-Za-z0-9._/-]+"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)
        #expect(!matches.isEmpty, "expected at least one github.com link (the attribution line) in the skill")
        for match in matches {
            guard let r = Range(match.range, in: content) else { continue }
            let url = String(content[r])
            #expect(url == Self.canonicalRepoURL,
                    "create-ticket skill contains non-canonical github.com link: \(url)")
        }
    }

    @Test func sharedFooterDocumentsAgentEnvVars() throws {
        let footer = try Self.liveAttributionFooter()
        #expect(footer.contains("CROW_AGENT_KIND"))
        #expect(footer.contains("CROW_AGENT_DISPLAY_NAME"))
        #expect(footer.contains(Self.canonicalRepoURL))
    }

    @Test func liveAttributionFooterAndBundledTemplateAreByteIdentical() throws {
        let live = try Self.liveAttributionFooter()
        let bundled = try Self.bundledAttributionTemplate()
        #expect(live == bundled,
                "skills/crow-attribution/FOOTER.md and Resources/crow-attribution-FOOTER.md.template must stay in sync — Scaffolder.bundledAttributionFooter() loads the template in release builds.")
    }

    @Test func liveAttributionFooterMatchesSwiftConstant() throws {
        let live = try Self.liveAttributionFooter()
        let swift = CrowAttribution.sharedFooterInstructions
        var trimmed = live
        while trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") { trimmed.removeLast() }
        var swiftTrimmed = swift
        while swiftTrimmed.hasSuffix("\n") || swiftTrimmed.hasSuffix("\r") { swiftTrimmed.removeLast() }
        #expect(trimmed + "\n" == swiftTrimmed + "\n",
                "skills/crow-attribution/FOOTER.md must match CrowAttribution.sharedFooterInstructions — the constant is Scaffolder's final fallback.")
    }
}
