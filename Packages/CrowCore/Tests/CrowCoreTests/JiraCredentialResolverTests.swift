import Foundation
import Testing
@testable import CrowCore

@Test func jiraCredentialResolverBuildsBasicAuthFromPlaintextToken() throws {
    let cred = JiraCredential(username: "me@example.com", tokenRef: "tok123")
    // resolveSecret must NOT be consulted for a plaintext token.
    let authorization = JiraCredentialResolver.resolve(cred) { _ in
        Issue.record("op read should not be called for a plaintext token")
        return nil
    }
    let expected = "Basic " + Data("me@example.com:tok123".utf8).base64EncodedString()
    #expect(authorization == expected)
}

@Test func jiraCredentialResolverResolvesOpReference() throws {
    let cred = JiraCredential(
        username: "me@example.com",
        tokenRef: "op://Private/Jira/api_token")
    var requestedRef: String?
    let authorization = JiraCredentialResolver.resolve(cred) { ref in
        requestedRef = ref
        return "secretToken"
    }
    #expect(requestedRef == "op://Private/Jira/api_token")
    let expected = "Basic " + Data("me@example.com:secretToken".utf8).base64EncodedString()
    #expect(authorization == expected)
}

@Test func jiraCredentialResolverReturnsNilForEmptyCredential() throws {
    let empty = JiraCredential(username: "", tokenRef: "")
    #expect(empty.isEmpty)
    #expect(JiraCredentialResolver.resolve(empty) { _ in "unused" } == nil)
}

@Test func jiraCredentialResolverReturnsNilWhenSecretResolutionFails() throws {
    let cred = JiraCredential(username: "me@example.com", tokenRef: "op://Vault/Item/missing")
    // A failed op read must NOT produce a broken credential.
    #expect(JiraCredentialResolver.resolve(cred) { _ in nil } == nil)
}

@Test func jiraCredentialResolverReturnsNilWhenHalfConfigured() throws {
    // Username without a token (or vice versa) can't form Basic auth.
    let usernameOnly = JiraCredential(username: "me@example.com", tokenRef: "")
    #expect(JiraCredentialResolver.resolve(usernameOnly) { _ in "unused" } == nil)
    let tokenOnly = JiraCredential(username: "", tokenRef: "tok")
    #expect(JiraCredentialResolver.resolve(tokenOnly) { _ in "unused" } == nil)
}

@Test func appConfigRoundTripsJiraCredential() throws {
    let config = AppConfig(jiraCredential: JiraCredential(
        username: "me@example.com", tokenRef: "op://Private/Jira/api_token"))
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.jiraCredential?.username == "me@example.com")
    #expect(decoded.jiraCredential?.tokenRef == "op://Private/Jira/api_token")
}

@Test func appConfigDecodesMissingJiraCredentialAsNil() throws {
    let json = "{}".data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(decoded.jiraCredential == nil)
}

@Test func appConfigMigratesLegacyAtlassianMCP() throws {
    // A pre-CROW-528 config.json with the old `atlassianMCP` block (email +
    // tokenRef) must migrate forward to `jiraCredential` on decode.
    let json = """
    { "atlassianMCP": { "endpoint": "https://mcp.atlassian.com/v1/mcp",
                        "email": "legacy@example.com",
                        "tokenRef": "op://Private/Atlassian/api_token" } }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(decoded.jiraCredential?.username == "legacy@example.com")
    #expect(decoded.jiraCredential?.tokenRef == "op://Private/Atlassian/api_token")
}
