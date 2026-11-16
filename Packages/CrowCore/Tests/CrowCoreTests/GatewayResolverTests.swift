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

// MARK: - X-Crow-Version (CROW-1458)
//
// These pass `crowVersion:` explicitly and never call `CrowVersionHeader.install`:
// the installed value is process-wide, and the suites around them run in
// parallel and expect no header.

@Test func gatewayResolverAppendsCrowVersionAfterTheGatewayHeaders() throws {
    let gateway = WorkspaceGateway(
        baseURL: "https://corveil.io",
        customHeaders: ["x-citadel-api-key": "sk-plain"]
    )
    let resolved = GatewayResolver.resolve(gateway, crowVersion: "0.2.0+8e32cc67") { _ in nil }
    #expect(resolved?.customHeaders == "x-citadel-api-key: sk-plain\nX-Crow-Version: 0.2.0+8e32cc67")
}

@Test func gatewayResolverSendsNoCrowVersionWithoutAGateway() throws {
    let empty = WorkspaceGateway(baseURL: "", customHeaders: [:])
    #expect(GatewayResolver.resolve(empty, crowVersion: "0.2.0+8e32cc67") { _ in nil } == nil)
}

@Test func gatewayResolverOmitsCrowVersionWhenNoneInstalled() throws {
    let gateway = WorkspaceGateway(baseURL: "https://corveil.io", customHeaders: ["x-k": "v"])
    #expect(GatewayResolver.resolve(gateway, crowVersion: nil) { _ in nil }?.customHeaders == "x-k: v")
}

@Test func gatewayResolverKeepsAUserConfiguredCrowVersion() throws {
    // Any casing counts as the same header; the user's value wins and Crow
    // doesn't add a second one.
    for name in ["X-Crow-Version", "x-crow-version", "X-CROW-VERSION"] {
        let gateway = WorkspaceGateway(
            baseURL: "https://corveil.io",
            customHeaders: ["x-k": "v", name: "pinned"]
        )
        let lines = GatewayResolver.resolve(gateway, crowVersion: "0.2.0+8e32cc67") { _ in nil }?
            .customHeaders.split(separator: "\n").map(String.init) ?? []
        #expect(lines.sorted() == ["\(name): pinned", "x-k: v"].sorted(), "\(name)")
    }
}

@Test func gatewayResolverDoesNotReplaceAFailedUserCrowVersionReference() throws {
    // The user's header is an `op://` reference that fails to resolve. It's
    // dropped like any failed header, and Crow does not substitute its own.
    let gateway = WorkspaceGateway(
        baseURL: "https://corveil.io",
        customHeaders: ["x-k": "v", "X-Crow-Version": "op://V/I/f"]
    )
    let resolved = GatewayResolver.resolve(gateway, crowVersion: "0.2.0+8e32cc67") { _ in nil }
    #expect(resolved?.customHeaders == "x-k: v")
}

@Test func crowVersionHeaderValueComesFromBuildInfo() throws {
    #expect(CrowVersionHeader.value(for: BuildInfo(version: "0.2.0", gitSha: "8e32cc67", buildDate: "2026-11-16"))
        == "0.2.0+8e32cc67")
    // The daemon's fallback for an unstamped build.
    #expect(CrowVersionHeader.value(for: BuildInfo(version: "?", gitSha: "dev", buildDate: "")) == "unknown+dev")
    #expect(CrowVersionHeader.value(for: BuildInfo(version: "0.2.0", gitSha: "dev", buildDate: "")) == "0.2.0+dev")
}

@Test func crowVersionHeaderValueHoldsOnlyTheAllowedCharacters() throws {
    let hostile = BuildInfo(
        version: "0.2.0\r\nX-Evil: 1 /Users/someone",
        gitSha: "abc$(id)'\"",
        buildDate: "")
    let value = CrowVersionHeader.value(for: hostile)
    #expect(value == "0.2.0X-Evil1Userssomeone+abcid")
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
    #expect(value.unicodeScalars.allSatisfy { allowed.contains($0) })
    // Bounded, whatever version.json says.
    let long = CrowVersionHeader.value(for: BuildInfo(
        version: String(repeating: "9", count: 500), gitSha: "a", buildDate: ""))
    #expect(long.count == CrowVersionHeader.maxComponentLength + 2)
}

@Test func crowVersionHeaderMatchesNamesCaseInsensitively() throws {
    #expect(CrowVersionHeader.isConfigured(in: ["x-crow-version"]))
    #expect(CrowVersionHeader.isConfigured(in: ["Other", "X-CROW-VERSION"]))
    #expect(!CrowVersionHeader.isConfigured(in: ["x-crow-versions", "x-citadel-api-key"]))
}
