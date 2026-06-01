import Foundation
import Testing
@testable import CrowCore

@Test func gatewayResolverSerializesHeadersSortedNewlineSeparated() throws {
    let lines = GatewayResolver.serializeHeaders([
        "x-b": "two",
        "x-a": "one",
    ])
    // Sorted by name for determinism, newline-separated "Name: Value".
    #expect(lines == "x-a: one\nx-b: two")
}

@Test func gatewayResolverReturnsNilForEmptyGateway() throws {
    let empty = WorkspaceGateway(baseURL: "", customHeaders: [:])
    #expect(GatewayResolver.resolve(empty) { _ in "unused" } == nil)
}

@Test func gatewayResolverPassesPlaintextThrough() throws {
    let gateway = WorkspaceGateway(
        baseURL: "https://corveil.io",
        customHeaders: ["x-citadel-api-key": "Bearer sk-plain"]
    )
    // resolveSecret must NOT be consulted for a plaintext value.
    let resolved = GatewayResolver.resolve(gateway) { _ in
        Issue.record("op read should not be called for a plaintext header")
        return nil
    }
    #expect(resolved?.baseURL == "https://corveil.io")
    #expect(resolved?.customHeaders == "x-citadel-api-key: Bearer sk-plain")
}

@Test func gatewayResolverResolvesOpReference() throws {
    let gateway = WorkspaceGateway(
        baseURL: "https://corveil.io",
        customHeaders: ["x-citadel-api-key": "op://Spotlight Prod/Citadel/api_key"]
    )
    var requestedRef: String?
    let resolved = GatewayResolver.resolve(gateway) { ref in
        requestedRef = ref
        return "Bearer sk-resolved"
    }
    #expect(requestedRef == "op://Spotlight Prod/Citadel/api_key")
    #expect(resolved?.customHeaders == "x-citadel-api-key: Bearer sk-resolved")
}

@Test func gatewayResolverDropsHeaderWhenSecretResolutionFails() throws {
    let gateway = WorkspaceGateway(
        baseURL: "https://corveil.io",
        customHeaders: [
            "x-citadel-api-key": "op://Vault/Item/missing",
            "x-plain": "kept",
        ]
    )
    // Secret fails to resolve → that header is dropped, baseURL + plaintext kept
    // (gateway rejects the request loudly rather than falling back to vanilla).
    let resolved = GatewayResolver.resolve(gateway) { _ in nil }
    #expect(resolved?.baseURL == "https://corveil.io")
    #expect(resolved?.customHeaders == "x-plain: kept")
}

// MARK: - Launch-line prefix (ClaudeLaunchArgs.gatewayEnvPrefix)

@Test func gatewayEnvPrefixUnsetsWhenNil() throws {
    #expect(ClaudeLaunchArgs.gatewayEnvPrefix(nil) == "unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS && ")
}

@Test func gatewayEnvPrefixAssignsSingleHeader() throws {
    let resolved = GatewayResolver.Resolved(
        baseURL: "https://corveil.io",
        customHeaders: "x-citadel-api-key: Bearer sk-1"
    )
    let prefix = ClaudeLaunchArgs.gatewayEnvPrefix(resolved)
    #expect(prefix == "ANTHROPIC_BASE_URL='https://corveil.io' ANTHROPIC_CUSTOM_HEADERS='x-citadel-api-key: Bearer sk-1' ")
}

@Test func gatewayEnvPrefixOmitsMultiLineHeadersFromLine() throws {
    // A multi-header value has an embedded newline; pasting it onto the launch
    // line would submit the command early, so it's omitted (settings.local.json
    // carries it). baseURL is still set.
    let resolved = GatewayResolver.Resolved(
        baseURL: "https://corveil.io",
        customHeaders: "x-a: one\nx-b: two"
    )
    let prefix = ClaudeLaunchArgs.gatewayEnvPrefix(resolved)
    #expect(prefix == "ANTHROPIC_BASE_URL='https://corveil.io' ")
    #expect(!prefix.contains("\n"))
}
