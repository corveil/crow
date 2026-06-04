import Foundation
import Testing
@testable import CrowCore

@Test func crowAttributionRepoURLIsCanonical() {
    #expect(CrowAttribution.repoURL == "https://github.com/radiusmethod/crow")
}

@Test func crowAttributionReviewLinkDefaultIsClaudeCode() {
    #expect(CrowAttribution.reviewMarkdownLink ==
            "[🐦‍⬛ Reviewed by Crow via Claude Code](https://github.com/radiusmethod/crow)")
}

@Test func crowAttributionReviewLinkForCursor() {
    #expect(CrowAttribution.reviewMarkdownLink(agentDisplayName: "Cursor") ==
            "[🐦‍⬛ Reviewed by Crow via Cursor](https://github.com/radiusmethod/crow)")
}

@Test func crowAttributionReviewLinkEmbedsRepoURL() {
    #expect(CrowAttribution.reviewMarkdownLink.contains(CrowAttribution.repoURL))
}

@Test func crowAttributionContainsNoForkReferences() {
    #expect(!CrowAttribution.reviewMarkdownLink.contains("nicholasgasior"))
    #expect(!CrowAttribution.reviewMarkdownLink.lowercased().contains("corveil"))
}

@Test func crowAttributionTicketLinkDefaultIsClaudeCode() {
    #expect(CrowAttribution.ticketMarkdownLink ==
            "[🐦‍⬛ Created with Crow via Claude Code](https://github.com/radiusmethod/crow)")
}

@Test func crowAttributionTicketLinkForCodex() {
    #expect(CrowAttribution.ticketMarkdownLink(agentDisplayName: "OpenAI Codex") ==
            "[🐦‍⬛ Created with Crow via OpenAI Codex](https://github.com/radiusmethod/crow)")
}

@Test func crowAttributionTicketLinkEmbedsRepoURL() {
    #expect(CrowAttribution.ticketMarkdownLink.contains(CrowAttribution.repoURL))
}

@Test func crowAttributionTicketLinkContainsNoForkReferences() {
    #expect(!CrowAttribution.ticketMarkdownLink.contains("nicholasgasior"))
    #expect(!CrowAttribution.ticketMarkdownLink.lowercased().contains("corveil"))
}

@Test func crowAttributionAgentDisplayNameKnownKinds() {
    #expect(CrowAttribution.agentDisplayName(for: .claudeCode) == "Claude Code")
    #expect(CrowAttribution.agentDisplayName(for: .cursor) == "Cursor")
    #expect(CrowAttribution.agentDisplayName(for: .codex) == "OpenAI Codex")
    #expect(CrowAttribution.agentDisplayName(for: nil) == "Claude Code")
}

@Test func crowAttributionReadsDisplayNameFromEnvironment() {
    let env = [
        CrowAttribution.agentDisplayNameEnvironmentKey: "Cursor",
        CrowAttribution.agentKindEnvironmentKey: "claude-code",
    ]
    #expect(CrowAttribution.agentDisplayName(fromEnvironment: env) == "Cursor")
}

@Test func crowAttributionMapsKindFromEnvironment() {
    let env = [CrowAttribution.agentKindEnvironmentKey: "cursor"]
    #expect(CrowAttribution.agentDisplayName(fromEnvironment: env) == "Cursor")
}

@Test func crowAttributionEnvironmentEntries() {
    let entries = CrowAttribution.environmentEntries(for: .cursor)
    #expect(entries[CrowAttribution.agentKindEnvironmentKey] == "cursor")
    #expect(entries[CrowAttribution.agentDisplayNameEnvironmentKey] == "Cursor")
}

@Test func crowAttributionExpandSkillBodySubstitutesShellExpression() {
    let body = "Footer: \(CrowAttribution.shellAgentDisplayNameExpression)"
    let expanded = CrowAttribution.expandSkillBody(body, agentKind: .cursor)
    #expect(expanded == "Footer: Cursor")
    #expect(!expanded.contains(CrowAttribution.shellAgentDisplayNameExpression))
}

@Test func crowAttributionExpandSkillBodySubstitutesBareEnvVar() {
    let body = "Footer: $\(CrowAttribution.agentDisplayNameEnvironmentKey)"
    let expanded = CrowAttribution.expandSkillBody(body, agentKind: .cursor)
    #expect(expanded == "Footer: Cursor")
}

@Test func crowAttributionExpandSkillBodySubstitutesLegacyPlaceholder() {
    let body = "Footer: \(CrowAttribution.skillAgentPlaceholder)"
    let expanded = CrowAttribution.expandSkillBody(body, agentKind: .cursor)
    #expect(expanded == "Footer: Cursor")
    #expect(!expanded.contains(CrowAttribution.skillAgentPlaceholder))
}

@Test func crowAttributionExpandSkillBodyReplacesLegacyClaudeCodeWording() {
    let body = "[🐦‍⬛ Reviewed by Crow via Claude Code](https://github.com/radiusmethod/crow)"
    let expanded = CrowAttribution.expandSkillBody(body, agentKind: .codex)
    #expect(expanded.contains("via OpenAI Codex"))
    #expect(!expanded.contains("via Claude Code"))
}

@Test func crowAttributionSharedFooterMatchesRepoFooterFile() throws {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    var found: URL?
    for _ in 0..<10 {
        let candidate = dir.appendingPathComponent("skills/crow-attribution/FOOTER.md")
        if FileManager.default.fileExists(atPath: candidate.path) {
            found = candidate
            break
        }
        dir = dir.deletingLastPathComponent()
    }
    let footerURL = try #require(found)
    let file = try String(contentsOf: footerURL, encoding: .utf8)
    let swift = CrowAttribution.sharedFooterInstructions
    #expect(
        file == swift,
        "skills/crow-attribution/FOOTER.md (\(file.count) bytes at \(footerURL.path)) must match CrowAttribution.sharedFooterInstructions (\(swift.count) bytes)"
    )
}
