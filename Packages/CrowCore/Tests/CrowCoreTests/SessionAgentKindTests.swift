import Foundation
import Testing
@testable import CrowCore

// Coverage for the Phase B addition of `Session.agentKind`. The most
// important property is backward compatibility: a `sessions.json` written
// before this field existed must continue to load.

@Test func sessionDefaultAgentKindIsClaudeCode() {
    let session = Session(name: "test")
    #expect(session.agentKind == .claudeCode)
}

@Test func sessionAgentKindRoundTrip() throws {
    let session = Session(
        name: "codex-session",
        agentKind: AgentKind(rawValue: "codex")
    )
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(Session.self, from: data)

    #expect(decoded.agentKind == AgentKind(rawValue: "codex"))
    #expect(decoded.agentKind.rawValue == "codex")
}

@Test func sessionCustomAgentKindRoundTripPreservesRawValue() throws {
    let original = Session(name: "aider", agentKind: AgentKind(rawValue: "aider"))
    let data = try JSONEncoder().encode(original)

    // Inspect the on-disk shape directly: the persisted `agentKind` field
    // must be a plain string so future-phase consumers don't need to know
    // the struct's encoding.
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["agentKind"] as? String == "aider")
}

@Test func sessionLegacyJSONWithoutAgentKindDecodesToClaudeCode() throws {
    // Simulates a Session record written before Phase B existed: no
    // `agentKind` key at all. Must decode cleanly to `.claudeCode`.
    let id = UUID()
    let date = Date()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let dateString = ISO8601DateFormatter().string(from: date)

    let json: [String: Any] = [
        "id": id.uuidString,
        "name": "legacy-session",
        "status": "active",
        "createdAt": dateString,
        "updatedAt": dateString,
    ]
    let data = try JSONSerialization.data(withJSONObject: json)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let session = try decoder.decode(Session.self, from: data)

    #expect(session.agentKind == .claudeCode)
    #expect(session.name == "legacy-session")
}
