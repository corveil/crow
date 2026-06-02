import Foundation
import Testing
@testable import CrowCore

@Suite("TerminalReadiness")
struct TerminalReadinessTests {

    // MARK: - Ordering

    @Test func statesAreOrdered() {
        #expect(TerminalReadiness.uninitialized < .surfaceCreated)
        #expect(TerminalReadiness.surfaceCreated < .timedOut)
        #expect(TerminalReadiness.timedOut < .shellReady)
        #expect(TerminalReadiness.shellReady < .agentLaunched)
    }

    @Test func transitiveOrdering() {
        #expect(TerminalReadiness.uninitialized < .agentLaunched)
        #expect(TerminalReadiness.uninitialized < .shellReady)
        #expect(TerminalReadiness.surfaceCreated < .agentLaunched)
        #expect(TerminalReadiness.timedOut < .agentLaunched)
    }

    @Test func timedOutGatesAutoPaste() {
        // The launchAgent guard is `== .shellReady`, so .timedOut must NOT
        // satisfy `< .shellReady ? false : true` equality checks. Verify the
        // ordering keeps .timedOut strictly below .shellReady.
        #expect(TerminalReadiness.timedOut < .shellReady)
        #expect(TerminalReadiness.timedOut != .shellReady)
    }

    @Test func equalStatesAreNotLessThan() {
        #expect(!(TerminalReadiness.uninitialized < .uninitialized))
        #expect(!(TerminalReadiness.shellReady < .shellReady))
        #expect(!(TerminalReadiness.agentLaunched < .agentLaunched))
        #expect(!(TerminalReadiness.timedOut < .timedOut))
    }

    // MARK: - Equality

    @Test func equalityHolds() {
        #expect(TerminalReadiness.uninitialized == .uninitialized)
        #expect(TerminalReadiness.surfaceCreated == .surfaceCreated)
        #expect(TerminalReadiness.shellReady == .shellReady)
        #expect(TerminalReadiness.agentLaunched == .agentLaunched)
    }

    @Test func differentStatesAreNotEqual() {
        #expect(TerminalReadiness.uninitialized != .surfaceCreated)
        #expect(TerminalReadiness.shellReady != .agentLaunched)
    }

    // MARK: - Raw Values

    @Test func rawValues() {
        #expect(TerminalReadiness.uninitialized.rawValue == "uninitialized")
        #expect(TerminalReadiness.surfaceCreated.rawValue == "surfaceCreated")
        #expect(TerminalReadiness.timedOut.rawValue == "timedOut")
        #expect(TerminalReadiness.shellReady.rawValue == "shellReady")
        #expect(TerminalReadiness.agentLaunched.rawValue == "agentLaunched")
    }

    // MARK: - Codable

    @Test func codableRoundTrip() throws {
        let cases: [TerminalReadiness] = [.uninitialized, .surfaceCreated, .timedOut, .shellReady, .agentLaunched]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for state in cases {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(TerminalReadiness.self, from: data)
            #expect(decoded == state)
        }
    }
}
