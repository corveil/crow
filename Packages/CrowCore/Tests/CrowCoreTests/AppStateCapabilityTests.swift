import Foundation
import Testing
@testable import CrowCore

// MARK: - AppState Capability Tests
//
// Cover the capability accessor that replaces UI provider guards
// (`session.provider == .github`). The accessor delegates to a resolver
// closure wired by AppDelegate using `ProviderManager.taskBackend(for:)` —
// these tests use stub closures to verify the wiring contract rather than
// the live capability lookup, which is covered separately by
// `BackendsTests.testGitHubTaskBackendDeclaresCapabilities`. See ADR 0005.

@MainActor @Test func canSetProjectStatusReturnsFalseWhenResolverUnset() {
    let appState = AppState()
    let session = Session(name: "no-resolver", provider: .github)
    #expect(appState.canSetProjectStatus(for: session) == false)
}

@MainActor @Test func canSetProjectStatusReturnsResolverFalse() {
    let appState = AppState()
    appState.canSetProjectStatusResolver = { _ in false }
    let session = Session(name: "resolver-false", provider: .github)
    #expect(appState.canSetProjectStatus(for: session) == false)
}

@MainActor @Test func canSetProjectStatusReturnsResolverTrue() {
    let appState = AppState()
    appState.canSetProjectStatusResolver = { _ in true }
    let session = Session(name: "resolver-true", provider: .github)
    #expect(appState.canSetProjectStatus(for: session) == true)
}

@MainActor @Test func canSetProjectStatusPassesSessionToResolver() {
    let appState = AppState()
    let target = Session(name: "passed-through", provider: .gitlab)
    var observed: Session?
    appState.canSetProjectStatusResolver = { session in
        observed = session
        return session.provider == .gitlab
    }
    let result = appState.canSetProjectStatus(for: target)
    #expect(observed?.id == target.id)
    #expect(result == true)
}

@MainActor @Test func canSetProjectStatusDelegatesForNilProvider() {
    // The accessor itself does not short-circuit on `provider == nil`;
    // that lives in the resolver body wired by AppDelegate. This documents
    // the contract so a future refactor doesn't quietly move the gating.
    let appState = AppState()
    var called = false
    appState.canSetProjectStatusResolver = { _ in
        called = true
        return false
    }
    let session = Session(name: "no-provider")
    _ = appState.canSetProjectStatus(for: session)
    #expect(called == true)
}
