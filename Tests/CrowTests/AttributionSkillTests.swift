import Foundation
import Testing
@testable import Crow

/// Snapshot tests for the `/crow-review-pr` skill attribution line.
///
/// These tests intentionally hardcode the expected attribution string rather
/// than importing `CrowCore.CrowAttribution`. The unit test in
/// `Packages/CrowCore/Tests/CrowCoreTests/CrowAttributionTests.swift` verifies
/// that the Swift constant matches this literal, so any drift between the
/// markdown skill file and the Swift constant is caught from both sides.
@Suite("Review attribution snapshot")
struct AttributionSkillTests {

    private static let canonicalRepoURL = "https://github.com/radiusmethod/crow"
    private static let canonicalReviewLink =
        "[🐦‍⬛ Reviewed by Crow via Claude Code](https://github.com/radiusmethod/crow)"
    private static let canonicalTicketLink =
        "[🐦‍⬛ Created with Crow via Claude Code](https://github.com/radiusmethod/crow)"

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

    @Test func liveSkillContainsCanonicalAttributionLink() throws {
        let content = try Self.liveSkill()
        #expect(content.contains(Self.canonicalReviewLink))
    }

    @Test func bundledTemplateContainsCanonicalAttributionLink() throws {
        let content = try Self.bundledTemplate()
        #expect(content.contains(Self.canonicalReviewLink))
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

    @Test func liveTicketSkillContainsCanonicalAttributionLink() throws {
        let content = try Self.liveTicketSkill()
        #expect(content.contains(Self.canonicalTicketLink))
    }

    @Test func bundledTicketTemplateContainsCanonicalAttributionLink() throws {
        let content = try Self.bundledTicketTemplate()
        #expect(content.contains(Self.canonicalTicketLink))
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
}
