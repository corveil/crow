import Foundation
import Testing

@testable import CrowEngine

/// `CorveilCLI` is the one place Settings' **Verify** / **Reinstall skill** and
/// `crow corveil` agree on what those buttons mean (CROW-1011), so its
/// decisions are pinned here rather than through either door.
@Suite("Corveil CLI actions")
struct CorveilCLITests {

    // MARK: - Fixtures

    /// A throwaway directory that cleans itself up.
    private func makeTempDir() throws -> String {
        let path = NSTemporaryDirectory().appending("corveil-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Write an executable shell script and return its path.
    @discardableResult
    private func makeScript(_ body: String, in dir: String, named: String = "corveil") throws -> String {
        let path = (dir as NSString).appendingPathComponent(named)
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    // MARK: - resolvePath

    @Test func explicitPathWinsOverConfiguredOne() {
        #expect(CorveilCLI.resolvePath(explicit: "/a/corveil", configured: "/b/corveil") == "/a/corveil")
    }

    @Test func blankExplicitPathFallsThroughToConfig() {
        // `crow corveil verify --path ""` and a browser sending an empty field
        // both mean "use what Settings has", not "run the empty string".
        #expect(CorveilCLI.resolvePath(explicit: "", configured: "/b/corveil") == "/b/corveil")
        #expect(CorveilCLI.resolvePath(explicit: "   ", configured: "/b/corveil") == "/b/corveil")
        #expect(CorveilCLI.resolvePath(explicit: nil, configured: "/b/corveil") == "/b/corveil")
    }

    @Test func nothingConfiguredResolvesToNil() {
        #expect(CorveilCLI.resolvePath(explicit: nil, configured: nil) == nil)
        #expect(CorveilCLI.resolvePath(explicit: "", configured: "  ") == nil)
    }

    @Test func resolvedPathIsTrimmed() {
        // A path pasted with a trailing newline is the common shape of this, and
        // `isExecutableFile` would reject it for a reason nobody could see.
        #expect(CorveilCLI.resolvePath(explicit: " /a/corveil\n", configured: nil) == "/a/corveil")
    }

    // MARK: - verify

    @Test func verifyReportsTheVersionLine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = try makeScript("echo 'corveil 1.2.3'", in: dir)

        let outcome = CorveilCLI.verify(path: script)
        #expect(outcome.ok)
        #expect(outcome.message == "corveil 1.2.3")
        #expect(outcome.path == script)
    }

    @Test func verifyReadsStderrWhenThatIsWhereVersionWent() throws {
        // A `--version` that writes to stderr and exits 0 is a working binary.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = try makeScript("echo 'corveil 9.9.9' >&2", in: dir)

        let outcome = CorveilCLI.verify(path: script)
        #expect(outcome.ok)
        #expect(outcome.message == "corveil 9.9.9")
    }

    @Test func verifyReportsOnlyTheFirstLineOfChattyOutput() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = try makeScript("printf 'corveil 1.0\\nbuilt from abc123\\n'", in: dir)

        // The result is one inline line in Settings, so a multi-line banner is
        // truncated rather than allowed to reflow the whole panel.
        #expect(CorveilCLI.verify(path: script).message == "corveil 1.0")
    }

    @Test func verifyFailsWithTheDiagnosticOnNonZeroExit() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = try makeScript("echo 'unknown flag --version' >&2; exit 2", in: dir)

        let outcome = CorveilCLI.verify(path: script)
        #expect(!outcome.ok)
        #expect(outcome.message == "unknown flag --version")
    }

    @Test func verifyFallsBackToTheExitCodeWhenNothingWasPrinted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = try makeScript("exit 3", in: dir)

        let outcome = CorveilCLI.verify(path: script)
        #expect(!outcome.ok)
        #expect(outcome.message == "exit code 3")
    }

    @Test func verifyRejectsANonExecutableFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("not-a-binary")
        try "text".write(toFile: path, atomically: true, encoding: .utf8)

        let outcome = CorveilCLI.verify(path: path)
        #expect(!outcome.ok)
        #expect(outcome.message == "Not executable: \(path)")
    }

    @Test func verifyRejectsAMissingFile() {
        let path = "/nonexistent/corveil-\(UUID().uuidString)"
        let outcome = CorveilCLI.verify(path: path)
        #expect(!outcome.ok)
        // Missing and non-executable are the same user-facing problem — "this
        // path does not name a runnable binary" — and are reported as one.
        #expect(outcome.message == "Not executable: \(path)")
    }

    // MARK: - reinstallSkill

    @Test func reinstallWritesTheSkillFromTheBinary() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let devRoot = (dir as NSString).appendingPathComponent("devRoot")
        try FileManager.default.createDirectory(atPath: devRoot, withIntermediateDirectories: true)

        // Stand in for `corveil skill install --path <target>`: write the body
        // the real CLI would write to whatever `--path` names.
        let script = try makeScript(
            #"""
            if [ "$1" = "skill" ] && [ "$2" = "install" ] && [ "$3" = "--path" ]; then
              printf 'installed body' > "$4"
              exit 0
            fi
            exit 1
            """#,
            in: dir)

        let outcome = CorveilCLI.reinstallSkill(path: script, devRoot: devRoot)
        #expect(outcome.ok)
        #expect(outcome.message == "Skill reinstalled")

        let installed = try String(contentsOfFile: CorveilCLI.skillPath(devRoot: devRoot), encoding: .utf8)
        #expect(installed == "installed body")
    }

    @Test func reinstallSurfacesTheLaunchTimeWarningOnFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let devRoot = (dir as NSString).appendingPathComponent("devRoot")
        try FileManager.default.createDirectory(atPath: devRoot, withIntermediateDirectories: true)
        let script = try makeScript("echo 'no such subcommand: skill' >&2; exit 1", in: dir)

        let outcome = CorveilCLI.reinstallSkill(path: script, devRoot: devRoot)
        #expect(!outcome.ok)
        // The button's failure text IS the startup warning text — one answer to
        // "is corveil broken?", not a button answer and a launch answer.
        #expect(outcome.message.contains("no such subcommand: skill"))
    }

    @Test func reinstallRejectsANonExecutablePath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let outcome = CorveilCLI.reinstallSkill(path: "/nonexistent/corveil", devRoot: dir)
        #expect(!outcome.ok)
        #expect(outcome.message.contains("not executable"))
    }

    // MARK: - skillPath

    @Test func skillPathIsTheFileScaffoldInstalls() {
        // Pinned because Settings names this file to the user; `Scaffolder`
        // installs to exactly this path via the same function.
        #expect(CorveilCLI.skillPath(devRoot: "/dev/root")
            == "/dev/root/.claude/commands/query-corveil.md")
    }
}
