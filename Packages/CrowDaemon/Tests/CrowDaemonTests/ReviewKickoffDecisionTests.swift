import Foundation
import Testing
import CrowCore
@testable import CrowDaemon

/// `CrowDaemon.decideReviewKickoffs` is the reviewer-side re-review brain the
/// headless-engine port (ADR 0008) dropped and CROW-756 restores. These pin the
/// two kickoff signals (create-once + `shaAdvanced`), the stale-session teardown
/// on head-advance, and the dedup guards — without AppState/tmux/git.
@Suite struct ReviewKickoffDecisionTests {
    private let patterns = ["org/repo"]

    private func request(
        prNumber: Int = 1,
        url: String = "https://github.com/org/repo/pull/1",
        repo: String = "org/repo",
        reviewSessionID: UUID? = nil,
        headRefOid: String? = "sha-1"
    ) -> ReviewRequest {
        ReviewRequest(
            id: "github:\(repo)#\(prNumber)",
            prNumber: prNumber,
            title: "PR \(prNumber)",
            url: url,
            repo: repo,
            author: "author",
            headBranch: "feature",
            baseBranch: "main",
            reviewSessionID: reviewSessionID,
            headRefOid: headRefOid
        )
    }

    /// A review session + its `.pr` link, wired into the `(sessions, links)`
    /// pair the decision reads.
    private func reviewSession(
        url: String = "https://github.com/org/repo/pull/1",
        lastReviewedHeadSha: String?,
        agentKind: AgentKind = .claudeCode
    ) -> (Session, [UUID: [SessionLink]]) {
        let session = Session(
            name: "review-repo-1",
            kind: .review,
            agentKind: agentKind,
            lastReviewedHeadSha: lastReviewedHeadSha
        )
        let link = SessionLink(sessionID: session.id, label: "PR", url: url, linkType: .pr)
        return (session, [session.id: [link]])
    }

    // MARK: - Signal 1: create-once

    @Test func kicksOffWhenNoReviewSessionExists() {
        let plan = CrowDaemon.decideReviewKickoffs(
            requests: [request()],
            patterns: patterns,
            reviewSessions: [],
            linksBySessionID: [:],
            alreadyKicked: []
        )
        #expect(plan.kickoffPRURLs == ["https://github.com/org/repo/pull/1"])
        #expect(plan.completeStaleSessionIDs.isEmpty)
        #expect(plan.newFingerprints == ["github:org/repo#1\nsha-1"])
    }

    @Test func skipsReposNotMatchingAutoReviewPatterns() {
        let plan = CrowDaemon.decideReviewKickoffs(
            requests: [request(url: "https://github.com/other/repo/pull/1", repo: "other/repo")],
            patterns: patterns,
            reviewSessions: [],
            linksBySessionID: [:],
            alreadyKicked: []
        )
        #expect(plan == CrowDaemon.ReviewKickoffPlan())
    }

    // MARK: - Signal 2: shaAdvanced re-review

    @Test func reReviewsAndTearsDownStaleSessionWhenHeadAdvances() {
        let (session, links) = reviewSession(lastReviewedHeadSha: "sha-1")
        let plan = CrowDaemon.decideReviewKickoffs(
            requests: [request(reviewSessionID: session.id, headRefOid: "sha-2")],
            patterns: patterns,
            reviewSessions: [session],
            linksBySessionID: links,
            alreadyKicked: []
        )
        #expect(plan.completeStaleSessionIDs == [session.id])
        #expect(plan.kickoffPRURLs == ["https://github.com/org/repo/pull/1"])
        #expect(plan.newFingerprints == ["github:org/repo#1\nsha-2"])
    }

    /// CROW-406 lag: the session exists (found by PR URL) but the request's
    /// `reviewSessionID` cross-ref hasn't landed yet. Head-advance must still
    /// re-review off the by-URL lookup.
    @Test func reReviewsViaExistingByPRWhenReviewSessionIDLags() {
        let (session, links) = reviewSession(lastReviewedHeadSha: "sha-1")
        let plan = CrowDaemon.decideReviewKickoffs(
            requests: [request(reviewSessionID: nil, headRefOid: "sha-2")],
            patterns: patterns,
            reviewSessions: [session],
            linksBySessionID: links,
            alreadyKicked: []
        )
        #expect(plan.completeStaleSessionIDs == [session.id])
        #expect(plan.kickoffPRURLs == ["https://github.com/org/repo/pull/1"])
    }

    /// Agent-agnostic: the reported repro was a Cursor review session.
    @Test func reReviewsForNonClaudeAgents() {
        let (session, links) = reviewSession(lastReviewedHeadSha: "sha-1", agentKind: .cursor)
        let plan = CrowDaemon.decideReviewKickoffs(
            requests: [request(reviewSessionID: session.id, headRefOid: "sha-2")],
            patterns: patterns,
            reviewSessions: [session],
            linksBySessionID: links,
            alreadyKicked: []
        )
        #expect(plan.completeStaleSessionIDs == [session.id])
        #expect(plan.kickoffPRURLs == ["https://github.com/org/repo/pull/1"])
    }

    // MARK: - Regression guards

    @Test func doesNotReReviewWhenHeadUnchanged() {
        let (session, links) = reviewSession(lastReviewedHeadSha: "sha-1")
        let plan = CrowDaemon.decideReviewKickoffs(
            requests: [request(reviewSessionID: session.id, headRefOid: "sha-1")],
            patterns: patterns,
            reviewSessions: [session],
            linksBySessionID: links,
            alreadyKicked: []
        )
        #expect(plan == CrowDaemon.ReviewKickoffPlan())
    }

    /// Session exists by PR URL, `reviewSessionID` not yet cross-referenced, and
    /// the head is unchanged — the create-once guard must NOT fire a duplicate.
    @Test func doesNotDuplicateWhenExistingByPRAndHeadUnchanged() {
        let (session, links) = reviewSession(lastReviewedHeadSha: "sha-1")
        let plan = CrowDaemon.decideReviewKickoffs(
            requests: [request(reviewSessionID: nil, headRefOid: "sha-1")],
            patterns: patterns,
            reviewSessions: [session],
            linksBySessionID: links,
            alreadyKicked: []
        )
        #expect(plan == CrowDaemon.ReviewKickoffPlan())
    }

    @Test func dedupesAlreadyKickedHead() {
        let plan = CrowDaemon.decideReviewKickoffs(
            requests: [request()],
            patterns: patterns,
            reviewSessions: [],
            linksBySessionID: [:],
            alreadyKicked: ["github:org/repo#1\nsha-1"]
        )
        #expect(plan == CrowDaemon.ReviewKickoffPlan())
    }

    /// A single pass with two requests on the same head still enqueues each once
    /// and never the same fingerprint twice.
    @Test func kicksEachDistinctRequestOncePerPass() {
        let r1 = request(prNumber: 1, url: "https://github.com/org/repo/pull/1")
        let r2 = request(prNumber: 2, url: "https://github.com/org/repo/pull/2")
        let plan = CrowDaemon.decideReviewKickoffs(
            requests: [r1, r2, r1],
            patterns: patterns,
            reviewSessions: [],
            linksBySessionID: [:],
            alreadyKicked: []
        )
        #expect(plan.kickoffPRURLs == [
            "https://github.com/org/repo/pull/1",
            "https://github.com/org/repo/pull/2",
        ])
        #expect(plan.newFingerprints.count == 2)
    }

    /// `headRefOid == nil` can't prove the head advanced, so an existing session
    /// with a nil incoming head must not re-review (and the by-PR guard blocks a
    /// duplicate create).
    @Test func doesNotReReviewWhenIncomingHeadIsNil() {
        let (session, links) = reviewSession(lastReviewedHeadSha: "sha-1")
        let plan = CrowDaemon.decideReviewKickoffs(
            requests: [request(reviewSessionID: session.id, headRefOid: nil)],
            patterns: patterns,
            reviewSessions: [session],
            linksBySessionID: links,
            alreadyKicked: []
        )
        #expect(plan == CrowDaemon.ReviewKickoffPlan())
    }
}
