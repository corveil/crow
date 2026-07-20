import Foundation
import Testing
@testable import CrowCore

@MainActor
private func makeReviewSession(name: String = "review-crow-406", status: SessionStatus = .active) -> Session {
    Session(
        name: name,
        status: status,
        kind: .review,
        agentKind: .claudeCode,
        provider: .github
    )
}

@MainActor
@Test func existingReviewSessionReturnsNilWhenNoSessionMatches() {
    let appState = AppState()
    let session = makeReviewSession()
    appState.sessions = [session]
    appState.links[session.id] = [
        SessionLink(sessionID: session.id, label: "PR #1", url: "https://github.com/org/other/pull/1", linkType: .pr)
    ]

    #expect(appState.existingReviewSession(forPRURL: "https://github.com/org/repo/pull/406") == nil)
}

@MainActor
@Test func existingReviewSessionReturnsSessionWithMatchingPRLink() {
    let appState = AppState()
    let session = makeReviewSession()
    let prURL = "https://github.com/corveil/crow/pull/406"
    appState.sessions = [session]
    appState.links[session.id] = [
        SessionLink(sessionID: session.id, label: "PR #406", url: prURL, linkType: .pr)
    ]

    #expect(appState.existingReviewSession(forPRURL: prURL)?.id == session.id)
}

@MainActor
@Test func existingReviewSessionIgnoresCompletedSessions() {
    let appState = AppState()
    let session = makeReviewSession(status: .completed)
    let prURL = "https://github.com/corveil/crow/pull/406"
    appState.sessions = [session]
    appState.links[session.id] = [
        SessionLink(sessionID: session.id, label: "PR #406", url: prURL, linkType: .pr)
    ]

    #expect(appState.existingReviewSession(forPRURL: prURL) == nil)
}

@MainActor
@Test func existingReviewSessionIgnoresArchivedSessions() {
    let appState = AppState()
    let session = makeReviewSession(status: .archived)
    let prURL = "https://github.com/corveil/crow/pull/406"
    appState.sessions = [session]
    appState.links[session.id] = [
        SessionLink(sessionID: session.id, label: "PR #406", url: prURL, linkType: .pr)
    ]

    #expect(appState.existingReviewSession(forPRURL: prURL) == nil)
}

@MainActor
@Test func existingReviewSessionIgnoresNonPRLinkTypes() {
    let appState = AppState()
    let session = makeReviewSession()
    let prURL = "https://github.com/corveil/crow/pull/406"
    appState.sessions = [session]
    // Same URL string but linked as `.repo`, not `.pr` — should not match.
    appState.links[session.id] = [
        SessionLink(sessionID: session.id, label: "Repo", url: prURL, linkType: .repo)
    ]

    #expect(appState.existingReviewSession(forPRURL: prURL) == nil)
}

@MainActor
@Test func existingReviewSessionReturnsFirstMatchWhenDuplicatesExist() {
    let appState = AppState()
    let first = makeReviewSession(name: "review-crow-406-a")
    let second = makeReviewSession(name: "review-crow-406-b")
    let prURL = "https://github.com/corveil/crow/pull/406"
    appState.sessions = [first, second]
    appState.links[first.id] = [
        SessionLink(sessionID: first.id, label: "PR #406", url: prURL, linkType: .pr)
    ]
    appState.links[second.id] = [
        SessionLink(sessionID: second.id, label: "PR #406", url: prURL, linkType: .pr)
    ]

    // We don't care which session wins — only that the helper returns
    // exactly one of them so callers get a stable, non-nil answer.
    let match = appState.existingReviewSession(forPRURL: prURL)
    #expect(match != nil)
    #expect(match?.id == first.id || match?.id == second.id)
}
