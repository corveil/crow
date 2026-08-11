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

// MARK: - Quote-wrapped values (CROW-969)

@Test func gatewayResolverPassesQuoteWrappedValueThroughUnchanged() throws {
    let gateway = WorkspaceGateway(
        baseURL: "https://corveil.io",
        customHeaders: ["x-citadel-api-key": "\"Bearer sk-1\""]
    )
    // Warn, don't strip. Writes are rejected now, but a config written before
    // that check still has to launch — and stripping would mean guessing the
    // quotes aren't part of the secret. A loud rejection at the gateway beats
    // authenticating with a credential the user never verified. This pins the
    // contract so a future "helpful" strip fails here.
    let resolved = GatewayResolver.resolve(gateway) { _ in nil }
    #expect(resolved?.customHeaders == "x-citadel-api-key: \"Bearer sk-1\"")
}

@Test func gatewayResolverDoesNotResolveQuoteWrappedOpReference() throws {
    let gateway = WorkspaceGateway(
        baseURL: "https://corveil.io",
        customHeaders: ["x-citadel-api-key": "\"op://Vault/Item/field\""]
    )
    // Documents *why* the resolve-time warning is needed: the quotes defeat
    // `hasPrefix("op://")`, so the reference silently falls into the plaintext
    // arm and is never resolved at all.
    let resolved = GatewayResolver.resolve(gateway) { _ in
        Issue.record("op read must not be called for a quote-wrapped reference")
        return "Bearer sk-resolved"
    }
    #expect(resolved?.customHeaders == "x-citadel-api-key: \"op://Vault/Item/field\"")
}
