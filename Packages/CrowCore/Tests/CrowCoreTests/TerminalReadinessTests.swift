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
        #expect(TerminalReadiness.shellReady < .claudeLaunched)
    }

    @Test func transitiveOrdering() {
        #expect(TerminalReadiness.uninitialized < .claudeLaunched)
        #expect(TerminalReadiness.uninitialized < .shellReady)
        #expect(TerminalReadiness.surfaceCreated < .claudeLaunched)
        #expect(TerminalReadiness.timedOut < .claudeLaunched)
    }

    @Test func timedOutGatesAutoPaste() {
        // The launchClaude guard is `== .shellReady`, so .timedOut must NOT
        // satisfy `< .shellReady ? false : true` equality checks. Verify the
        // ordering keeps .timedOut strictly below .shellReady.
        #expect(TerminalReadiness.timedOut < .shellReady)
        #expect(TerminalReadiness.timedOut != .shellReady)
    }

    @Test func equalStatesAreNotLessThan() {
        #expect(!(TerminalReadiness.uninitialized < .uninitialized))
        #expect(!(TerminalReadiness.shellReady < .shellReady))
        #expect(!(TerminalReadiness.claudeLaunched < .claudeLaunched))
        #expect(!(TerminalReadiness.timedOut < .timedOut))
    }

    // MARK: - Equality

    @Test func equalityHolds() {
        #expect(TerminalReadiness.uninitialized == .uninitialized)
        #expect(TerminalReadiness.surfaceCreated == .surfaceCreated)
        #expect(TerminalReadiness.shellReady == .shellReady)
        #expect(TerminalReadiness.claudeLaunched == .claudeLaunched)
    }

    @Test func differentStatesAreNotEqual() {
        #expect(TerminalReadiness.uninitialized != .surfaceCreated)
        #expect(TerminalReadiness.shellReady != .claudeLaunched)
    }

    // MARK: - Raw Values

    @Test func rawValues() {
        #expect(TerminalReadiness.uninitialized.rawValue == "uninitialized")
        #expect(TerminalReadiness.surfaceCreated.rawValue == "surfaceCreated")
        #expect(TerminalReadiness.timedOut.rawValue == "timedOut")
        #expect(TerminalReadiness.shellReady.rawValue == "shellReady")
        #expect(TerminalReadiness.claudeLaunched.rawValue == "claudeLaunched")
    }

    // MARK: - Codable

    @Test func codableRoundTrip() throws {
        let cases: [TerminalReadiness] = [.uninitialized, .surfaceCreated, .timedOut, .shellReady, .claudeLaunched]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for state in cases {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(TerminalReadiness.self, from: data)
            #expect(decoded == state)
        }
    }
}
