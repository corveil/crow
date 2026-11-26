import CrowIPC
import Foundation
import Testing
@testable import CrowCLILib

// MARK: - crow send cold-cache warning (CROW-1499)

private let agentTerminal = "B1B2C3D4-E5F6-7890-ABCD-EF1234567890"

/// A `get-session` result as the daemon prints it, with a `context` object.
private func getSession(
    tokens: JSONValue = .int(704_312), large: JSONValue = .bool(true), expired: JSONValue = .bool(true),
    idle: JSONValue = .int(3 * 3600 + 120), context: Bool = true
) -> AgentWait.Snapshot {
    var result: [String: JSONValue] = [
        "agent_state": .string("idle"),
        "agent_terminal_id": .string(agentTerminal),
    ]
    result["context"] = context ? .object([
        "tokens": tokens, "max_tokens": .int(1_000_000), "large": large, "cache_expired": expired,
        "idle_seconds": idle, "cache_ttl_seconds": .int(3600),
    ]) : .null
    return AgentWait.Snapshot(result)
}

@Test func coldLargeSessionWarnsWithTheTokenCount() {
    let message = ColdCacheWarning.message(for: getSession(), terminal: agentTerminal)
    #expect(message == "sent into a cold session: its prompt cache had expired (idle 3h 2m), so this message "
        + "re-writes all 704,312 tokens of context to the cache. See context in crow get-session.")
}

@Test func theTerminalIDMatchesCaseInsensitively() {
    #expect(ColdCacheWarning.message(for: getSession(), terminal: agentTerminal.lowercased()) != nil)
}

@Test func noWarningUnlessLargeAndExpired() {
    #expect(ColdCacheWarning.message(for: getSession(expired: .bool(false)), terminal: agentTerminal) == nil)
    #expect(ColdCacheWarning.message(for: getSession(large: .bool(false)), terminal: agentTerminal) == nil)
    // Unknown cache state (no TTL or no last request recorded) is not "expired".
    #expect(ColdCacheWarning.message(for: getSession(expired: .null), terminal: agentTerminal) == nil)
    #expect(ColdCacheWarning.message(for: getSession(tokens: .null), terminal: agentTerminal) == nil)
    #expect(ColdCacheWarning.message(for: getSession(context: false), terminal: agentTerminal) == nil)
}

@Test func noWarningForANonAgentTerminal() {
    // A shell tab never reaches the model, so its session's cache is beside the point.
    #expect(ColdCacheWarning.message(
        for: getSession(), terminal: "C1B2C3D4-E5F6-7890-ABCD-EF1234567890") == nil)
    var noAgent = getSession()
    noAgent.agentTerminalID = nil
    #expect(ColdCacheWarning.message(for: noAgent, terminal: agentTerminal) == nil)
}

@Test func theIdleClauseIsOptional() {
    let message = ColdCacheWarning.message(for: getSession(idle: .null), terminal: agentTerminal)
    #expect(message?.hasPrefix("sent into a cold session: its prompt cache had expired, so") == true)
}

@Test func noDollarFigure() {
    // Acceptance (#1499): token counts only; the repo has no price table.
    let message = ColdCacheWarning.message(for: getSession(), terminal: agentTerminal) ?? ""
    #expect(!message.contains("$"))
}

@Test func idleAndTokenFormatting() {
    #expect(ColdCacheWarning.formatIdle(45 * 60) == "45m")
    #expect(ColdCacheWarning.formatIdle(3 * 3600 + 120) == "3h 2m")
    #expect(ColdCacheWarning.formatIdle(3 * 86400) == "3d")
    #expect(ColdCacheWarning.groupThousands(999) == "999")
    #expect(ColdCacheWarning.groupThousands(1_000) == "1,000")
    #expect(ColdCacheWarning.groupThousands(1_234_567) == "1,234,567")
}

@Test func snapshotCarriesTheContextObject() {
    #expect(getSession().context?["large"] == .bool(true))
    #expect(getSession(context: false).context == nil)
}
