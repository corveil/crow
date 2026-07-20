import Foundation
import Testing
@testable import CrowCore

// MARK: - AssignedIssue Tests

@Test func assignedIssueCodableRoundTrip() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let issue = AssignedIssue(
        id: "github:corveil/crow#64",
        number: 64,
        title: "Expand test coverage",
        state: "open",
        url: "https://github.com/corveil/crow/issues/64",
        repo: "corveil/crow",
        labels: [LabelInfo(name: "enhancement", color: "a2eeef"), LabelInfo(name: "testing")],
        provider: .github,
        prNumber: 100,
        prURL: "https://github.com/corveil/crow/pull/100",
        updatedAt: date,
        projectStatus: .inProgress
    )
    let data = try JSONEncoder().encode(issue)
    let decoded = try JSONDecoder().decode(AssignedIssue.self, from: data)
    #expect(decoded.id == "github:corveil/crow#64")
    #expect(decoded.number == 64)
    #expect(decoded.title == "Expand test coverage")
    #expect(decoded.state == "open")
    #expect(decoded.labels == [LabelInfo(name: "enhancement", color: "a2eeef"), LabelInfo(name: "testing")])
    #expect(decoded.provider == .github)
    #expect(decoded.prNumber == 100)
    #expect(decoded.prURL == "https://github.com/corveil/crow/pull/100")
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

// #696: priority + epic/parent ride the model as additive optionals.

@Test func assignedIssueRoundTripsPriorityAndParent() throws {
    let issue = AssignedIssue(
        id: "jira:MAXX-1", number: 1, title: "T", state: "open",
        url: "https://acme.atlassian.net/browse/MAXX-1", repo: "MAXX",
        provider: .jira,
        priority: .high, priorityName: "Critical",
        parentKey: "MAXX-100", parentSummary: "Q3 latency epic"
    )
    let data = try JSONEncoder().encode(issue)
    let decoded = try JSONDecoder().decode(AssignedIssue.self, from: data)
    #expect(decoded.priority == .high)
    #expect(decoded.priorityName == "Critical")
    #expect(decoded.parentKey == "MAXX-100")
    #expect(decoded.parentSummary == "Q3 latency epic")
}

@Test func assignedIssueLegacyJSONWithoutAlignmentFieldsDecodes() throws {
    // Persisted AppState predating #696 has none of the new keys; synthesized
    // Codable must surface them as nil, not fail.
    let json: [String: Any] = [
        "id": "github:o/r#7",
        "number": 7,
        "title": "Legacy",
        "state": "open",
        "url": "https://github.com/o/r/issues/7",
        "repo": "o/r",
        "labels": [],
        "provider": "github",
        "projectStatus": "In Progress",
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let decoded = try JSONDecoder().decode(AssignedIssue.self, from: data)
    #expect(decoded.priority == nil)
    #expect(decoded.priorityName == nil)
    #expect(decoded.parentKey == nil)
    #expect(decoded.parentSummary == nil)
    #expect(decoded.projectStatus == .inProgress)
}
