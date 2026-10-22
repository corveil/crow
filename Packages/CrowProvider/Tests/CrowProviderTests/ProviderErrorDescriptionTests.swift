import Foundation
import Testing
@testable import CrowProvider

@Suite("ProviderError LocalizedError (CROW-1352)")
struct ProviderErrorDescriptionTests {

    @Test func commandFailedPrefersTheGhSummaryLineOverAnHTMLBody() {
        let body = """
        <!DOCTYPE html>
        <html><head><style>body { color: red }</style></head>
        <body><h1>Unicorn!</h1><p>We had issues producing the response.</p></body></html>
        gh: HTTP 502: Bad Gateway (https://api.github.com/graphql)
        """
        let error = ProviderError.commandFailed(body)
        #expect(error.localizedDescription == "gh: HTTP 502: Bad Gateway (https://api.github.com/graphql)")
    }

    @Test func commandFailedStripsHTMLWhenThereIsNoSummaryLine() {
        let error = ProviderError.commandFailed(
            "<html><head><script>var x = 1;</script></head><body><p>Bad   Gateway</p></body></html>"
        )
        #expect(error.localizedDescription == "Bad Gateway")
    }

    @Test func commandFailedKeepsPlainOutput() {
        let error = ProviderError.commandFailed("GraphQL: Could not resolve to a Repository (repository)\n")
        #expect(error.localizedDescription == "GraphQL: Could not resolve to a Repository (repository)")
    }

    @Test func commandFailedWithEmptyOutputSaysSo() {
        #expect(ProviderError.commandFailed("  \n").localizedDescription == "command failed with no output")
    }

    @Test func invalidURLIncludesTheURL() {
        #expect(ProviderError.invalidURL("not a url").localizedDescription == "invalid URL: not a url")
    }

    @Test func unimplementedIsTheMessage() {
        #expect(ProviderError.unimplemented("listProjects is not supported on GitLab")
            .localizedDescription == "listProjects is not supported on GitLab")
    }

    @Test func insufficientScopeNamesTheScope() {
        #expect(ProviderError.insufficientScope("read:project")
            .localizedDescription == "GitHub token missing 'read:project' scope")
    }

    @Test func rateLimitedIncludesTheReason() {
        let error = ProviderError.rateLimited(#"{"errors":[{"type":"RATE_LIMITED"}]}"# + "\ngh: API rate limit exceeded")
        #expect(error.localizedDescription == "rate limited: gh: API rate limit exceeded")
    }

    @Test func samlRestrictedIncludesTheReason() {
        let error = ProviderError.samlRestricted(
            #"{"data":{"search":{"nodes":[]}}}"# + "\ngh: Resource protected by organization SAML enforcement."
        )
        #expect(error.localizedDescription == "SAML-restricted: gh: Resource protected by organization SAML enforcement.")
    }

    @Test func descriptionIsLengthLimited() {
        let error = ProviderError.commandFailed(String(repeating: "x", count: 5_000))
        let description = error.localizedDescription
        #expect(description.count == ProviderError.descriptionLimit)
        #expect(description.hasSuffix("…"))
    }

    @Test func credentialsAreRedacted() {
        let secrets = [
            "ghp_" + String(repeating: "A", count: 36),
            "github_pat_" + String(repeating: "b", count: 40),
            "glpat-" + String(repeating: "c", count: 20),
            "sk-citadel-" + String(repeating: "d", count: 24),
        ]
        for secret in secrets {
            let description = ProviderError.commandFailed("gh: auth failed for \(secret)").localizedDescription
            #expect(!description.contains(secret))
            #expect(description.contains("[REDACTED]"))
        }
        let header = ProviderError.commandFailed("Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345")
            .localizedDescription
        #expect(!header.contains("abcdefghijklmnopqrstuvwxyz012345"))
    }

    @Test func isNotTheOpaqueFoundationDefault() {
        #expect(!ProviderError.commandFailed("gh: HTTP 502").localizedDescription.contains("ProviderError error"))
    }
}
