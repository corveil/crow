import Foundation
import Testing

@testable import CrowEngine

/// The multi-skill corveil install `Scaffolder` runs at launch and behind the
/// Settings "Reinstall skill" button (CROW-1039): enumerate the binary's
/// embedded skills, install each one independently, aggregate per-skill
/// failures, and never regress below the historical single default when the
/// binary can't be enumerated.
@Suite("Scaffolder — corveil embedded-skill install")
struct ScaffolderCorveilSkillInstallTests {

    // MARK: - Fixtures

    private func makeTempDevRoot() throws -> (dir: String, devRoot: String) {
        let dir = NSTemporaryDirectory().appending("scaffolder-corveil-\(UUID().uuidString)")
        let devRoot = (dir as NSString).appendingPathComponent("devRoot")
        try FileManager.default.createDirectory(atPath: devRoot, withIntermediateDirectories: true)
        return (dir, devRoot)
    }

    @discardableResult
    private func makeScript(_ body: String, in dir: String, named: String = "corveil") throws -> String {
        let path = (dir as NSString).appendingPathComponent(named)
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// A stub `corveil` that enumerates `skills` (one name per line) and, on
    /// `skill install --skill <name> --path <target>`, writes `installed:<name>`
    /// to `<target>` — so a test can prove exactly which skills landed.
    private func makeEnumeratingCorveil(in dir: String, skills: [String]) throws -> String {
        let listing = skills.joined(separator: "\\n")
        return try makeScript(
            #"""
            if [ "$1" = "skill" ] && [ "$2" = "list" ]; then
              printf '\#(listing)\n'
              exit 0
            fi
            if [ "$1" = "skill" ] && [ "$2" = "install" ]; then
              name=default; target=""
              shift 2
              while [ $# -gt 0 ]; do
                case "$1" in
                  --skill) name="$2"; shift 2;;
                  --path) target="$2"; shift 2;;
                  *) shift;;
                esac
              done
              printf 'installed:%s' "$name" > "$target"
              exit 0
            fi
            exit 1
            """#,
            in: dir)
    }

    private func body(ofSkill skill: String, devRoot: String) throws -> String {
        try String(contentsOfFile: CorveilCLI.skillPath(devRoot: devRoot, skill: skill), encoding: .utf8)
    }

    // MARK: - Enumerate + install-each

    @Test func installsEveryEnumeratedSkill() throws {
        let (dir, devRoot) = try makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let names = ["query-corveil", "sample-skill", "worker-runner", "create-corveil-workflow"]
        let binary = try makeEnumeratingCorveil(in: dir, skills: names)

        let warning = Scaffolder(devRoot: devRoot).installCorveilSkill(binary)

        #expect(warning == nil)
        // Every enumerated skill lands as its own `<name>.md`, installed with
        // `--skill <name>` (the stub echoes the name back into the file body).
        for name in names {
            #expect(try body(ofSkill: name, devRoot: devRoot) == "installed:\(name)")
        }
    }

    // MARK: - Fallback when enumeration fails

    @Test func fallsBackToDefaultWhenListFails() throws {
        let (dir, devRoot) = try makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // An older binary with no `skill list` subcommand. Its `skill install`
        // matches ONLY when there is no `--skill` flag (i.e. corveil's own
        // default) — so this both proves the fallback installs query-corveil and
        // that it omits `--skill`, which an ancient binary wouldn't understand.
        let binary = try makeScript(
            #"""
            if [ "$1" = "skill" ] && [ "$2" = "list" ]; then
              echo 'unknown command "list"' >&2
              exit 1
            fi
            if [ "$1" = "skill" ] && [ "$2" = "install" ] && [ "$3" = "--path" ]; then
              printf 'default-install' > "$4"
              exit 0
            fi
            exit 1
            """#,
            in: dir)

        let warning = Scaffolder(devRoot: devRoot).installCorveilSkill(binary)

        #expect(warning == nil)
        #expect(try body(ofSkill: "query-corveil", devRoot: devRoot) == "default-install")
    }

    @Test func fallsBackToDefaultWhenListIsEmpty() throws {
        let (dir, devRoot) = try makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // `skill list` succeeds but prints nothing parseable — still install the
        // default rather than silently installing nothing.
        let binary = try makeScript(
            #"""
            if [ "$1" = "skill" ] && [ "$2" = "list" ]; then
              exit 0
            fi
            if [ "$1" = "skill" ] && [ "$2" = "install" ] && [ "$3" = "--path" ]; then
              printf 'default-install' > "$4"
              exit 0
            fi
            exit 1
            """#,
            in: dir)

        #expect(Scaffolder(devRoot: devRoot).installCorveilSkill(binary) == nil)
        #expect(try body(ofSkill: "query-corveil", devRoot: devRoot) == "default-install")
    }

    // MARK: - Per-skill failure aggregation

    @Test func aggregatesPerSkillFailuresButInstallsTheRest() throws {
        let (dir, devRoot) = try makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // `sample-skill` fails to install; the other two succeed. One bad skill
        // must not abort the others, and the single returned warning must name
        // the failure with corveil's own diagnostic.
        let binary = try makeScript(
            #"""
            if [ "$1" = "skill" ] && [ "$2" = "list" ]; then
              printf 'query-corveil\nsample-skill\nworker-runner\n'
              exit 0
            fi
            if [ "$1" = "skill" ] && [ "$2" = "install" ]; then
              name=""; target=""
              shift 2
              while [ $# -gt 0 ]; do
                case "$1" in
                  --skill) name="$2"; shift 2;;
                  --path) target="$2"; shift 2;;
                  *) shift;;
                esac
              done
              if [ "$name" = "sample-skill" ]; then
                echo 'embed missing for sample-skill' >&2
                exit 7
              fi
              printf 'ok' > "$target"
              exit 0
            fi
            exit 1
            """#,
            in: dir)

        let warning = Scaffolder(devRoot: devRoot).installCorveilSkill(binary)

        // The two good skills landed; the bad one did not.
        #expect(FileManager.default.fileExists(
            atPath: CorveilCLI.skillPath(devRoot: devRoot, skill: "query-corveil")))
        #expect(FileManager.default.fileExists(
            atPath: CorveilCLI.skillPath(devRoot: devRoot, skill: "worker-runner")))
        #expect(!FileManager.default.fileExists(
            atPath: CorveilCLI.skillPath(devRoot: devRoot, skill: "sample-skill")))

        let text = try #require(warning)
        #expect(text.contains("sample-skill"))
        #expect(text.contains("embed missing for sample-skill"))
        #expect(text.contains("1 skill"))
    }

    // MARK: - Unconfigured / broken binary

    @Test func unconfiguredBinaryIsANoOp() throws {
        let (dir, devRoot) = try makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(Scaffolder(devRoot: devRoot).installCorveilSkill(nil) == nil)
        #expect(Scaffolder(devRoot: devRoot).installCorveilSkill("   ") == nil)
        // Nothing was created under .claude/commands.
        #expect(!FileManager.default.fileExists(
            atPath: CorveilCLI.commandsDir(devRoot: devRoot)))
    }

    @Test func nonExecutableBinaryWarnsWithoutRunning() throws {
        let (dir, devRoot) = try makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let warning = Scaffolder(devRoot: devRoot).installCorveilSkill("/nonexistent/corveil")
        #expect(warning?.contains("not executable") == true)
    }

    // MARK: - parseSkillNames

    @Test func parsesOneNamePerLine() {
        #expect(Scaffolder.parseSkillNames(from: "query-corveil\nsample-skill\nworker-runner\n")
            == ["query-corveil", "sample-skill", "worker-runner"])
    }

    @Test func parsesAJSONArrayOfStrings() {
        // A future corveil build may honour `--format json` with a real array.
        #expect(Scaffolder.parseSkillNames(from: #"["query-corveil","sample-skill"]"#)
            == ["query-corveil", "sample-skill"])
    }

    @Test func parsesAJSONArrayOfObjects() {
        let json = #"[{"name":"query-corveil","description":"x"},{"name":"sample-skill"}]"#
        #expect(Scaffolder.parseSkillNames(from: json) == ["query-corveil", "sample-skill"])
    }

    @Test func dropsBannerAndBlankLines() {
        // Only clean slugs survive — a header line, an indented blurb, and blank
        // lines are all rejected so they can't become bogus install targets.
        let chatty = """
        Available skills:
          query-corveil   Walk a Corveil ontology.

        sample-skill
        """
        #expect(Scaffolder.parseSkillNames(from: chatty) == ["sample-skill"])
    }

    @Test func rejectsPathTraversalNames() {
        // A name with a slash or a dot never becomes a `<name>.md` target.
        #expect(Scaffolder.parseSkillNames(from: "../evil\n/etc/passwd\nok-skill")
            == ["ok-skill"])
    }
}
