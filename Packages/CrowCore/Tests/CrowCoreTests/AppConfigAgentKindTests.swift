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

// CROW-421: per-action agent selection.

@Test func appConfigAgentsByKindDefaultsToEmpty() {
    let config = AppConfig()
    #expect(config.agentsByKind.isEmpty)
}

@Test func appConfigAgentsByKindRoundTrip() throws {
    var config = AppConfig()
    config.agentsByKind["review"] = AgentKind(rawValue: "codex")
    config.agentsByKind["job"] = AgentKind(rawValue: "cursor")

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

    #expect(decoded.agentsByKind["review"] == AgentKind(rawValue: "codex"))
    #expect(decoded.agentsByKind["job"] == AgentKind(rawValue: "cursor"))
}

@Test func appConfigAgentsByKindSerializesAsJSONObject() throws {
    // Storing the map as `[String: AgentKind]` rather than
    // `[SessionKind: AgentKind]` is intentional: Swift's JSONEncoder only
    // emits dictionaries with String/Int keys as JSON objects.
    var config = AppConfig()
    config.agentsByKind["review"] = AgentKind(rawValue: "codex")

    let data = try JSONEncoder().encode(config)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let agentsByKind = try #require(json["agentsByKind"] as? [String: String])
    #expect(agentsByKind["review"] == "codex")
}

@Test func appConfigLegacyJSONWithoutAgentsByKindIsEmpty() throws {
    let json = """
    {
      "workspaces": [],
      "defaultAgentKind": "codex"
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.agentsByKind.isEmpty)
    // Resolver falls back to defaultAgentKind for every kind when the map is empty.
    #expect(config.agentKind(for: .work) == AgentKind(rawValue: "codex"))
    #expect(config.agentKind(for: .review) == AgentKind(rawValue: "codex"))
    #expect(config.agentKind(for: .job) == AgentKind(rawValue: "codex"))
}

@Test func appConfigAgentResolverReturnsOverrideWhenSet() {
    var config = AppConfig(defaultAgentKind: .claudeCode)
    config.agentsByKind["review"] = AgentKind(rawValue: "codex")
    #expect(config.agentKind(for: .review) == AgentKind(rawValue: "codex"))
    // Other kinds still use the default.
    #expect(config.agentKind(for: .work) == .claudeCode)
    #expect(config.agentKind(for: .job) == .claudeCode)
}

@Test func appConfigAgentResolverPinsManagerToClaudeCode() {
    var config = AppConfig(defaultAgentKind: AgentKind(rawValue: "codex"))
    // Even if someone hand-edits the map to override manager, it's ignored.
    config.agentsByKind["manager"] = AgentKind(rawValue: "cursor")
    #expect(config.agentKind(for: .manager) == .claudeCode)
}
