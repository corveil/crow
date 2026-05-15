import Foundation
import Testing
@testable import CrowCore

// MARK: - AppState Lookup Tests

@MainActor @Test func assignedIssueForSessionMatchesByTicketURL() {
    let appState = AppState()
    let issue = AssignedIssue(
        id: "github:org/repo#42", number: 42, title: "Bug fix",
        state: "open", url: "https://github.com/org/repo/issues/42",
        repo: "org/repo", labels: [LabelInfo(name: "bug", color: "d73a4a"), LabelInfo(name: "priority")], provider: .github
    )
    appState.assignedIssues = [issue]
    let session = Session(name: "fix-bug", ticketURL: "https://github.com/org/repo/issues/42")
    let result = appState.assignedIssue(for: session)
    #expect(result?.id == "github:org/repo#42")
    #expect(result?.labels == [LabelInfo(name: "bug", color: "d73a4a"), LabelInfo(name: "priority")])
}

@MainActor @Test func assignedIssueForSessionReturnsNilWithoutTicketURL() {
    let appState = AppState()
    appState.assignedIssues = [
        AssignedIssue(
            id: "github:org/repo#1", number: 1, title: "T",
            state: "open", url: "https://github.com/org/repo/issues/1",
            repo: "org/repo", provider: .github
        )
    ]
    let session = Session(name: "no-ticket")
    #expect(appState.assignedIssue(for: session) == nil)
}

@MainActor @Test func assignedIssueForSessionReturnsNilWhenNoMatch() {
    let appState = AppState()
    appState.assignedIssues = [
        AssignedIssue(
            id: "github:org/repo#1", number: 1, title: "T",
            state: "open", url: "https://github.com/org/repo/issues/1",
            repo: "org/repo", provider: .github
        )
    ]
    let session = Session(name: "other", ticketURL: "https://github.com/org/repo/issues/99")
    #expect(appState.assignedIssue(for: session) == nil)
}

@MainActor @Test func reviewRequestForSessionMatchesByPRLink() {
    let appState = AppState()
    let session = Session(name: "review-repo-123", kind: .review)
    let prLink = SessionLink(
        sessionID: session.id, label: "PR #123",
        url: "https://github.com/org/repo/pull/123", linkType: .pr
    )
    appState.links[session.id] = [prLink]
    let request = ReviewRequest(
        id: "github:org/repo#123", prNumber: 123, title: "Fix",
        url: "https://github.com/org/repo/pull/123",
        repo: "org/repo", author: "alice", headBranch: "fix-branch",
        baseBranch: "main", labels: [LabelInfo(name: "bug", color: "d73a4a"), LabelInfo(name: "urgent", color: "e4e669")]
    )
    appState.reviewRequests = [request]
    let result = appState.reviewRequest(for: session)
    #expect(result?.labels == [LabelInfo(name: "bug", color: "d73a4a"), LabelInfo(name: "urgent", color: "e4e669")])
}

@MainActor @Test func reviewRequestForSessionReturnsNilForWorkSessions() {
    let appState = AppState()
    let session = Session(name: "work-session", kind: .work)
    #expect(appState.reviewRequest(for: session) == nil)
}

@MainActor @Test func labelsForSessionReturnsIssueLabels() {
    let appState = AppState()
    let issue = AssignedIssue(
        id: "github:org/repo#1", number: 1, title: "T",
        state: "open", url: "https://github.com/org/repo/issues/1",
        repo: "org/repo", labels: [LabelInfo(name: "enhancement", color: "a2eeef"), LabelInfo(name: "ui")], provider: .github
    )
    appState.assignedIssues = [issue]
    let session = Session(name: "s", ticketURL: "https://github.com/org/repo/issues/1")
    #expect(appState.labels(forSession: session) == [LabelInfo(name: "enhancement", color: "a2eeef"), LabelInfo(name: "ui")])
}

@MainActor @Test func labelsForSessionReturnsReviewLabels() {
    let appState = AppState()
    let session = Session(name: "review-s", kind: .review)
    let prLink = SessionLink(
        sessionID: session.id, label: "PR #5",
        url: "https://github.com/org/repo/pull/5", linkType: .pr
    )
    appState.links[session.id] = [prLink]
    let request = ReviewRequest(
        id: "github:org/repo#5", prNumber: 5, title: "PR",
        url: "https://github.com/org/repo/pull/5",
        repo: "org/repo", author: "bob", headBranch: "feat",
        baseBranch: "main", labels: [LabelInfo(name: "needs-review", color: "0075ca")]
    )
    appState.reviewRequests = [request]
    #expect(appState.labels(forSession: session) == [LabelInfo(name: "needs-review", color: "0075ca")])
}

@MainActor @Test func labelsForSessionReturnsEmptyWhenNoMatch() {
    let appState = AppState()
    let session = Session(name: "s")
    #expect(appState.labels(forSession: session).isEmpty)
}

// MARK: - LabelInfo Tests

@Test func labelInfoCodableRoundTripWithColor() throws {
    let label = LabelInfo(name: "bug", color: "d73a4a")
    let data = try JSONEncoder().encode(label)
    let decoded = try JSONDecoder().decode(LabelInfo.self, from: data)
    #expect(decoded.name == "bug")
    #expect(decoded.color == "d73a4a")
}

@Test func labelInfoCodableRoundTripWithoutColor() throws {
    let label = LabelInfo(name: "enhancement")
    let data = try JSONEncoder().encode(label)
    let decoded = try JSONDecoder().decode(LabelInfo.self, from: data)
    #expect(decoded.name == "enhancement")
    #expect(decoded.color == nil)
}

@Test func labelInfoEquality() {
    let a = LabelInfo(name: "bug", color: "d73a4a")
    let b = LabelInfo(name: "bug", color: "d73a4a")
    let c = LabelInfo(name: "bug", color: "ff0000")
    let d = LabelInfo(name: "bug")
    #expect(a == b)
    #expect(a != c)
    #expect(a != d)
}
