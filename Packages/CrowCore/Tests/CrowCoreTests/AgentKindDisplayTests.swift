import Foundation
import Testing
@testable import CrowCore

// Locks in the fallback semantics CROW-427 specifies: when a kind isn't
// registered in `AgentRegistry`, `displayName` must return the kind's raw
// value (e.g. `"cursor"`) and NOT silently degrade to `"Claude Code"`.
// `iconSystemName` must fall back to a neutral SF Symbol (`"sparkles"`) so
// the tab UI doesn't render an empty glyph box. A future refactor that
// "simplifies" `?? rawValue` to `?? "Claude Code"` would reintroduce the
// exact bug this PR fixes; these tests are the regression guard.

@Test func displayNameFallsBackToRawValueWhenKindUnregistered() {
    // Use a kind value that no shipped agent claims so the lookup misses
    // even if the process-wide `AgentRegistry` has been populated by
    // another test.
    let unknown = AgentKind(rawValue: "crow-427-unregistered-fallback")
    #expect(AgentRegistry.shared.agent(for: unknown) == nil)
    #expect(unknown.displayName == "crow-427-unregistered-fallback")
}

@Test func iconSystemNameFallsBackToSparklesWhenKindUnregistered() {
    let unknown = AgentKind(rawValue: "crow-427-unregistered-icon-fallback")
    #expect(AgentRegistry.shared.agent(for: unknown) == nil)
    #expect(unknown.iconSystemName == "sparkles")
}
