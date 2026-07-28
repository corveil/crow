import Foundation
import Testing
@testable import CrowCore

@Test func crowAttributionRepoURLIsCanonical() {
    #expect(CrowAttribution.repoURL == "https://github.com/corveil/crow")
}

@Test func crowAttributionReviewLinkDefaultIsClaudeCode() {
    #expect(CrowAttribution.reviewMarkdownLink ==
            "[🐦‍⬛ Reviewed by Crow via Claude Code](https://github.com/corveil/crow)")
}

@Test func crowAttributionReviewLinkForCursor() {
    #expect(CrowAttribution.reviewMarkdownLink(agentDisplayName: "Cursor") ==
            "[🐦‍⬛ Reviewed by Crow via Cursor](https://github.com/corveil/crow)")
}

@Test func crowAttributionReviewLinkEmbedsRepoURL() {
    #expect(CrowAttribution.reviewMarkdownLink.contains(CrowAttribution.repoURL))
}

@Test func crowAttributionContainsNoForkOrSupersededOrgReferences() {
    #expect(!CrowAttribution.reviewMarkdownLink.contains("nicholasgasior"))
    #expect(!CrowAttribution.reviewMarkdownLink.lowercased().contains("radiusmethod"))
}

@Test func crowAttributionTicketLinkDefaultIsClaudeCode() {
    #expect(CrowAttribution.ticketMarkdownLink ==
            "[🐦‍⬛ Created with Crow via Claude Code](https://github.com/corveil/crow)")
}

@Test func crowAttributionTicketLinkForCodex() {
    #expect(CrowAttribution.ticketMarkdownLink(agentDisplayName: "OpenAI Codex") ==
            "[🐦‍⬛ Created with Crow via OpenAI Codex](https://github.com/corveil/crow)")
}

@Test func crowAttributionTicketLinkEmbedsRepoURL() {
    #expect(CrowAttribution.ticketMarkdownLink.contains(CrowAttribution.repoURL))
}

@Test func crowAttributionTicketLinkContainsNoForkOrSupersededOrgReferences() {
    #expect(!CrowAttribution.ticketMarkdownLink.contains("nicholasgasior"))
    #expect(!CrowAttribution.ticketMarkdownLink.lowercased().contains("radiusmethod"))
}

@Test func crowAttributionAgentDisplayNameKnownKinds() {
    #expect(CrowAttribution.agentDisplayName(for: .claudeCode) == "Claude Code")
    #expect(CrowAttribution.agentDisplayName(for: .cursor) == "Cursor")
    #expect(CrowAttribution.agentDisplayName(for: .codex) == "OpenAI Codex")
    #expect(CrowAttribution.agentDisplayName(for: .openCode) == "OpenCode")
    #expect(CrowAttribution.agentDisplayName(for: .grok) == "Grok Build")
    #expect(CrowAttribution.agentDisplayName(for: nil) == "Claude Code")
}

/// The registration-independent display-name set the orphan-window reaper unions
/// with the registry (#861 review r10) covers every built-in kind — so a pane for
/// a kind whose binary later stopped resolving is still reapable, and a new kind
/// added to the table is picked up with zero reaper edits.
@Test func crowAttributionAllKnownDisplayNames() {
    let all = CrowAttribution.allKnownDisplayNames
    for name in ["Claude Code", "Cursor", "OpenAI Codex", "OpenCode", "Antigravity", "Grok Build"] {
        #expect(all.contains(name))
    }
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
    let body = "[🐦‍⬛ Reviewed by Crow via Claude Code](https://github.com/corveil/crow)"
    let expanded = CrowAttribution.expandSkillBody(body, agentKind: .codex)
    #expect(expanded.contains("via OpenAI Codex"))
    #expect(!expanded.contains("via Claude Code"))
}

@Test func crowAttributionExpandSkillBodyForGrok() {
    // #861 review round 6: the inlined `.grok` review skill footer must attribute
    // "via Grok Build", not fall back to "via Claude Code" (which happened when
    // `knownDisplayNames` / setup.sh's `agent_display_name` omitted grok).
    let body = "[🐦‍⬛ Reviewed by Crow via ${CROW_AGENT_DISPLAY_NAME:-Claude Code}](https://github.com/corveil/crow)"
    let expanded = CrowAttribution.expandSkillBody(body, agentKind: .grok)
    #expect(expanded.contains("via Grok Build"))
    #expect(!expanded.contains("via Claude Code"))
    #expect(!expanded.contains("${CROW_AGENT_DISPLAY_NAME"))
}

/// Normalize footer text so a trailing source-file newline does not fail the drift
/// guard when the Swift multiline literal omits the closing-delimiter newline.
private func normalizedFooterText(_ text: String) -> String {
    var trimmed = text
    while trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") {
        trimmed.removeLast()
    }
    return trimmed + "\n"
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
        normalizedFooterText(file) == normalizedFooterText(swift),
        "skills/crow-attribution/FOOTER.md at \(footerURL.path) must match CrowAttribution.sharedFooterInstructions"
    )
}
