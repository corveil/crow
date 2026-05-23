import Foundation
import Testing
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
        let result = ProviderManager.parseTicketURLComponents("https://github.com/radiusmethod/crow/issues/74")
        #expect(result?.org == "radiusmethod")
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
        #expect(ProviderManager.classifySpec("radiusmethod/*") == .glob(owner: "radiusmethod"))
    }

    @Test func classifySpecNestedGroupGlob() {
        #expect(ProviderManager.classifySpec("group/subgroup/*") == .glob(owner: "group/subgroup"))
    }

    @Test func classifySpecExplicitSlugPassesThrough() {
        #expect(ProviderManager.classifySpec("radiusmethod/api") == .explicit(slug: "radiusmethod/api"))
    }

    @Test func classifySpecTrimsWhitespace() {
        #expect(ProviderManager.classifySpec("  radiusmethod/api  ") == .explicit(slug: "radiusmethod/api"))
    }

    @Test func classifySpecBareNameIsInvalid() {
        // No owner — can't list or clone it.
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
        #expect(ProviderManager.encodeGitLabGroupPath("radiusmethod") == "radiusmethod")
    }

    @Test func reposForSpecsKeepsExplicitSlugsSortedAndDeduped() async {
        // Explicit-only specs need no provider call, so this exercises the
        // merge/dedup/sort path without shelling out.
        let result = await manager.reposForSpecs(
            ["org/zeta", "org/alpha", "org/alpha", "bare"],
            provider: .github, host: nil
        )
        #expect(result == ["org/alpha", "org/zeta"])
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
        let info = TicketInfo(number: 42, title: "Fix bug", repo: "crow", org: "radiusmethod", url: "https://github.com/radiusmethod/crow/issues/42", provider: .github, isMR: false)
        #expect(info.number == 42)
        #expect(info.title == "Fix bug")
        #expect(info.repo == "crow")
        #expect(info.org == "radiusmethod")
        #expect(info.url == "https://github.com/radiusmethod/crow/issues/42")
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
