import Foundation
import Testing
@testable import CrowCore

// Coverage for Phase B's `AppConfig.defaultAgentKind` field.

@Test func appConfigDefaultAgentKindIsClaudeCode() {
    let config = AppConfig()
    #expect(config.defaultAgentKind == .claudeCode)
}

@Test func appConfigDefaultAgentKindRoundTrip() throws {
    var config = AppConfig()
    config.defaultAgentKind = AgentKind(rawValue: "codex")

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

    #expect(decoded.defaultAgentKind == AgentKind(rawValue: "codex"))
}

@Test func appConfigLegacyJSONWithoutDefaultAgentKindUsesClaudeCode() throws {
    // Simulates a config.json written before Phase B existed. The field must
    // default to `.claudeCode` on decode so the app keeps booting.
    let json = """
    {
      "workspaces": [],
      "remoteControlEnabled": true
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.defaultAgentKind == .claudeCode)
    #expect(config.remoteControlEnabled == true)
}
