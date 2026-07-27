import Testing
import Foundation
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
