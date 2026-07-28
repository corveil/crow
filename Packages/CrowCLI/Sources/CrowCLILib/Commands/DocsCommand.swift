import ArgumentParser
import CrowIPC
import Foundation

/// Regenerate `docs/cli.md` from the command tree's own ArgumentParser metadata
/// (CROW-808).
///
/// Purely local — it never touches the socket, so it works with `crowd` down.
/// Hidden from `crow --help` because it is a repo-maintenance verb, not part of
/// the control plane; `make docs` is the front door.
public struct GenerateDocs: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "generate-docs",
        abstract: "Regenerate the generated CLI reference from ArgumentParser metadata",
        discussion: """
        Writes every subcommand and flag the binary accepts to docs/cli.md. \
        Run it after adding or changing a command; `make docs` does exactly this. \
        Use --check in a script to assert the committed file is current without \
        writing anything — it exits non-zero when the file is stale or missing.
        """,
        shouldDisplay: false
    )

    @Option(name: .long, help: "Path to write (default: docs/cli.md, relative to the current directory)")
    var output: String?

    @Flag(name: .long, help: "Verify the file on disk instead of writing it; exits non-zero when stale")
    var check: Bool = false

    public init() {}

    public func run() throws {
        let path = output ?? CLIDocs.outputPath
        let generated = try CLIDocs.markdown()
        let url = URL(fileURLWithPath: path)

        if check {
            let onDisk = try? String(contentsOf: url, encoding: .utf8)
            guard onDisk == generated else {
                let reason = onDisk == nil ? "is missing" : "is out of date"
                FileHandle.standardError.write(Data(
                    "crow: \(path) \(reason) — run `make docs`\n".utf8
                ))
                throw ExitCode.failure
            }
            printJSON(["path": .string(path), "up_to_date": .bool(true)])
            return
        }

        try generated.write(to: url, atomically: true, encoding: .utf8)
        printJSON([
            "path": .string(path),
            "commands": .int(CLIDocs.documentedCommandCount),
            "written": .bool(true),
        ])
    }
}
