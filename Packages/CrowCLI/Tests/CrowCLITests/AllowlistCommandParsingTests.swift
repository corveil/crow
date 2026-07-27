import Testing
@testable import CrowCLILib

// MARK: - promote-allowlist (#819)

@Test func promoteAllowlistParsesRepeatedPatterns() throws {
    let cmd = try PromoteAllowlist.parse([
        "--pattern", "Bash(npm test:*)",
        "--pattern", "Read",
    ])
    #expect(cmd.pattern == ["Bash(npm test:*)", "Read"])
}

/// The `.singleValue` regression guard. With ArgumentParser's default
/// `.upToNextOption`, a pattern containing spaces would be split across
/// elements — and real allowlist patterns routinely contain them.
@Test func promoteAllowlistKeepsSpacesAndParensInOnePattern() throws {
    let cmd = try PromoteAllowlist.parse(["--pattern", "Bash(npm run build:*)"])
    #expect(cmd.pattern == ["Bash(npm run build:*)"])
}

@Test func promoteAllowlistRequiresAtLeastOnePattern() {
    // validate() runs during parse, so the empty case throws here.
    #expect(throws: (any Error).self) { _ = try PromoteAllowlist.parse([]) }
}

@Test func promoteAllowlistRejectsAllBlankPatterns() {
    #expect(throws: (any Error).self) {
        _ = try PromoteAllowlist.parse(["--pattern", "   ", "--pattern", ""])
    }
}

@Test func promoteAllowlistAcceptsABlankAlongsideARealPattern() throws {
    // The blank is dropped by normalization rather than rejecting the call.
    let cmd = try PromoteAllowlist.parse(["--pattern", "Read", "--pattern", "  "])
    #expect(try normalizedAllowlistPatterns(cmd.pattern) == ["Read"])
}

// MARK: - list-allowlist / refresh-allowlist (#819)

@Test func listAndRefreshAllowlistTakeNoArguments() throws {
    _ = try ListAllowlist.parse([])
    _ = try RefreshAllowlist.parse([])
    #expect(throws: (any Error).self) { _ = try ListAllowlist.parse(["--pattern", "Read"]) }
    #expect(throws: (any Error).self) { _ = try RefreshAllowlist.parse(["--session", "x"]) }
}
