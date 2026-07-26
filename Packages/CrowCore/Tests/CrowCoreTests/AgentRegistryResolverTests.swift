import Foundation
import Testing
@testable import CrowCore

// #834: `registeredKind` is the single registry gate every session-creation
// surface (new-session + web/daemon create-manager) funnels a caller-supplied
// `AgentKind` through, replacing the per-surface asymmetry where only the web
// `create-manager` (CROW-593) validated. An unregistered/unknown kind or `nil`
// returns `nil` so the caller falls back to its own configured default.
//
// The registered-kind passthrough is asserted at the surface level in
// CrowEngineTests / CrowDaemonTests, where a real `ClaudeCodeAgent` is
// registered — CrowCore has no concrete `CodingAgent` to register here.

@Suite("AgentRegistry.registeredKind gate")
struct AgentRegistryResolverTests {

    @Test func rejectsAnUnregisteredKind() {
        // A kind value no shipped agent claims — misses even if the process-wide
        // registry has been populated by another test.
        let unknown = AgentKind(rawValue: "crow-834-unregistered-resolver")
        #expect(AgentRegistry.shared.agent(for: unknown) == nil)
        #expect(AgentRegistry.shared.registeredKind(unknown) == nil)
    }

    @Test func passesThroughNil() {
        // No request → no gate decision to make; the caller supplies the default.
        #expect(AgentRegistry.shared.registeredKind(nil) == nil)
    }
}
