import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import Crow

@Suite("IssueTracker reconcile decision")
struct IssueTrackerReconcileDecisionTests {

    private let s1 = UUID()
    private let s2 = UUID()

    private func match(
        _ sessionID: UUID,
        number: Int,
        state: String,
        updatedAt: Date? = nil,
        url: String? = nil
    ) -> IssueTracker.ReconcileBranchMatch {
        IssueTracker.ReconcileBranchMatch(
            sessionID: sessionID,
            number: number,
            url: url ?? "https://example.test/pr/\(number)",
            state: state,
            updatedAt: updatedAt
        )
    }

    @Test func picksOpenOverMergedAndClosed() {
        let picks = IssueTracker.decideReconcileLinks(matches: [
            match(s1, number: 10, state: "MERGED", updatedAt: Date(timeIntervalSince1970: 300)),
            match(s1, number: 11, state: "OPEN",   updatedAt: Date(timeIntervalSince1970: 100)),
            match(s1, number: 12, state: "CLOSED", updatedAt: Date(timeIntervalSince1970: 400)),
        ])
        #expect(picks.count == 1)
        #expect(picks[0].number == 11)
        #expect(picks[0].state == "OPEN")
    }

    @Test func picksMostRecentWhenNoneOpen() {
        let picks = IssueTracker.decideReconcileLinks(matches: [
            match(s1, number: 20, state: "CLOSED", updatedAt: Date(timeIntervalSince1970: 100)),
            match(s1, number: 21, state: "MERGED", updatedAt: Date(timeIntervalSince1970: 500)),
            match(s1, number: 22, state: "CLOSED", updatedAt: Date(timeIntervalSince1970: 300)),
        ])
        #expect(picks.count == 1)
        #expect(picks[0].number == 21)
        #expect(picks[0].state == "MERGED")
    }

    @Test func returnsOneMatchPerSession() {
        let picks = IssueTracker.decideReconcileLinks(matches: [
            match(s1, number: 30, state: "OPEN"),
            match(s2, number: 31, state: "MERGED", updatedAt: Date(timeIntervalSince1970: 200)),
        ])
        #expect(picks.count == 2)
        let bySession = Dictionary(uniqueKeysWithValues: picks.map { ($0.sessionID, $0) })
        #expect(bySession[s1]?.number == 30)
        #expect(bySession[s2]?.number == 31)
    }

    @Test func emptyMatchesProducesNoPicks() {
        let picks = IssueTracker.decideReconcileLinks(matches: [])
        #expect(picks.isEmpty)
    }

    @Test func fallsBackToHighestNumberWhenTimestampsMissing() {
        // Deterministic tie-break: when all states are non-OPEN and none have
        // a timestamp, the higher PR number wins (most-recently created).
        let picks = IssueTracker.decideReconcileLinks(matches: [
            match(s1, number: 40, state: "MERGED"),
            match(s1, number: 42, state: "MERGED"),
            match(s1, number: 41, state: "MERGED"),
        ])
        #expect(picks.count == 1)
        #expect(picks[0].number == 42)
    }

    @Test func openWinsEvenIfNonOpenIsNewer() {
        let picks = IssueTracker.decideReconcileLinks(matches: [
            match(s1, number: 50, state: "OPEN",   updatedAt: Date(timeIntervalSince1970: 100)),
            match(s1, number: 51, state: "MERGED", updatedAt: Date(timeIntervalSince1970: 9_999_999)),
        ])
        #expect(picks.count == 1)
        #expect(picks[0].state == "OPEN")
        #expect(picks[0].number == 50)
    }
}

@Suite("IssueTracker reconcile provider routing")
struct IssueTrackerReconcileProviderTests {
    // Regression for #463: a Jira-task + GitHub-code session must route its
    // reconcile candidate to GitHub via `codeProvider`, not be dropped because
    // `provider` is the task-only `.jira`.
    @Test func jiraTaskWithGitHubCodeRoutesToGitHub() {
        let r = IssueTracker.resolveReconcileProvider(
            codeProvider: .github, provider: .jira, host: "github.com")
        #expect(r.provider == .github)
        #expect(r.gitlabHost == nil)
    }

    @Test func codeProviderTakesPrecedenceOverTaskProvider() {
        // Jira-task + GitLab-code: route to GitLab and carry the host.
        let r = IssueTracker.resolveReconcileProvider(
            codeProvider: .gitlab, provider: .jira, host: "gitlab.corp.example")
        #expect(r.provider == .gitlab)
        #expect(r.gitlabHost == "gitlab.corp.example")
    }

    @Test func nilProvidersFallBackToHostSniff() {
        // Sessions predating the provider field rely on host sniffing.
        let gh = IssueTracker.resolveReconcileProvider(
            codeProvider: nil, provider: nil, host: "github.com")
        #expect(gh.provider == .github)
        #expect(gh.gitlabHost == nil)

        let empty = IssueTracker.resolveReconcileProvider(
            codeProvider: nil, provider: nil, host: "")
        #expect(empty.provider == .github)

        let gl = IssueTracker.resolveReconcileProvider(
            codeProvider: nil, provider: nil, host: "gitlab.internal.example")
        #expect(gl.provider == .gitlab)
        #expect(gl.gitlabHost == "gitlab.internal.example")
    }

    @Test func taskOnlyProviderWithoutCodeProviderFallsBackToHost() {
        // Defensive: a `.jira` task with no `codeProvider` set must not become
        // a `.jira` candidate — host sniffing picks the real code backend.
        let r = IssueTracker.resolveReconcileProvider(
            codeProvider: nil, provider: .jira, host: "github.com")
        #expect(r.provider == .github)
    }

    @Test func plainGitHubAndGitLabSessionsUnaffected() {
        let gh = IssueTracker.resolveReconcileProvider(
            codeProvider: nil, provider: .github, host: "github.com")
        #expect(gh.provider == .github)
        #expect(gh.gitlabHost == nil)

        let gl = IssueTracker.resolveReconcileProvider(
            codeProvider: nil, provider: .gitlab, host: "gitlab.com")
        #expect(gl.provider == .gitlab)
        #expect(gl.gitlabHost == "gitlab.com")
    }
}

@Suite("IssueTracker remote host extraction")
struct IssueTrackerRemoteHostTests {
    @Test func parsesGitHubSSH() {
        #expect(IssueTracker.extractHost(fromRemote: "git@github.com:radiusmethod/corveil") == "github.com")
    }

    @Test func parsesGitHubHTTPS() {
        #expect(IssueTracker.extractHost(fromRemote: "https://github.com/radiusmethod/corveil") == "github.com")
    }

    @Test func parsesGitLabHTTPSCustomHost() {
        #expect(IssueTracker.extractHost(fromRemote: "https://gitlab.internal.example/acme/api") == "gitlab.internal.example")
    }

    @Test func parsesGitLabSSHCustomHost() {
        #expect(IssueTracker.extractHost(fromRemote: "git@gitlab.corp.example:acme/api") == "gitlab.corp.example")
    }

    @Test func returnsEmptyForUnrecognized() {
        #expect(IssueTracker.extractHost(fromRemote: "/tmp/local/repo") == "")
        #expect(IssueTracker.extractHost(fromRemote: "") == "")
    }
}

@Suite("IssueTracker remote slug extraction")
struct IssueTrackerRemoteSlugTests {
    @Test func parsesGitHubSSH() {
        #expect(IssueTracker.extractSlug(fromRemote: "git@github.com:radiusmethod/corveil") == "radiusmethod/corveil")
    }

    @Test func parsesGitHubHTTPS() {
        #expect(IssueTracker.extractSlug(fromRemote: "https://github.com/radiusmethod/corveil") == "radiusmethod/corveil")
    }

    @Test func parsesGitLabTwoLevel() {
        #expect(IssueTracker.extractSlug(fromRemote: "https://gitlab.internal.example/acme/api") == "acme/api")
        #expect(IssueTracker.extractSlug(fromRemote: "git@gitlab.corp.example:acme/api") == "acme/api")
    }

    @Test func parsesGitLabNestedGroupsHTTPS() {
        // Regression test for #232: nested-group paths must not be truncated.
        #expect(
            IssueTracker.extractSlug(
                fromRemote: "https://gitlab.example.com/big-bang/product/packages/elasticsearch-kibana"
            ) == "big-bang/product/packages/elasticsearch-kibana"
        )
    }

    @Test func parsesGitLabNestedGroupsSSH() {
        #expect(
            IssueTracker.extractSlug(
                fromRemote: "git@gitlab.example.com:big-bang/product/packages/elasticsearch-kibana"
            ) == "big-bang/product/packages/elasticsearch-kibana"
        )
    }

    @Test func stripsTrailingDotGit() {
        #expect(IssueTracker.extractSlug(fromRemote: "https://github.com/radiusmethod/corveil.git") == "radiusmethod/corveil")
        #expect(IssueTracker.extractSlug(fromRemote: "git@github.com:radiusmethod/corveil.git") == "radiusmethod/corveil")
        #expect(
            IssueTracker.extractSlug(
                fromRemote: "https://gitlab.example.com/big-bang/product/packages/elasticsearch-kibana.git"
            ) == "big-bang/product/packages/elasticsearch-kibana"
        )
    }

    @Test func returnsEmptyForUnrecognized() {
        #expect(IssueTracker.extractSlug(fromRemote: "/tmp/local/repo") == "")
        #expect(IssueTracker.extractSlug(fromRemote: "") == "")
    }
}

@Suite("IssueTracker PR-URL slug extraction")
struct IssueTrackerPRSlugTests {
    @Test func parsesGitHubPRURL() {
        #expect(IssueTracker.repoSlug(fromPRURL: "https://github.com/owner/repo/pull/123") == "owner/repo")
    }

    @Test func parsesGitLabMRURL() {
        // GitLab MR URLs interpose `/-/` before `merge_requests`; the slug is
        // everything up to that marker, including nested groups.
        #expect(
            IssueTracker.repoSlug(fromPRURL: "https://gitlab.com/group/sub/repo/-/merge_requests/12")
                == "group/sub/repo"
        )
    }

    @Test func ignoresQueryStringAndFragment() {
        #expect(IssueTracker.repoSlug(fromPRURL: "https://github.com/owner/repo/pull/123?w=1") == "owner/repo")
        #expect(IssueTracker.repoSlug(fromPRURL: "https://github.com/owner/repo/pull/123#discussion_r1") == "owner/repo")
    }

    @Test func parsesHTTPScheme() {
        #expect(IssueTracker.repoSlug(fromPRURL: "http://github.com/owner/repo/pull/9") == "owner/repo")
    }

    @Test func returnsEmptyForMissingScheme() {
        #expect(IssueTracker.repoSlug(fromPRURL: "github.com/owner/repo/pull/1") == "")
    }

    @Test func returnsEmptyForEmptyInput() {
        #expect(IssueTracker.repoSlug(fromPRURL: "") == "")
        #expect(IssueTracker.repoSlug(fromPRURL: "   ") == "")
    }
}

@Suite("IssueTracker reconcile fan-out")
struct IssueTrackerReconcileFanOutTests {

    private func candidate(_ sid: UUID, _ slug: String, _ branch: String, provider: Provider = .github) -> IssueTracker.ReconcileCandidate {
        IssueTracker.ReconcileCandidate(
            sessionID: sid,
            provider: provider,
            repoSlug: slug,
            branch: branch,
            gitlabHost: nil
        )
    }

    @Test func dedupedBranchCandidatesCollapsesDuplicates() {
        // Regression guard for the @MainActor crash that
        // `Dictionary(uniqueKeysWithValues:)` triggered: two sessions sharing
        // a (repoSlug, branch) must produce a single backend query candidate,
        // not trap on duplicate keys.
        let s1 = UUID()
        let s2 = UUID()
        let cands = [
            candidate(s1, "acme/api", "feature/x"),
            candidate(s2, "acme/api", "feature/x"),
            candidate(s1, "acme/api", "feature/y"),
        ]
        let out = IssueTracker.dedupedBranchCandidates(cands)
        #expect(out.count == 2)
        #expect(out.contains(BranchCandidate(repoSlug: "acme/api", branch: "feature/x")))
        #expect(out.contains(BranchCandidate(repoSlug: "acme/api", branch: "feature/y")))
    }

    @Test func fanOutMatchesEmitsOneRecordPerSessionSharingABranch() {
        // When two sessions share (repoSlug, branch), a single backend match
        // must produce one ReconcileBranchMatch per session — collapsing them
        // to one sessionID would silently drop the PR link for the other.
        let s1 = UUID()
        let s2 = UUID()
        let cands = [
            candidate(s1, "acme/api", "feature/x"),
            candidate(s2, "acme/api", "feature/x"),
        ]
        let bc = BranchCandidate(repoSlug: "acme/api", branch: "feature/x")
        let backendMatches = [
            BranchPRMatch(candidate: bc, number: 42, url: "https://github.com/acme/api/pull/42",
                          state: "OPEN", updatedAt: nil)
        ]
        let fanned = IssueTracker.fanOutMatches(backendMatches, across: cands)
        #expect(fanned.count == 2)
        let sids: Set<UUID> = Set(fanned.map(\.sessionID))
        #expect(sids == [s1, s2])
        #expect(fanned.allSatisfy { $0.number == 42 })
        #expect(fanned.allSatisfy { $0.state == "OPEN" })
    }

    @Test func fanOutMatchesDropsUnknownCandidates() {
        // A match for a candidate the caller didn't request must not bleed
        // into the output (defensive: a stale or malformed backend response
        // shouldn't create phantom sessionIDs).
        let s1 = UUID()
        let bc1 = BranchCandidate(repoSlug: "acme/api", branch: "feature/x")
        let bc2 = BranchCandidate(repoSlug: "acme/api", branch: "feature/y")
        let backendMatches = [
            BranchPRMatch(candidate: bc1, number: 1, url: "u1", state: "OPEN", updatedAt: nil),
            BranchPRMatch(candidate: bc2, number: 2, url: "u2", state: "OPEN", updatedAt: nil),
        ]
        let cands = [candidate(s1, "acme/api", "feature/x")]
        let fanned = IssueTracker.fanOutMatches(backendMatches, across: cands)
        #expect(fanned.count == 1)
        #expect(fanned[0].number == 1)
    }
}

@Suite("IssueTracker reconcile key fan-out")
struct IssueTrackerReconcileKeyFanOutTests {

    private func keyCandidate(_ sid: UUID, _ slug: String, _ key: String) -> IssueTracker.ReconcileKeyCandidate {
        IssueTracker.ReconcileKeyCandidate(
            sessionID: sid, provider: .github, repoSlug: slug, key: key, gitlabHost: nil
        )
    }

    @Test func dedupedKeyCandidatesCollapsesDuplicates() {
        // Two sessions on the same (repoSlug, key) — e.g. a duplicated Jira
        // session — must produce a single backend search.
        let s1 = UUID(); let s2 = UUID()
        let cands = [
            keyCandidate(s1, "acme/api", "MAXX-6859"),
            keyCandidate(s2, "acme/api", "MAXX-6859"),
            keyCandidate(s1, "acme/api", "MAXX-6860"),
        ]
        let out = IssueTracker.dedupedKeyCandidates(cands)
        #expect(out.count == 2)
        #expect(out.contains(KeyCandidate(repoSlug: "acme/api", key: "MAXX-6859")))
        #expect(out.contains(KeyCandidate(repoSlug: "acme/api", key: "MAXX-6860")))
    }

    @Test func fanOutKeyMatchesEmitsOnePerSessionSharingAKey() {
        let s1 = UUID(); let s2 = UUID()
        let cands = [
            keyCandidate(s1, "acme/api", "MAXX-6859"),
            keyCandidate(s2, "acme/api", "MAXX-6859"),
        ]
        let kc = KeyCandidate(repoSlug: "acme/api", key: "MAXX-6859")
        let backendMatches = [
            KeyPRMatch(candidate: kc, number: 52, url: "https://github.com/acme/api/pull/52",
                       state: "OPEN", updatedAt: nil)
        ]
        let fanned = IssueTracker.fanOutKeyMatches(backendMatches, across: cands)
        #expect(fanned.count == 2)
        #expect(Set(fanned.map(\.sessionID)) == [s1, s2])
        #expect(fanned.allSatisfy { $0.number == 52 && $0.state == "OPEN" })
    }

    @Test func fanOutKeyMatchesDropsUnknownCandidates() {
        let s1 = UUID()
        let known = KeyCandidate(repoSlug: "acme/api", key: "MAXX-6859")
        let unknown = KeyCandidate(repoSlug: "acme/api", key: "MAXX-9999")
        let backendMatches = [
            KeyPRMatch(candidate: known, number: 1, url: "u1", state: "OPEN", updatedAt: nil),
            KeyPRMatch(candidate: unknown, number: 2, url: "u2", state: "OPEN", updatedAt: nil),
        ]
        let cands = [keyCandidate(s1, "acme/api", "MAXX-6859")]
        let fanned = IssueTracker.fanOutKeyMatches(backendMatches, across: cands)
        #expect(fanned.count == 1)
        #expect(fanned[0].number == 1)
    }
}
