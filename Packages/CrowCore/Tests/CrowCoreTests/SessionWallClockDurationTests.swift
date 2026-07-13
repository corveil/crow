import Foundation
import Testing
@testable import CrowCore

// #692 (ADR 0008 follow-up 4): agent wall-clock lifecycle stamps on Session.
// Wall-clock duration is DISPLAY-ONLY context — SessionAnalytics.activeTimeSeconds
// is the authoritative clock for penalty normalization, and these tests lock in
// the boundary semantics that keep the two roles distinct.

private func makeSession() -> Session {
    Session(name: "wall-clock")
}

@Test func firstSessionStartWins() {
    var session = makeSession()
    let first = Date(timeIntervalSince1970: 1_752_000_000)
    session.recordAgentSessionStart(at: first)
    // A resume/clear/compact SessionStart must not move the origin.
    session.recordAgentSessionStart(at: first.addingTimeInterval(600))
    #expect(session.agentSessionStartedAt == first)
}

@Test func sessionStartClearsStaleEnd() {
    var session = makeSession()
    let start = Date(timeIntervalSince1970: 1_752_000_000)
    session.recordAgentSessionStart(at: start)
    session.recordAgentSessionEnd(at: start.addingTimeInterval(1_200))
    // The agent resumes: a finished-looking duration would be a lie, so the
    // session reads as open-ended again until the next SessionEnd.
    session.recordAgentSessionStart(at: start.addingTimeInterval(7_200))
    #expect(session.agentSessionEndedAt == nil)
    #expect(session.wallClockDuration == nil)
    #expect(session.agentSessionStartedAt == start)
}

@Test func lastSessionEndWins() {
    var session = makeSession()
    let start = Date(timeIntervalSince1970: 1_752_000_000)
    session.recordAgentSessionStart(at: start)
    session.recordAgentSessionEnd(at: start.addingTimeInterval(60))
    session.recordAgentSessionEnd(at: start.addingTimeInterval(3_600))
    #expect(session.wallClockDuration == 3_600)
}

@Test func durationNilWithoutEnd() {
    var session = makeSession()
    session.recordAgentSessionStart(at: Date(timeIntervalSince1970: 1_752_000_000))
    // Open-ended: no SessionEnd yet, or an agent (Codex/Cursor/OpenCode) that
    // never sends one. No fabricated duration.
    #expect(session.wallClockDuration == nil)
}

@Test func durationNilWithoutStart() {
    var session = makeSession()
    session.recordAgentSessionEnd(at: Date(timeIntervalSince1970: 1_752_000_000))
    #expect(session.wallClockDuration == nil)
}

@Test func durationNilWhenEndBeforeStart() {
    // Host clock skew must not render a negative duration.
    var session = makeSession()
    let start = Date(timeIntervalSince1970: 1_752_000_000)
    session.recordAgentSessionStart(at: start)
    session.agentSessionEndedAt = start.addingTimeInterval(-30)
    #expect(session.wallClockDuration == nil)
}

@Test func wallClockDistinctFromActiveTime() {
    // The ADR's core split: an idle-overnight session has a huge wall-clock
    // span but tiny active time. The two must never be conflated — wall-clock
    // is display-only, activeTimeSeconds is the penalty denominator.
    var session = makeSession()
    let start = Date(timeIntervalSince1970: 1_752_000_000)
    session.recordAgentSessionStart(at: start)
    session.recordAgentSessionEnd(at: start.addingTimeInterval(28_800)) // 8h wall-clock
    let analytics = SessionAnalytics(activeTimeSeconds: 300) // 5m active
    #expect(session.wallClockDuration == 28_800)
    #expect(analytics.activeTimeSeconds == 300)
    #expect(session.wallClockDuration != analytics.activeTimeSeconds)
}

@Test func sessionWallClockJSONRoundTrip() throws {
    // Whole-second dates: the store's ISO8601 strategy drops sub-second
    // precision, and this test locks in the same encoder configuration.
    let start = Date(timeIntervalSince1970: 1_752_000_000)
    let session = Session(
        name: "round-trip",
        agentSessionStartedAt: start,
        agentSessionEndedAt: start.addingTimeInterval(4_500)
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(Session.self, from: encoder.encode(session))
    #expect(decoded.agentSessionStartedAt == start)
    #expect(decoded.agentSessionEndedAt == start.addingTimeInterval(4_500))
    #expect(decoded.wallClockDuration == 4_500)
}

@Test func sessionBackwardCompatDecodingWithoutWallClockFields() throws {
    // Persisted state.json predating #692 has no lifecycle stamps. Decode
    // must succeed and default both fields to nil (open-ended, no bogus
    // duration).
    let id = UUID()
    let date = Date()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let dateStr = formatter.string(from: date)
    let json: [String: Any] = [
        "id": id.uuidString,
        "name": "legacy",
        "status": "active",
        "kind": "work",
        "createdAt": dateStr,
        "updatedAt": dateStr,
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let session = try decoder.decode(Session.self, from: data)
    #expect(session.agentSessionStartedAt == nil)
    #expect(session.agentSessionEndedAt == nil)
    #expect(session.wallClockDuration == nil)
}
