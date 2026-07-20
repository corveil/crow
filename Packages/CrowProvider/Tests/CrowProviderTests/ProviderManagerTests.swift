import Foundation
import Testing
import CrowCore
@testable import CrowProvider

@Suite("ProviderManager")
struct ProviderManagerTests {

    let manager = ProviderManager()

    // MARK: - detectProvider

    @Test func detectProviderGitHub() async {
        let result = await manager.detectProvider(from: "https://github.com/org/repo/issues/1")
        #expect(result.provider == .github)
        #expect(result.cli == "gh")
        #expect(result.host == nil)
    }

    @Test func detectProviderGitLab() async {
        let result = await manager.detectProvider(from: "https://gitlab.com/org/repo/-/issues/1")
        #expect(result.provider == .gitlab)
        #expect(result.cli == "glab")
        #expect(result.host == "gitlab.com")
    }

    @Test func detectProviderCustomGitLabHost() async {
        let mgr = ProviderManager(additionalGitLabHosts: ["gitlab.internal.io"])
        let result = await mgr.detectProvider(from: "https://gitlab.internal.io/org/repo/-/issues/5")
        #expect(result.provider == .gitlab)
        #expect(result.cli == "glab")
        #expect(result.host == "gitlab.internal.io")
    }

    @Test func detectProviderFallsBackToGitHub() async {
        let result = await manager.detectProvider(from: "https://unknown.host/org/repo")
        #expect(result.provider == .github)
        #expect(result.cli == "gh")
    }

    // MARK: - parseTicketURLComponents (static)

    @Test func parseGitHubIssueURL() {
        let result = ProviderManager.parseTicketURLComponents("https://github.com/corveil/crow/issues/74")
        #expect(result?.org == "corveil")
        #expect(result?.repo == "crow")
        #expect(result?.number == 74)
        #expect(result?.isMR == false)
    }

    @Test func parseGitHubPullURL() {
        let result = ProviderManager.parseTicketURLComponents("https://github.com/org/repo/pull/123")
        #expect(result?.org == "org")
        #expect(result?.repo == "repo")
        #expect(result?.number == 123)
        #expect(result?.isMR == true)
    }

    @Test func parseGitLabIssueURL() {
        let result = ProviderManager.parseTicketURLComponents("https://gitlab.com/org/repo/-/issues/42")
        #expect(result?.org == "org")
        #expect(result?.repo == "repo")
        #expect(result?.number == 42)
        #expect(result?.isMR == false)
    }

    @Test func parseGitLabMergeRequestURL() {
        let result = ProviderManager.parseTicketURLComponents("https://gitlab.internal.io/team/project/-/merge_requests/99")
        #expect(result?.org == "team")
        #expect(result?.repo == "project")
        #expect(result?.number == 99)
        #expect(result?.isMR == true)
    }

    @Test func parseURLTooShort() {
        let result = ProviderManager.parseTicketURLComponents("https://github.com/org")
        #expect(result == nil)
    }

    @Test func parseURLNonNumericNumber() {
        let result = ProviderManager.parseTicketURLComponents("https://github.com/org/repo/issues/abc")
        #expect(result == nil)
    }

    // MARK: - Jira (ADR 0005 task-only provider)

    @Test func detectProviderJiraBrowseURL() async {
        let result = await manager.detectProvider(from: "https://acme.atlassian.net/browse/PROJ-123")
        #expect(result.provider == .jira)
        #expect(result.cli == "acli")
        #expect(result.host == nil)
    }

    @Test func parseJiraBrowseURL() {
        let result = ProviderManager.parseTicketURLComponents("https://acme.atlassian.net/browse/PROJ-123")
        #expect(result?.org == "PROJ")
        #expect(result?.repo == "PROJ")
        #expect(result?.number == 123)
        #expect(result?.isMR == false)
    }

    @Test func detectProviderJiraBareKey() async {
        // A pasted bare key is auto-detected as Jira.
        let result = await manager.detectProvider(from: "PROJ-123")
        #expect(result.provider == .jira)
        #expect(result.cli == "acli")
    }

    @Test func parseJiraBareKey() {
        let result = ProviderManager.parseTicketURLComponents("TEAM-7")
        #expect(result?.org == "TEAM")
        #expect(result?.number == 7)
        #expect(result?.isMR == false)
    }

    @Test func detectProviderBrowseWithoutValidKeyIsNotJira() async {
        // A `/browse/` path whose tail isn't a valid Jira key must not misroute
        // to Jira — it falls through to the default (GitHub).
        let result = await manager.detectProvider(from: "https://example.com/browse/wiki/Home")
        #expect(result.provider != .jira)
    }

    @Test func detectProviderSelfHostedJiraBrowseURL() async {
        // Jira Server on a custom domain: /browse/<valid key> still resolves.
        let result = await manager.detectProvider(from: "https://jira.acme.com/browse/PROJ-9")
        #expect(result.provider == .jira)
    }

    @Test func taskBackendForJiraIsJiraBackend() {
        let backend = manager.taskBackend(for: .jira)
        #expect(backend.provider == .jira)
        #expect(backend is JiraTaskBackend)
        #expect(backend.capabilities.contains(.projectBoardStatus))
    }

    @Test func codeBackendForJiraIsNil() {
        // Jira is task-only — no VCS surface (pairs with a GitHub/GitLab code backend).
        #expect(manager.codeBackend(for: .jira) == nil)
    }

    // MARK: - Corveil (ADR 0005 task-only provider)

    @Test func detectProviderPublicCorveilURL() async {
        let result = await manager.detectProvider(from: "https://corveil.io/dashboard/tasks/42")
        #expect(result.provider == .corveil)
        #expect(result.cli == "corveil")
        #expect(result.host == nil)
    }

    @Test func detectProviderSelfHostedCorveilURL() async {
        let mgr = ProviderManager(additionalCorveilHosts: ["corveil.acme.io"])
        let result = await mgr.detectProvider(from: "https://corveil.acme.io/dashboard/tasks/137")
        #expect(result.provider == .corveil)
        #expect(result.cli == "corveil")
        #expect(result.host == "corveil.acme.io")
    }

    @Test func detectProviderMultipleCorveilHosts() async {
        let mgr = ProviderManager(additionalCorveilHosts: ["corveil.a.com", "corveil.b.com"])
        let resultA = await mgr.detectProvider(from: "https://corveil.a.com/dashboard/tasks/1")
        #expect(resultA.host == "corveil.a.com")
        let resultB = await mgr.detectProvider(from: "https://corveil.b.com/dashboard/tasks/2")
        #expect(resultB.host == "corveil.b.com")
    }

    @Test func taskBackendForCorveilIsCorveilBackend() {
        let backend = manager.taskBackend(for: .corveil)
        #expect(backend.provider == .corveil)
        #expect(backend is CorveilTaskBackend)
        #expect(backend.capabilities.contains(.batchedQuery))
        #expect(backend.capabilities.contains(.projectBoardStatus))
    }

    @Test func codeBackendForCorveilIsNil() {
        // Corveil is task-only — no VCS surface (pairs with a GitHub/GitLab code backend).
        #expect(manager.codeBackend(for: .corveil) == nil)
    }

    @Test func taskBackendForCorveilURLDetectsCorveil() {
        let backend = manager.taskBackend(forURL: "https://corveil.io/dashboard/tasks/42")
        #expect(backend.provider == .corveil)
    }

    // MARK: - detectProvider edge cases

    @Test func detectProviderCaseSensitiveHost() async {
        // url.contains("github.com") is case-sensitive — uppercase doesn't match
        let result = await manager.detectProvider(from: "https://GitHub.COM/org/repo/issues/1")
        // Falls back to GitHub anyway (default fallback), but via fallback path
        #expect(result.provider == .github)
        #expect(result.cli == "gh")
    }

    @Test func detectProviderWithPortInURL() async {
        let mgr = ProviderManager(additionalGitLabHosts: ["gitlab.internal.io"])
        let result = await mgr.detectProvider(from: "https://gitlab.internal.io:8443/org/repo/-/issues/5")
        #expect(result.provider == .gitlab)
        #expect(result.host == "gitlab.internal.io")
    }

    @Test func detectProviderEmptyURL() async {
        let result = await manager.detectProvider(from: "")
        #expect(result.provider == .github)
    }

    @Test func detectProviderMultipleCustomHosts() async {
        let mgr = ProviderManager(additionalGitLabHosts: ["gitlab.a.com", "gitlab.b.com"])
        let resultA = await mgr.detectProvider(from: "https://gitlab.a.com/org/repo")
        #expect(resultA.host == "gitlab.a.com")
        let resultB = await mgr.detectProvider(from: "https://gitlab.b.com/org/repo")
        #expect(resultB.host == "gitlab.b.com")
    }

    // MARK: - parseTicketURLComponents edge cases

    @Test func parseGitHubURLWithTrailingSlash() {
        // split(separator: "/") omits empty subsequences, so trailing "/" is harmless
        let result = ProviderManager.parseTicketURLComponents("https://github.com/org/repo/issues/42/")
        #expect(result?.number == 42)
        #expect(result?.org == "org")
    }

    @Test func parseGitHubURLWithQueryParams() {
        // Int("42?tab=comments") returns nil
        let result = ProviderManager.parseTicketURLComponents("https://github.com/org/repo/issues/42?tab=comments")
        #expect(result == nil)
    }

    @Test func parseGitHubURLWithFragment() {
        // Int("42#issuecomment-123") returns nil
        let result = ProviderManager.parseTicketURLComponents("https://github.com/org/repo/issues/42#issuecomment-123")
        #expect(result == nil)
    }

    @Test func parseGitLabSelfHostedIssue() {
        let result = ProviderManager.parseTicketURLComponents("https://gitlab.company.io/team/project/-/issues/10")
        #expect(result?.org == "team")
        #expect(result?.repo == "project")
        #expect(result?.number == 10)
        #expect(result?.isMR == false)
    }

    @Test func parseHTTPNotHTTPS() {
        // Parser doesn't check protocol scheme
        let result = ProviderManager.parseTicketURLComponents("http://github.com/org/repo/issues/1")
        #expect(result?.number == 1)
    }

    @Test func parseLargeIssueNumber() {
        let result = ProviderManager.parseTicketURLComponents("https://github.com/org/repo/issues/999999")
        #expect(result?.number == 999999)
    }

    @Test func parseGitLabSubgroupDocumentsLimitation() {
        // Subgroup URLs: parts[2]="org", parts[3]="sub" — repo is actually "sub", not "repo"
        let result = ProviderManager.parseTicketURLComponents("https://gitlab.com/org/sub/repo/-/issues/5")
        // Misparses: treats "sub" as the repo name (known limitation of flat split parsing)
        #expect(result?.org == "org")
        #expect(result?.repo == "sub")
    }

    // MARK: - classifySpec (Jobs repo specs)

    @Test func classifySpecGlobExtractsOwner() {
        #expect(ProviderManager.classifySpec("corveil/*") == .glob(owner: "corveil"))
    }

    @Test func classifySpecNestedGroupGlob() {
        #expect(ProviderManager.classifySpec("group/subgroup/*") == .glob(owner: "group/subgroup"))
    }

    @Test func classifySpecExplicitSlugPassesThrough() {
        #expect(ProviderManager.classifySpec("corveil/api") == .explicit(slug: "corveil/api"))
    }

    @Test func classifySpecTrimsWhitespace() {
        #expect(ProviderManager.classifySpec("  corveil/api  ") == .explicit(slug: "corveil/api"))
    }

    @Test func classifySpecBareNameIsInvalid() {
        // No owner — can't list or clone it. Bare names stay invalid; rather than
        // coerce them to a glob, `reposForSpecs` surfaces them with a suggested fix.
        #expect(ProviderManager.classifySpec("api") == .invalid)
    }

    @Test func classifySpecEmptyIsInvalid() {
        #expect(ProviderManager.classifySpec("   ") == .invalid)
    }

    @Test func classifySpecBareGlobIsInvalid() {
        #expect(ProviderManager.classifySpec("/*") == .invalid)
    }

    @Test func encodeGitLabGroupPathEncodesSeparators() {
        // A nested-group glob (group/sub/*) yields owner "group/sub", which the
        // GitLab groups endpoint needs as "group%2Fsub".
        #expect(ProviderManager.encodeGitLabGroupPath("group/sub") == "group%2Fsub")
    }

    @Test func encodeGitLabGroupPathLeavesSimpleOwnerUnchanged() {
        #expect(ProviderManager.encodeGitLabGroupPath("corveil") == "corveil")
    }

    @Test func reposForSpecsKeepsExplicitSlugsSortedAndDeduped() async {
        // Explicit + invalid specs need no provider call, so this exercises the
        // merge/dedup/sort path (and invalid-spec surfacing) without shelling out.
        let result = await manager.reposForSpecs(
            ["org/zeta", "org/alpha", "org/alpha", "bare"],
            provider: .github, host: nil
        )
        #expect(result.repos == ["org/alpha", "org/zeta"])
        // The bare token is surfaced (not silently dropped) with a suggested fix.
        #expect(result.invalidSpecs == [.init(raw: "bare", suggestion: "bare/*")])
    }

    @Test func reposForSpecsSurfacesBareOrgTokenWithSuggestion() async {
        // A bare org name (the CROW-516 repro) is surfaced as invalid with a
        // "did you mean owner/*" hint while valid explicit slugs still resolve.
        let result = await manager.reposForSpecs(
            ["securityscorecard", "org/repo"],
            provider: .github, host: nil
        )
        #expect(result.repos == ["org/repo"])
        #expect(result.invalidSpecs == [
            .init(raw: "securityscorecard", suggestion: "securityscorecard/*"),
        ])
    }

    @Test func reposForSpecsSkipsWhitespaceOnlySpecs() async {
        // Empty/whitespace entries aren't user-meaningful, so they're dropped
        // rather than surfaced as "'' is invalid".
        let result = await manager.reposForSpecs(
            ["   ", "org/repo"],
            provider: .github, host: nil
        )
        #expect(result.repos == ["org/repo"])
        #expect(result.invalidSpecs.isEmpty)
    }

    @Test func suggestionForInvalidSpecGlobsBareOrgName() {
        #expect(ProviderManager.suggestion(forInvalidSpec: "securityscorecard") == "securityscorecard/*")
        #expect(ProviderManager.suggestion(forInvalidSpec: "  acme  ") == "acme/*")
        // No clean fix for these.
        #expect(ProviderManager.suggestion(forInvalidSpec: "foo*") == nil)
        #expect(ProviderManager.suggestion(forInvalidSpec: "/*") == nil)
        #expect(ProviderManager.suggestion(forInvalidSpec: "") == nil)
    }

    // MARK: - ProviderError

    @Test func providerErrorInvalidURLStoresURL() {
        let error = ProviderError.invalidURL("bad-url")
        if case .invalidURL(let url) = error {
            #expect(url == "bad-url")
        } else {
            #expect(Bool(false), "Expected invalidURL case")
        }
    }

    @Test func providerErrorCommandFailedStoresOutput() {
        let error = ProviderError.commandFailed("stderr output here")
        if case .commandFailed(let output) = error {
            #expect(output == "stderr output here")
        } else {
            #expect(Bool(false), "Expected commandFailed case")
        }
    }

    // MARK: - TicketInfo

    @Test func ticketInfoStoresAllProperties() {
        let info = TicketInfo(number: 42, title: "Fix bug", repo: "crow", org: "corveil", url: "https://github.com/corveil/crow/issues/42", provider: .github, isMR: false)
        #expect(info.number == 42)
        #expect(info.title == "Fix bug")
        #expect(info.repo == "crow")
        #expect(info.org == "corveil")
        #expect(info.url == "https://github.com/corveil/crow/issues/42")
        #expect(info.provider == .github)
        #expect(info.isMR == false)
    }

    @Test func ticketInfoDistinguishesIssueFromMR() {
        let issue = TicketInfo(number: 1, title: "Issue", repo: "r", org: "o", url: "u", provider: .github, isMR: false)
        let mr = TicketInfo(number: 2, title: "MR", repo: "r", org: "o", url: "u", provider: .gitlab, isMR: true)
        #expect(issue.isMR == false)
        #expect(mr.isMR == true)
    }
}
