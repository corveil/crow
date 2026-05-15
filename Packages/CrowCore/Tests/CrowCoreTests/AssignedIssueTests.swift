import Foundation
import Testing
@testable import CrowCore

// MARK: - AssignedIssue Tests

@Test func assignedIssueCodableRoundTrip() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let issue = AssignedIssue(
        id: "github:radiusmethod/crow#64",
        number: 64,
        title: "Expand test coverage",
        state: "open",
        url: "https://github.com/radiusmethod/crow/issues/64",
        repo: "radiusmethod/crow",
        labels: [LabelInfo(name: "enhancement", color: "a2eeef"), LabelInfo(name: "testing")],
        provider: .github,
        prNumber: 100,
        prURL: "https://github.com/radiusmethod/crow/pull/100",
        updatedAt: date,
        projectStatus: .inProgress
    )
    let data = try JSONEncoder().encode(issue)
    let decoded = try JSONDecoder().decode(AssignedIssue.self, from: data)
    #expect(decoded.id == "github:radiusmethod/crow#64")
    #expect(decoded.number == 64)
    #expect(decoded.title == "Expand test coverage")
    #expect(decoded.state == "open")
    #expect(decoded.labels == [LabelInfo(name: "enhancement", color: "a2eeef"), LabelInfo(name: "testing")])
    #expect(decoded.provider == .github)
    #expect(decoded.prNumber == 100)
    #expect(decoded.prURL == "https://github.com/radiusmethod/crow/pull/100")
    #expect(decoded.updatedAt == date)
    #expect(decoded.projectStatus == .inProgress)
}

@Test func assignedIssueCodableNilOptionals() throws {
    let issue = AssignedIssue(
        id: "gitlab:host:org/repo#5",
        number: 5,
        title: "Bug",
        state: "open",
        url: "https://gitlab.com/org/repo/-/issues/5",
        repo: "org/repo",
        provider: .gitlab
    )
    let data = try JSONEncoder().encode(issue)
    let decoded = try JSONDecoder().decode(AssignedIssue.self, from: data)
    #expect(decoded.prNumber == nil)
    #expect(decoded.prURL == nil)
    #expect(decoded.updatedAt == nil)
}

@Test func assignedIssueDefaultProjectStatus() {
    let issue = AssignedIssue(
        id: "github:o/r#1", number: 1, title: "T", state: "open",
        url: "u", repo: "o/r", provider: .github
    )
    #expect(issue.projectStatus == .unknown)
}
