import Foundation
import Testing
@testable import CrowCore

@Suite("AgentSemVer")
struct AgentSemVerTests {

    // MARK: - Parsing

    @Test func parsesPlainTriple() {
        #expect(AgentSemVer.parse(token: "0.141.0") == AgentSemVer(0, 141, 0))
        #expect(AgentSemVer.parse(token: "1.18.4") == AgentSemVer(1, 18, 4))
    }

    @Test func parsesOptionalLeadingV() {
        #expect(AgentSemVer.parse(token: "v0.148.0") == AgentSemVer(0, 148, 0))
        #expect(AgentSemVer.parse(token: "V1.0.0") == AgentSemVer(1, 0, 0))
    }

    @Test func parsesPreReleaseSuffix() {
        let parsed = AgentSemVer.parse(token: "0.148.0-alpha.9")
        #expect(parsed == AgentSemVer(0, 148, 0, preRelease: "alpha.9"))
        #expect(parsed?.preRelease == "alpha.9")
    }

    @Test func dropsBuildMetadata() {
        // Semver excludes build metadata from precedence, so it must not end up
        // in `preRelease` (where it would sort the build *below* its release).
        #expect(AgentSemVer.parse(token: "1.2.3+build.5") == AgentSemVer(1, 2, 3))
        // A `-` inside build metadata is not a pre-release separator.
        #expect(AgentSemVer.parse(token: "1.2.3+sha-abc") == AgentSemVer(1, 2, 3))
    }

    @Test func rejectsPartialTokens() {
        // Whole-token matching is the guard against reading a version out of a
        // path — the reason this doesn't scan for a triple inside the token.
        #expect(AgentSemVer.parse(token: "/Users/x/.nvm/versions/node/v22.22.2/bin/codex") == nil)
        #expect(AgentSemVer.parse(token: "codex-cli") == nil)
        #expect(AgentSemVer.parse(token: "1.2") == nil)
        #expect(AgentSemVer.parse(token: "1.2.3.4") == nil)
        #expect(AgentSemVer.parse(token: "1.2.x") == nil)
        #expect(AgentSemVer.parse(token: "1..3") == nil)
        #expect(AgentSemVer.parse(token: "") == nil)
        #expect(AgentSemVer.parse(token: "1.2.3-") == nil, "empty pre-release is malformed")
    }

    @Test func rejectsOversizedComponents() {
        // Too large for `Int` — must fail to parse rather than trap or wrap.
        #expect(AgentSemVer.parse(token: "1.99999999999999999999.0") == nil)
    }

    // MARK: - Scanning real banner output

    @Test func firstTokenReadsCodexBanner() {
        #expect(AgentSemVer.firstToken(in: "codex-cli 0.141.0\n") == AgentSemVer(0, 141, 0))
    }

    @Test func firstTokenSkipsWarningPreamble() {
        // Observed on a real box: the CLI prints a PATH-aliasing warning before
        // its banner. Nothing in the preamble is a whole-token version.
        let output = """
        WARNING: proceeding, even though we could not create PATH aliases: Operation not permitted (os error 1)
        codex-cli 0.148.0
        """
        #expect(AgentSemVer.firstToken(in: output) == AgentSemVer(0, 148, 0))
    }

    @Test func firstTokenIgnoresVersionShapedPathSegments() {
        // The failure whole-token matching exists to prevent: a node path in the
        // preamble must not be read as the agent's version.
        let output = """
        resolved via /Users/x/.nvm/versions/node/v22.22.2/bin/codex
        codex-cli 0.148.0
        """
        #expect(AgentSemVer.firstToken(in: output) == AgentSemVer(0, 148, 0))
    }

    @Test func firstTokenReturnsNilWhenAbsent() {
        #expect(AgentSemVer.firstToken(in: "") == nil)
        #expect(AgentSemVer.firstToken(in: "command not found: codex") == nil)
    }

    // MARK: - Ordering

    @Test func ordersByTriple() {
        #expect(AgentSemVer(1, 17, 10) < AgentSemVer(1, 18, 0))
        #expect(AgentSemVer(1, 18, 0) < AgentSemVer(1, 18, 1))
        #expect(!(AgentSemVer(2, 0, 0) < AgentSemVer(1, 99, 99)))
        #expect(AgentSemVer(0, 141, 0) < AgentSemVer(0, 148, 0))
    }

    @Test func preReleaseSortsBelowItsRelease() {
        // The rule the Codex gate depends on: an alpha of 0.148.0 is not 0.148.0.
        #expect(AgentSemVer(0, 148, 0, preRelease: "alpha.9") < AgentSemVer(0, 148, 0))
        #expect(!(AgentSemVer(0, 148, 0, preRelease: "alpha.9") >= AgentSemVer(0, 148, 0)))
        // But it still outranks the previous release.
        #expect(AgentSemVer(0, 147, 0) < AgentSemVer(0, 148, 0, preRelease: "alpha.9"))
        // And a later release outranks any pre-release of an earlier one.
        #expect(AgentSemVer(0, 148, 0, preRelease: "rc.1") < AgentSemVer(0, 149, 0))
    }

    @Test func releasesCompareEqualIgnoringNothing() {
        #expect(AgentSemVer(1, 2, 3) == AgentSemVer(1, 2, 3))
        #expect(AgentSemVer(1, 2, 3, preRelease: "a") != AgentSemVer(1, 2, 3))
    }

    // MARK: - Display

    @Test func displayStringRoundTrips() {
        #expect(AgentSemVer(0, 148, 0).displayString == "0.148.0")
        #expect(AgentSemVer(0, 148, 0, preRelease: "alpha.9").displayString == "0.148.0-alpha.9")
    }
}
