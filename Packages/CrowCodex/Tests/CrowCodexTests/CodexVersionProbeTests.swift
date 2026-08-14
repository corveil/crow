import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

@Suite("CodexVersionProbe")
struct CodexVersionProbeTests {

    // MARK: - The gate

    @Test func stableAtOrAboveMinimumEnablesAsync() {
        let verdict = CodexVersionProbe.decide(versionOutput: "codex-cli 0.148.0\n")
        #expect(verdict.supported)
        #expect(verdict.detected == AgentSemVer(0, 148, 0))
    }

    @Test func laterStableEnablesAsync() {
        #expect(CodexVersionProbe.decide(versionOutput: "codex-cli 0.149.2").supported)
        #expect(CodexVersionProbe.decide(versionOutput: "codex-cli 1.0.0").supported)
    }

    @Test func currentStableBelowMinimumStaysSync() {
        // 0.147.0 still skips async hooks for every event but SessionEnd, so
        // emitting `async: true` there would delete the hooks Crow's state
        // detection runs on.
        let verdict = CodexVersionProbe.decide(versionOutput: "codex-cli 0.147.0")
        #expect(!verdict.supported)
        #expect(verdict.detected == AgentSemVer(0, 147, 0))
    }

    @Test func preReleaseOfMinimumStaysSync() {
        // Async landed at 0.148.0-alpha.9, so earlier alphas of the same
        // release would silently drop the hooks. Standard semver precedence
        // (pre-release < release) rejects the whole alpha series.
        let verdict = CodexVersionProbe.decide(versionOutput: "codex-cli 0.148.0-alpha.9")
        #expect(!verdict.supported)
        #expect(verdict.detected == AgentSemVer(0, 148, 0, preRelease: "alpha.9"))
    }

    // MARK: - Fail-closed

    @Test func emptyOutputStaysSync() {
        // `BinaryIdentityProbe.run` returns "" on spawn failure or timeout.
        let verdict = CodexVersionProbe.decide(versionOutput: "")
        #expect(!verdict.supported)
        #expect(verdict.detected == nil)
    }

    @Test func unparseableOutputStaysSync() {
        let verdict = CodexVersionProbe.decide(versionOutput: "codex: command not found")
        #expect(!verdict.supported)
        #expect(verdict.detected == nil)
    }

    @Test func unsupportedSentinelIsFailClosed() {
        #expect(!CodexVersionProbe.AsyncHookSupport.unsupported.supported)
        #expect(CodexVersionProbe.AsyncHookSupport.unsupported.detected == nil)
    }

    // MARK: - Log line

    @Test func logLineNamesVersionAndPin() {
        #expect(CodexVersionProbe.decide(versionOutput: "codex-cli 0.148.0").logLine
            .contains("async enabled"))
        let sync = CodexVersionProbe.decide(versionOutput: "codex-cli 0.141.0").logLine
        #expect(sync.contains("sync-only"))
        #expect(sync.contains("0.141.0"), "log must name what was detected")
        #expect(sync.contains("0.148.0"), "log must name the pin so a stale gate is diagnosable")
        #expect(CodexVersionProbe.decide(versionOutput: "").logLine.contains("unreadable"))
    }

    // MARK: - Subprocess path

    @Test func probeParsesRunnerOutput() async {
        let runner = StubShellRunner(output: "codex-cli 0.148.0\n")
        let verdict = await CodexVersionProbe.probe(binaryPath: "/usr/local/bin/codex", runner: runner)
        #expect(verdict.supported)
        #expect(await runner.recordedArgs == ["/usr/local/bin/codex", "--version"])
    }

    @Test func probeFailsClosedWhenRunnerThrows() async {
        let runner = StubShellRunner(
            output: "", error: ShellRunnerError.nonZeroExit(exitCode: 127, output: ""))
        let verdict = await CodexVersionProbe.probe(binaryPath: "/nope/codex", runner: runner)
        #expect(!verdict.supported)
        #expect(verdict.detected == nil)
    }

    @Test func probeKeepsNonZeroExitOutput() async {
        // Some CLIs print their banner and exit non-zero; that banner is still
        // the version. `BinaryIdentityProbe.run` keeps `nonZeroExit` output.
        let runner = StubShellRunner(
            output: "", error: ShellRunnerError.nonZeroExit(exitCode: 1, output: "codex-cli 0.148.0"))
        let verdict = await CodexVersionProbe.probe(binaryPath: "/usr/local/bin/codex", runner: runner)
        #expect(verdict.supported)
    }
}

/// Records the args it was handed and replays a canned result.
private actor StubShellRunner: ShellRunner {
    private let output: String
    private let error: (any Error)?
    private(set) var recordedArgs: [String] = []

    init(output: String, error: (any Error)? = nil) {
        self.output = output
        self.error = error
    }

    func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        recordedArgs = args
        if let error { throw error }
        return output
    }
}
