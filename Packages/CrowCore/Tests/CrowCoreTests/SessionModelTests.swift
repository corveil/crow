import Foundation
import Testing
@testable import CrowCore

// MARK: - Session Model

@Test func sessionDefaultValues() {
    let session = Session(name: "test")
    #expect(session.status == .active)
    #expect(session.ticketURL == nil)
    #expect(session.ticketTitle == nil)
    #expect(session.ticketNumber == nil)
    #expect(session.provider == nil)
    #expect(session.createdAt <= Date())
    #expect(session.updatedAt <= Date())
}

@Test func sessionCodableRoundTrip() throws {
    let session = Session(
        name: "full-session",
        status: .inReview,
        ticketURL: "https://github.com/org/repo/issues/42",
        ticketTitle: "Fix the thing",
        ticketNumber: 42,
        provider: .github
    )
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(Session.self, from: data)

    #expect(decoded.id == session.id)
    #expect(decoded.name == "full-session")
    #expect(decoded.status == .inReview)
    #expect(decoded.ticketURL == "https://github.com/org/repo/issues/42")
    #expect(decoded.ticketTitle == "Fix the thing")
    #expect(decoded.ticketNumber == 42)
    #expect(decoded.provider == .github)
}

@Test func sessionCodableWithNilOptionals() throws {
    let session = Session(name: "minimal")
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(Session.self, from: data)

    #expect(decoded.name == "minimal")
    #expect(decoded.ticketURL == nil)
    #expect(decoded.ticketTitle == nil)
    #expect(decoded.ticketNumber == nil)
    #expect(decoded.provider == nil)
}

@Test func sessionBackwardCompatDecodingLastReviewedHeadSha() throws {
    // Persisted state.json predating CROW-290 has no `lastReviewedHeadSha`.
    // Decode must succeed and default the field to nil.
    let id = UUID()
    let date = Date()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let dateStr = formatter.string(from: date)
    let json: [String: Any] = [
        "id": id.uuidString,
        "name": "legacy",
        "status": "active",
        "kind": "review",
        "createdAt": dateStr,
        "updatedAt": dateStr,
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let session = try decoder.decode(Session.self, from: data)
    #expect(session.lastReviewedHeadSha == nil)
    #expect(session.kind == .review)
}

@Test func sessionRoundTripsLastReviewedHeadSha() throws {
    let session = Session(
        name: "review",
        kind: .review,
        lastReviewedHeadSha: "deadbeef"
    )
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(Session.self, from: data)
    #expect(decoded.lastReviewedHeadSha == "deadbeef")
}

// MARK: - Enum Raw Values

@Test func sessionStatusRawValues() {
    #expect(SessionStatus.active.rawValue == "active")
    #expect(SessionStatus.paused.rawValue == "paused")
    #expect(SessionStatus.inReview.rawValue == "inReview")
    #expect(SessionStatus.completed.rawValue == "completed")
    #expect(SessionStatus.archived.rawValue == "archived")
}

@Test func providerRawValues() {
    #expect(Provider.github.rawValue == "github")
    #expect(Provider.gitlab.rawValue == "gitlab")
}

@Test func linkTypeRawValues() {
    #expect(LinkType.ticket.rawValue == "ticket")
    #expect(LinkType.pr.rawValue == "pr")
    #expect(LinkType.repo.rawValue == "repo")
    #expect(LinkType.custom.rawValue == "custom")
}

// MARK: - SessionTerminal

@Test func terminalDefaultValues() {
    let sessionID = UUID()
    let terminal = SessionTerminal(sessionID: sessionID, cwd: "/tmp")
    #expect(terminal.name == "Shell")
    #expect(terminal.isManaged == false)
    #expect(terminal.command == nil)
    #expect(terminal.sessionID == sessionID)
}

@Test func terminalBackwardCompatDecoding() throws {
    // JSON without isManaged field (simulating old data)
    let id = UUID()
    let sessionID = UUID()
    let date = Date()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970

    // Manually construct JSON without isManaged
    let json: [String: Any] = [
        "id": id.uuidString,
        "sessionID": sessionID.uuidString,
        "name": "Claude Code",
        "cwd": "/work",
        "createdAt": date.timeIntervalSince1970
    ]
    let data = try JSONSerialization.data(withJSONObject: json)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let terminal = try decoder.decode(SessionTerminal.self, from: data)

    #expect(terminal.isManaged == false)
    #expect(terminal.name == "Claude Code")
    #expect(terminal.command == nil)
}

// MARK: - SessionWorktree

@Test func worktreeDefaultValues() {
    let sessionID = UUID()
    let wt = SessionWorktree(
        sessionID: sessionID, repoName: "crow", repoPath: "/repo",
        worktreePath: "/wt", branch: "feature/x"
    )
    #expect(wt.isPrimary == false)
    #expect(wt.sessionID == sessionID)
}

// MARK: - SessionLink

@Test func linkFieldVerification() {
    let sessionID = UUID()
    let link = SessionLink(sessionID: sessionID, label: "PR #1", url: "https://github.com/org/repo/pull/1", linkType: .pr)
    #expect(link.label == "PR #1")
    #expect(link.url == "https://github.com/org/repo/pull/1")
    #expect(link.linkType == .pr)
    #expect(link.sessionID == sessionID)
}
