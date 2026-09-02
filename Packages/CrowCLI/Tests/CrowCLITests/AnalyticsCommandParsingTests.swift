import Testing
@testable import CrowCLILib

private let validUUID = "550e8400-e29b-41d4-a716-446655440000"

// MARK: - list-artifacts (#819)

@Test func listArtifactsParsesSessionUUID() throws {
    let cmd = try ListArtifacts.parse(["--session", validUUID])
    #expect(cmd.session == validUUID)
}

@Test func listArtifactsRejectsInvalidSession() {
    for bad in ["not-a-uuid", "", "550e8400-e29b-41d4-a716"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            _ = try ListArtifacts.parse(["--session", bad])
        }
    }
}

@Test func listArtifactsRequiresSession() {
    #expect(throws: (any Error).self) { _ = try ListArtifacts.parse([]) }
}

// MARK: - get-scorecard / rebuild-scorecard / get-state (#819)

@Test func zeroArgAnalyticsCommandsParse() throws {
    _ = try GetScorecard.parse([])
    _ = try RebuildScorecard.parse([])
    _ = try GetState.parse([])
    #expect(throws: (any Error).self) { _ = try GetState.parse(["--session", validUUID]) }
}

// MARK: - Registration

/// A command that isn't in `CrowCommand.configuration.subcommands` compiles,
/// parses, and tests green while being unreachable from the `crow` binary —
/// so pin the wiring itself.
@Test func crowRootRegistersTheNewVerbs() {
    let registered = Set(CrowCommand.configuration.subcommands.map { $0.configuration.commandName })
    for verb in [
        "get-scorecard", "rebuild-scorecard", "get-state", "list-artifacts",
    ] {
        #expect(registered.contains(verb), "\(verb) is not registered on the crow root command")
    }
}
