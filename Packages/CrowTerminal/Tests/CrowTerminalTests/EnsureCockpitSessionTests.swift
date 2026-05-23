import Foundation
import Testing
@testable import CrowTerminal

/// Unit tests for `TmuxBackend.ensureCockpitSession` — the create-or-adopt
/// logic that survives the launch race (#326 × #293). Runs WITHOUT a real
/// tmux server: a `FakeStarter` simulates the `new-session` race outcomes.
///
/// The Adopt and Genuine-failure cases are the regression guard requested in
/// the #336 review: if the `catch` ever regresses to a bare `throw`, the
/// Adopt case fails.
@Suite("ensureCockpitSession adopt/create logic")
struct EnsureCockpitSessionTests {

    /// Drives `hasSession()` from a queued sequence (last value repeats once
    /// the queue is down to one) and optionally makes `newSessionDetached`
    /// throw, so each race outcome can be reproduced deterministically.
    final class FakeStarter: CockpitSessionStarter {
        private var hasSessionResults: [Bool]
        private let newSessionError: Error?
        private(set) var newSessionCallCount = 0
        private(set) var hasSessionCallCount = 0

        init(hasSessionSequence: [Bool], newSessionError: Error? = nil) {
            self.hasSessionResults = hasSessionSequence
            self.newSessionError = newSessionError
        }

        func hasSession() -> Bool {
            hasSessionCallCount += 1
            if hasSessionResults.count > 1 { return hasSessionResults.removeFirst() }
            return hasSessionResults.first ?? false
        }

        func newSessionDetached(configPath: String?, env: [String: String], command: String?) throws {
            newSessionCallCount += 1
            if let newSessionError { throw newSessionError }
        }
    }

    private static let duplicateSessionError = TmuxError.cliFailed(
        args: ["new-session", "-d", "-s", "crow-cockpit"],
        status: 1,
        stdout: "",
        stderr: "duplicate session: crow-cockpit"
    )

    @Test func alreadyLiveAdoptsWithoutCreating() throws {
        let fake = FakeStarter(hasSessionSequence: [true])
        try TmuxBackend.ensureCockpitSession(fake, configPath: nil)
        #expect(fake.newSessionCallCount == 0)
        #expect(fake.hasSessionCallCount == 1)
    }

    @Test func coldStartCreatesSession() throws {
        let fake = FakeStarter(hasSessionSequence: [false])
        try TmuxBackend.ensureCockpitSession(fake, configPath: nil)
        #expect(fake.newSessionCallCount == 1)
    }

    /// Lost the creation race: `new-session` fails with "duplicate session"
    /// but the session now exists, so we adopt rather than throw.
    @Test func lostRaceAdoptsInsteadOfThrowing() throws {
        let fake = FakeStarter(
            hasSessionSequence: [false, true],
            newSessionError: Self.duplicateSessionError
        )
        try TmuxBackend.ensureCockpitSession(fake, configPath: nil)
        #expect(fake.newSessionCallCount == 1)
        #expect(fake.hasSessionCallCount == 2)
    }

    /// Genuine failure (bad conf, tmux gone, …): `new-session` throws and the
    /// session still does not exist, so the original error must propagate.
    @Test func genuineFailureRethrows() {
        let fake = FakeStarter(
            hasSessionSequence: [false, false],
            newSessionError: Self.duplicateSessionError
        )
        #expect(throws: TmuxError.self) {
            try TmuxBackend.ensureCockpitSession(fake, configPath: nil)
        }
    }
}
