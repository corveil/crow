import Testing
import Foundation
import CrowCore
@testable import CrowCLILib

// MARK: - UUID Validation

@Test func validUUIDAccepted() throws {
    try validateUUID("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
}

@Test func uppercaseUUIDAccepted() throws {
    try validateUUID("A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
}

@Test func nilUUIDAccepted() throws {
    try validateUUID("00000000-0000-0000-0000-000000000000")
}

@Test func invalidUUIDRejected() {
    #expect(throws: (any Error).self) {
        try validateUUID("not-a-uuid")
    }
}

@Test func emptyStringUUIDRejected() {
    #expect(throws: (any Error).self) {
        try validateUUID("")
    }
}

@Test func uuidWithoutDashesRejected() {
    // Foundation's UUID(uuidString:) requires dashes
    #expect(throws: (any Error).self) {
        try validateUUID("a1b2c3d4e5f67890abcdef1234567890")
    }
}

// MARK: - Session Status Validation

@Test func allValidStatusesAccepted() throws {
    for status in ["active", "paused", "inReview", "completed", "archived"] {
        try validateSessionStatus(status)
    }
}

@Test func invalidStatusRejected() {
    #expect(throws: (any Error).self) {
        try validateSessionStatus("invalid")
    }
}

@Test func statusIsCaseSensitive() {
    #expect(throws: (any Error).self) {
        try validateSessionStatus("Active")
    }
}

@Test func emptyStatusRejected() {
    #expect(throws: (any Error).self) {
        try validateSessionStatus("")
    }
}

// MARK: - Link Type Validation

@Test func allValidLinkTypesAccepted() throws {
    for linkType in ["ticket", "pr", "repo", "custom"] {
        try validateLinkType(linkType)
    }
}

@Test func invalidLinkTypeRejected() {
    #expect(throws: (any Error).self) {
        try validateLinkType("unknown")
    }
}

@Test func linkTypeIsCaseSensitive() {
    #expect(throws: (any Error).self) {
        try validateLinkType("Ticket")
    }
}

// MARK: - Set Ticket Field Validation

@Test func setTicketWithURLAccepted() throws {
    try validateSetTicketHasField(url: "https://example.com", title: nil, number: nil)
}

@Test func setTicketWithTitleAccepted() throws {
    try validateSetTicketHasField(url: nil, title: "My Ticket", number: nil)
}

@Test func setTicketWithNumberAccepted() throws {
    try validateSetTicketHasField(url: nil, title: nil, number: 42)
}

@Test func setTicketWithAllFieldsAccepted() throws {
    try validateSetTicketHasField(url: "https://example.com", title: "Ticket", number: 1)
}

@Test func setTicketWithNoFieldsRejected() {
    #expect(throws: (any Error).self) {
        try validateSetTicketHasField(url: nil, title: nil, number: nil)
    }
}

@Test func setTicketWithPriorityAloneAccepted() throws {
    // #696: --priority alone satisfies the has-field rule.
    try validateSetTicketHasField(url: nil, title: nil, number: nil, priority: "high")
}

// MARK: - Ticket Priority Validation (#696)

@Test func allValidTicketPrioritiesAccepted() throws {
    for priority in ["highest", "high", "medium", "low", "lowest"] {
        try validateTicketPriority(priority)
    }
}

@Test func ticketPriorityIsCaseInsensitive() throws {
    try validateTicketPriority("Highest")
    try validateTicketPriority("HIGH")
}

@Test func invalidTicketPriorityRejected() {
    #expect(throws: (any Error).self) {
        try validateTicketPriority("urgent")
    }
    #expect(throws: (any Error).self) {
        // `unknown` is the internal neutral, not a CLI-settable rung.
        try validateTicketPriority("unknown")
    }
}

// MARK: - Set Goal Validation (#696)

@Test func setGoalWithGoalAccepted() throws {
    try validateSetGoal(goal: "Q3 latency KPI", clear: false)
}

@Test func setGoalClearAccepted() throws {
    try validateSetGoal(goal: nil, clear: true)
}

@Test func setGoalRejectsGoalAndClearTogether() {
    #expect(throws: (any Error).self) {
        try validateSetGoal(goal: "Q3 latency KPI", clear: true)
    }
}

@Test func setGoalRejectsNeitherGoalNorClear() {
    #expect(throws: (any Error).self) {
        try validateSetGoal(goal: nil, clear: false)
    }
}

@Test func setGoalRejectsBlankGoal() {
    // A whitespace goal would silently fail to earn the on-goal multiplier.
    #expect(throws: (any Error).self) {
        try validateSetGoal(goal: "   ", clear: false)
    }
}

// MARK: - promote-allowlist patterns (#819)

@Test func allowlistPatternsAreTrimmedDedupedAndOrdered() throws {
    // First-seen order is preserved so the echoed request reads like the input.
    #expect(try normalizedAllowlistPatterns(["  Read ", "Write", "Read"]) == ["Read", "Write"])
}

@Test func allowlistPatternsKeepInternalSpacingAndGlobs() throws {
    #expect(try normalizedAllowlistPatterns(["Bash(npm run build:*)"]) == ["Bash(npm run build:*)"])
}

@Test func allowlistPatternsDropBlanksAlongsideRealOnes() throws {
    #expect(try normalizedAllowlistPatterns(["Read", "  ", ""]) == ["Read"])
}

@Test func allowlistPatternsRejectEmptyAndAllBlank() {
    // A blank pattern would be written verbatim and silently grant nothing.
    for bad in [[], ["", " "], ["\n"]] {
        #expect(throws: (any Error).self, "expected \(bad) to be rejected") {
            try normalizedAllowlistPatterns(bad)
        }
    }
}

// MARK: - Board & Workflow Validation (CROW-817)

@Test func validQuickActionsAccepted() throws {
    for action in validQuickActions {
        try validateQuickAction(action)
    }
}

@Test func invalidQuickActionRejected() {
    for bad in ["", "merge", "mergepr", "MergePR", "fix_checks"] {
        #expect(throws: (any Error).self) {
            try validateQuickAction(bad)
        }
    }
}

@Test func validIssueURLAccepted() throws {
    try validateIssueURL("https://github.com/corveil/crow/issues/817")
    try validateIssueURL("http://localhost:8080/browse/CROW-817")
}

@Test func invalidIssueURLRejected() {
    // Mirrors the daemon's `isSafeIssueURL`. Whitespace and control characters
    // matter beyond tidiness: TerminalRouter turns newlines into Enter presses,
    // so an embedded newline would split the injected prompt.
    for bad in ["", "github.com/o/r/issues/1", "ftp://example.com/x",
                "https://example.com/a b", "https://example.com/a\nrm -rf /",
                "https://example.com/a\u{7F}"] {
        #expect(throws: (any Error).self) {
            try validateIssueURL(bad)
        }
    }
}

// MARK: - Settings Ranges (CROW-814)
//
// These duplicate the server-side checks in `SettingsRPC` for fast local
// feedback — and because CrowEngine is not on CI's Linux package allow-list,
// they're the only range assertions that gate a PR.

@Test func telemetryPortAcceptsRange() throws {
    try validateTelemetryPort(1024)
    try validateTelemetryPort(4318)
    try validateTelemetryPort(65535)
}

@Test func telemetryPortRejectsOutOfRange() {
    // Below 1024 needs root; above 65535 doesn't fit TelemetryConfig's UInt16 and
    // would make config.json undecodable if it ever landed on disk.
    for bad in [0, 80, 1023, 65536, 70000, -1] {
        #expect(throws: (any Error).self, "expected port \(bad) to be rejected") {
            try validateTelemetryPort(bad)
        }
    }
}

@Test func retentionDaysAcceptsZeroAsForever() throws {
    try validateRetentionDays(0)
    try validateRetentionDays(180)
}

@Test func retentionDaysRejectsNegative() {
    #expect(throws: (any Error).self) {
        try validateRetentionDays(-1)
    }
}

@Test func retentionHoursAcceptsOneOrMore() throws {
    try validateRetentionHours(1)
    try validateRetentionHours(48) // not a UI preset — ranges, not the dropdown
}

@Test func retentionHoursRejectsZeroAndNegative() {
    // Cleanup has no "forever": 0 deletes on completion, and a negative value
    // pushes the cutoff into the future and sweeps every eligible session.
    for bad in [0, -1, -24] {
        #expect(throws: (any Error).self, "expected \(bad) hours to be rejected") {
            try validateRetentionHours(bad)
        }
    }
}

// MARK: - Defaults (CROW-810)
//
// These mirror the server-side checks in `DefaultsRPC` for fast local feedback.
// The provider/CLI lists and the branch-prefix and binary-name predicates all
// come from `ConfigDefaults` in CrowCore, so there is one source of truth rather
// than the hand-kept copy `validQuickActions` warns about.

@Test func providerAcceptsKnownForges() throws {
    try validateProvider("github")
    try validateProvider("gitlab")
}

@Test func providerRejectsUnknownAndMiscasedForges() {
    // `GitManager` compares with `==`, so "GitHub" is a real mismatch that would
    // silently fall through to the gitlab branch — not a cosmetic one.
    for bad in ["bitbucket", "GitHub", "GITLAB", "gitea", ""] {
        #expect(throws: (any Error).self, "expected provider '\(bad)' to be rejected") {
            try validateProvider(bad)
        }
    }
}

@Test func forgeCLIAcceptsKnownCLIs() throws {
    try validateForgeCLI("gh")
    try validateForgeCLI("glab")
}

@Test func forgeCLIRejectsUnknownCLIs() {
    for bad in ["hub", "GH", "git", ""] {
        #expect(throws: (any Error).self, "expected cli '\(bad)' to be rejected") {
            try validateForgeCLI(bad)
        }
    }
}

@Test func branchPrefixAcceptsValidRefPrefixes() throws {
    try validateBranchPrefix("feature/")
    try validateBranchPrefix("feat/")
    try validateBranchPrefix("")            // empty means "no prefix"
    try validateBranchPrefix("  feature/ ") // trimmed before validating
}

@Test func branchPrefixRejectsWhatGitWouldRefuse() {
    for bad in ["bad..prefix", "has space/", "tilde~/", "caret^/", "colon:/",
                "question?/", "star*/", "bracket[/", "trailing.", "at@{x}/"] {
        #expect(throws: (any Error).self, "expected prefix '\(bad)' to be rejected") {
            try validateBranchPrefix(bad)
        }
    }
}

@Test func normalizedListValuesTrimsDropsBlanksAndDedupes() throws {
    // Case-insensitive, unlike `normalizedAllowlistPatterns`: these values are
    // matched case-insensitively by their consumers, so `Owner/Repo` and
    // `owner/repo` are one entry. First-seen casing wins.
    #expect(try normalizedListValues(
        ["  acme/docs  ", "acme/docs", "ACME/DOCS", "   ", "acme/api"], flag: "--add-x")
        == ["acme/docs", "acme/api"])
}

@Test func normalizedListValuesRejectsAnAllBlankFlag() {
    for raw in [[""], ["   "], ["", "  "]] {
        #expect(throws: (any Error).self, "expected \(raw) to be rejected") {
            _ = try normalizedListValues(raw, flag: "--add-x")
        }
    }
}

// MARK: - Workspace validators (CROW-809)

@Test func workspaceProviderAcceptsCodeHostsOnly() throws {
    for provider in WorkspaceInfo.validProviders { try validateWorkspaceProvider(provider) }
    try validateWorkspaceProvider("  github  ")
    // Jira and Corveil are task-only — they have no git surface.
    for bad in ["jira", "corveil", "bitbucket", "", "GitHub"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            try validateWorkspaceProvider(bad)
        }
    }
}

@Test func workspaceTaskProviderAcceptsEveryProviderAndBlank() throws {
    for provider in WorkspaceInfo.validTaskProviders { try validateWorkspaceTaskProvider(provider) }
    // Blank is the Settings dropdown's "follow the code provider" option.
    try validateWorkspaceTaskProvider("")
    try validateWorkspaceTaskProvider("   ")
    #expect(throws: (any Error).self) { try validateWorkspaceTaskProvider("trello") }
}

/// The provider lists come from the model, so a new `Provider` case reaches the
/// CLI's rejection messages without a second edit.
@Test func workspaceProviderErrorsListTheValidValues() {
    do {
        try validateWorkspaceProvider("bitbucket")
        Issue.record("expected a throw")
    } catch {
        let message = String(describing: error)
        for provider in WorkspaceInfo.validProviders { #expect(message.contains(provider)) }
    }
}

@Test func sessionEnvEntryAcceptsKeyValuePairs() throws {
    try validateSessionEnvEntry("AWS_PROFILE=dev")
    // An env var set to the empty string differs meaningfully from an unset one.
    try validateSessionEnvEntry("EMPTY=")
    // Only the first '=' separates, so a value may contain more.
    try validateSessionEnvEntry("DSN=postgres://u:p@h/db?a=1&b=2")
}

@Test func sessionEnvEntryRejectsMalformedInput() {
    for bad in ["NOEQUALS", "", "=novalue", "   =v"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            try validateSessionEnvEntry(bad)
        }
    }
}

/// The value is exported into the agent's shell environment, where an embedded
/// newline would read as a second statement — same hazard as a header line.
@Test func sessionEnvEntryRejectsEmbeddedNewlines() {
    for bad in ["K=v\nINJECTED=x", "K=v\r\nINJECTED=x", "K=v\rx"] {
        #expect(throws: (any Error).self) { try validateSessionEnvEntry(bad) }
    }
}

/// A key no shell can reference is an entry that can never be read back. The CLI
/// can't produce a key containing `=` (it splits on the first one), but it can
/// produce one containing a space — so this is the half of
/// `WorkspaceRPC.decodeSessionEnv`'s key rules that the CLI can actually reach.
@Test func sessionEnvEntryRejectsUnaddressableKeys() {
    for bad in ["FOO BAR=v", "FOO\tBAR=v", "FOO\u{0}BAR=v"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            try validateSessionEnvEntry(bad)
        }
    }
    // Surrounding space is a typo, not a bad name — `parseSessionEnv` trims it.
    #expect(throws: Never.self) { try validateSessionEnvEntry("  AWS_PROFILE  =dev") }
}

// MARK: - Gateway header lines (CROW-969)

@Test func headerLineAcceptsWellFormedValues() throws {
    try validateHeaderLine("X-Api-Key: sk-1")
    // Blank value = "keep the secret already stored for this header", which is
    // how a base URL is changed without restating the key.
    try validateHeaderLine("X-Api-Key:")
    try validateHeaderLine("X-Api-Key: op://Vault/Item/field")
    // Quotes are only a problem when they wrap the whole value.
    try validateHeaderLine("X-Json: {\"a\":1}")
    try validateHeaderLine("X-Api-Key: Bearer \"quoted\"-inside")
}

/// A value the shell left literally quoted reaches the gateway with its quotes
/// intact and is rejected — surfacing as a bare "API error" that names nothing.
@Test func headerLineRejectsQuoteWrappedValues() {
    for bad in [
        "X-Api-Key: \"sk-1\"",
        "X-Api-Key: 'sk-1'",
        // Worst case: the quotes defeat `hasPrefix("op://")`, so the reference is
        // never resolved and the literal string is sent instead.
        "X-Api-Key: \"op://Vault/Item/field\"",
    ] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            try validateHeaderLine(bad)
        }
    }
}

/// Quoting the whole pair splits into a name and value where *neither half* is
/// individually wrapped — so only the header-name rule catches this one.
@Test func headerLineRejectsWholeLineQuoted() {
    for bad in ["\"X-Api-Key: sk-1\"", "'X-Api-Key: sk-1'"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            try validateHeaderLine(bad)
        }
    }
}

/// A header value is a credential and an ArgumentParser error prints to the
/// terminal, so the new messages name the header and never quote its value.
@Test func headerLineErrorNamesTheHeaderNotTheSecret() {
    do {
        try validateHeaderLine("X-Api-Key: \"sk-SECRET\"")
        Issue.record("expected a throw")
    } catch {
        let message = String(describing: error)
        #expect(message.contains("X-Api-Key"))
        #expect(!message.contains("sk-SECRET"))
    }
}
