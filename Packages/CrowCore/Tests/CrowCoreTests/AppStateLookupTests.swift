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

// MARK: - linkedSession(for:) — broadened matching (#533)

@MainActor @Test func linkedSessionMatchesActiveGitHubByExactURL() {
    let appState = AppState()
    let issue = AssignedIssue(
        id: "github:org/repo#42", number: 42, title: "Bug",
        state: "open", url: "https://github.com/org/repo/issues/42",
        repo: "org/repo", provider: .github
    )
    let session = Session(name: "fix", status: .active, ticketURL: "https://github.com/org/repo/issues/42", provider: .github)
    appState.sessions = [session]
    #expect(appState.linkedSession(for: issue)?.id == session.id)
}

@MainActor @Test func linkedSessionMatchesInReviewAndPausedSessions() {
    let appState = AppState()
    let issue = AssignedIssue(
        id: "github:org/repo#7", number: 7, title: "T",
        state: "open", url: "https://github.com/org/repo/issues/7",
        repo: "org/repo", provider: .github
    )
    // In Review session — would NOT match under the old `.active`-only scan.
    let inReview = Session(name: "ir", status: .inReview, ticketURL: "https://github.com/org/repo/issues/7", provider: .github)
    appState.sessions = [inReview]
    #expect(appState.linkedSession(for: issue)?.id == inReview.id)

    let paused = Session(name: "p", status: .paused, ticketURL: "https://github.com/org/repo/issues/7", provider: .github)
    appState.sessions = [paused]
    #expect(appState.linkedSession(for: issue)?.id == paused.id)
}

@MainActor @Test func linkedSessionExcludesTerminalSessions() {
    let appState = AppState()
    let issue = AssignedIssue(
        id: "github:org/repo#7", number: 7, title: "T",
        state: "open", url: "https://github.com/org/repo/issues/7",
        repo: "org/repo", provider: .github
    )
    let completed = Session(name: "c", status: .completed, ticketURL: "https://github.com/org/repo/issues/7", provider: .github)
    let archived = Session(name: "a", status: .archived, ticketURL: "https://github.com/org/repo/issues/7", provider: .github)
    appState.sessions = [completed, archived]
    #expect(appState.linkedSession(for: issue) == nil)
}

@MainActor @Test func linkedSessionMatchesJiraByKeyAcrossURLVariants() {
    let appState = AppState()
    let issue = AssignedIssue(
        id: "jira:MAXX-10", number: 10, title: "Jira one",
        state: "open", url: "https://acme.atlassian.net/browse/MAXX-10",
        repo: "MAXX", provider: .jira, projectStatus: .inProgress
    )
    // Session stored a browse URL with extra path/query — exact match fails, key matches.
    let session = Session(name: "jira", status: .inReview, ticketURL: "https://acme.atlassian.net/browse/MAXX-10?focusedCommentId=99", provider: .jira)
    appState.sessions = [session]
    #expect(appState.linkedSession(for: issue)?.id == session.id)
}

@MainActor @Test func linkedSessionDoesNotKeyMatchNonJiraProviders() {
    let appState = AppState()
    // Two different GitHub issues that share no exact URL must not link via key.
    let issue = AssignedIssue(
        id: "github:org/repo#1", number: 1, title: "T",
        state: "open", url: "https://github.com/org/repo/issues/1",
        repo: "org/repo", provider: .github
    )
    let session = Session(name: "other", status: .active, ticketURL: "https://github.com/org/repo/issues/2", provider: .github)
    appState.sessions = [session]
    #expect(appState.linkedSession(for: issue) == nil)
}

@MainActor @Test func assignedIssueMatchesJiraByKey() {
    let appState = AppState()
    appState.assignedIssues = [
        AssignedIssue(
            id: "jira:MAXX-10", number: 10, title: "Jira one",
            state: "open", url: "https://acme.atlassian.net/browse/MAXX-10",
            repo: "MAXX", labels: [LabelInfo(name: "bug")], provider: .jira, projectStatus: .inReview
        )
    ]
    let session = Session(name: "jira", status: .inReview, ticketURL: "MAXX-10", provider: .jira)
    #expect(appState.assignedIssue(for: session)?.id == "jira:MAXX-10")
    #expect(appState.labels(forSession: session) == [LabelInfo(name: "bug")])
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

// MARK: - producedPR(for:) — the crow_sessions PR sidecar (CROW-1115)

private func prAttribution(
    prURL: String, prNumber: Int, sessionIDs: [UUID],
    state: String = "MERGED", updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> PRSessionAttribution {
    PRSessionAttribution(
        prURL: prURL, repoNameWithOwner: "org/repo", prNumber: prNumber,
        sessionIDs: sessionIDs, state: state,
        firstSeenAt: Date(timeIntervalSince1970: 1_699_000_000),
        updatedAt: updatedAt)
}

@MainActor @Test func producedPRResolvesFromTrailerAttributionForIssueLinkedSession() {
    let appState = AppState()
    // Issue-linked session — the ticket is an issue, but the branch's commits
    // carried this session's `Crow-Session:` trailer, so attribution names the PR.
    let session = Session(name: "fix", ticketURL: "https://github.com/org/repo/issues/42")
    appState.sessions = [session]
    let prURL = "https://github.com/org/repo/pull/99"
    appState.prAttributions = [prURL: prAttribution(prURL: prURL, prNumber: 99, sessionIDs: [session.id])]

    let result = appState.producedPR(for: session)
    #expect(result?.url == prURL)
    #expect(result?.number == 99)
}

@MainActor @Test func producedPRFallsBackToSessionBranchPRLink() {
    let appState = AppState()
    let session = Session(name: "fix", ticketURL: "https://github.com/org/repo/issues/7")
    appState.sessions = [session]
    // No trailer attribution captured yet; PRLinkReconciler already attached the
    // branch-matched `.pr` link ("the PR Crow opened for this branch").
    appState.links[session.id] = [
        SessionLink(sessionID: session.id, label: "PR #12",
                    url: "https://github.com/org/repo/pull/12", linkType: .pr)
    ]
    let result = appState.producedPR(for: session)
    #expect(result?.url == "https://github.com/org/repo/pull/12")
    #expect(result?.number == 12)
}

@MainActor @Test func producedPRPrefersTrailerAttributionOverPRLink() {
    let appState = AppState()
    let session = Session(name: "fix", ticketURL: "https://github.com/org/repo/issues/7")
    appState.sessions = [session]
    let prURL = "https://github.com/org/repo/pull/99"
    appState.prAttributions = [prURL: prAttribution(prURL: prURL, prNumber: 99, sessionIDs: [session.id])]
    // Trailer attribution is authorship ground truth and wins over the link.
    appState.links[session.id] = [
        SessionLink(sessionID: session.id, label: "PR #12",
                    url: "https://github.com/org/repo/pull/12", linkType: .pr)
    ]
    #expect(appState.producedPR(for: session)?.number == 99)
}

@MainActor @Test func producedPRReturnsNilForReviewSession() {
    let appState = AppState()
    // A review session carries a `.pr` link to the PR it REVIEWS — that PR must
    // never be reported as PRODUCED by the reviewer (enforced, not incidental).
    let session = Session(name: "review-repo-123", kind: .review)
    appState.sessions = [session]
    appState.links[session.id] = [
        SessionLink(sessionID: session.id, label: "PR #123",
                    url: "https://github.com/org/repo/pull/123", linkType: .pr)
    ]
    #expect(appState.producedPR(for: session) == nil)
}

@MainActor @Test func producedPRResolvesForJobSession() {
    let appState = AppState()
    // A scheduled job authors its own branch — it is a genuine producer, so its
    // branch-matched `.pr` link is reported (the guard excludes only reviews).
    let session = Session(name: "nightly", kind: .job)
    appState.sessions = [session]
    appState.links[session.id] = [
        SessionLink(sessionID: session.id, label: "PR #8",
                    url: "https://github.com/org/repo/pull/8", linkType: .pr)
    ]
    #expect(appState.producedPR(for: session)?.number == 8)
}

@MainActor @Test func producedPRReturnsNilWhenNoPRKnown() {
    let appState = AppState()
    // A session whose branch never landed a PR, with no trailer attribution and
    // no `.pr` link, produces no sidecar hint (never a guess).
    let session = Session(name: "wip", ticketURL: "https://github.com/org/repo/issues/1")
    appState.sessions = [session]
    #expect(appState.producedPR(for: session) == nil)
}

@MainActor @Test func producedPRIgnoresAttributionsForOtherSessions() {
    let appState = AppState()
    let session = Session(name: "mine", ticketURL: "https://github.com/org/repo/issues/1")
    let other = UUID()
    appState.sessions = [session]
    let prURL = "https://github.com/org/repo/pull/5"
    // The PR carries a different session's trailer — not ours.
    appState.prAttributions = [prURL: prAttribution(prURL: prURL, prNumber: 5, sessionIDs: [other])]
    #expect(appState.producedPR(for: session) == nil)
}

@Test func bestProducedPRPrefersMergedThenMostRecent() {
    let sid = UUID()
    let openOld = PRSessionAttribution(
        prURL: "pr/open-old", repoNameWithOwner: "org/repo", prNumber: 1,
        sessionIDs: [sid], state: "OPEN",
        firstSeenAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 100))
    let mergedOlder = PRSessionAttribution(
        prURL: "pr/merged-older", repoNameWithOwner: "org/repo", prNumber: 2,
        sessionIDs: [sid], state: "MERGED",
        firstSeenAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 50))
    let mergedNewer = PRSessionAttribution(
        prURL: "pr/merged-newer", repoNameWithOwner: "org/repo", prNumber: 3,
        sessionIDs: [sid], state: "MERGED",
        firstSeenAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 60))

    // A landed PR outranks a newer still-open one.
    #expect(AppState.bestProducedPR([openOld, mergedOlder])?.prURL == "pr/merged-older")
    // Among merged, the most recently updated wins.
    #expect(AppState.bestProducedPR([mergedOlder, mergedNewer])?.prURL == "pr/merged-newer")
    #expect(AppState.bestProducedPR([]) == nil)
}

// MARK: - Manager Session Lookups

@MainActor @Test func managerSessionsIncludesPrimaryAndAdditional() {
    let appState = AppState()
    let primary = Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)
    let extra = Session(name: "Manager 2", kind: .manager)
    let work = Session(name: "work")
    appState.sessions = [primary, extra, work]

    #expect(Set(appState.managerSessions.map(\.id)) == [primary.id, extra.id])
    #expect(appState.managerSession?.id == primary.id)
}

@MainActor @Test func isManagerSessionRecognizesAllManagers() {
    let appState = AppState()
    let primary = Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)
    let extra = Session(name: "Manager 2", kind: .manager)
    let work = Session(name: "work")
    appState.sessions = [primary, extra, work]

    #expect(appState.isManagerSession(primary.id))
    #expect(appState.isManagerSession(extra.id))
    #expect(appState.isManagerSession(work.id) == false)
    // Falls back to the well-known UUID when the session isn't loaded yet.
    #expect(appState.isManagerSession(AppState.managerSessionID))
}

@MainActor @Test func managerSessionsExcludedFromActiveAndCompleted() {
    let appState = AppState()
    let manager = Session(name: "Manager 2", status: .active, kind: .manager)
    let completedManager = Session(name: "Manager 3", status: .completed, kind: .manager)
    let work = Session(name: "work", status: .active)
    appState.sessions = [manager, completedManager, work]

    #expect(appState.activeSessions.map(\.id) == [work.id])
    #expect(appState.completedSessions.isEmpty)
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
