import ArgumentParser
import Foundation
import Testing
@testable import CrowCLILib

/// The doc-drift guard (CROW-808).
///
/// The parity tests prove a verb *exists*; these prove it is *documented*. A new
/// subcommand that nobody writes up fails the build here rather than shipping
/// invisible — which is how `crow job`, `set-locked`, `recreate-terminal` and
/// `resync-jira` all went missing from the reference before this existed.
///
/// These run in CI's Linux lane, which builds only `Packages/CrowCLI` and never
/// links the `crow` executable — so everything here works in-process, off the
/// command tree itself, with no binary to invoke.

// MARK: - Repo layout

/// The repo root, derived from this file's compile-time path
/// (`<root>/Packages/CrowCLI/Tests/CrowCLITests/CLIDocsTests.swift`).
private let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url = url.deletingLastPathComponent() }
    return url
}()

private func repoFile(_ path: String) throws -> String {
    let url = repoRoot.appendingPathComponent(path)
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
        throw DocsTestError.unreadable(url.path)
    }
    return contents
}

private enum DocsTestError: Error, CustomStringConvertible {
    case unreadable(String)

    var description: String {
        switch self {
        case .unreadable(let path):
            return "Could not read \(path) — is the repo root still 5 levels above this test file?"
        }
    }
}

/// Every command below the `crow` root, as invocation strings.
private var invocations: [String] {
    CLIDocs.tree().filter { !$0.isRoot }.map(\.invocation)
}

/// Just the fenced code blocks of a Markdown document, concatenated.
///
/// The hand-written docs are checked against this rather than the whole file so
/// that "documented" means "there is a command here you can copy and run". A
/// passing mention in prose is not enough: `crow transition-ticket` had nothing
/// but a cross-reference link — pointing at an anchor that did not exist — and
/// a whole-file substring match called that documented.
private func codeBlocks(of markdown: String) -> String {
    var blocks: [String] = []
    var insideFence = false
    for line in markdown.components(separatedBy: "\n") {
        if line.hasPrefix("```") {
            insideFence.toggle()
        } else if insideFence {
            blocks.append(line)
        }
    }
    return blocks.joined(separator: "\n")
}

/// Whether `invocation` appears in `examples` as a complete command token.
///
/// A plain `contains` would let one verb be covered by a longer one that merely
/// starts the same way — a future `crow set-status-bulk` example would satisfy
/// `crow set-status`. So the match must begin a token and must not be followed
/// by a character that continues the verb (letter, digit, or hyphen).
///
/// Parent groups still pass on a child's example: `crow job` is followed by a
/// space in `crow job list`. That is intended — a bare `crow job` only prints
/// help, so demanding a standalone example for it would add a line nobody would
/// ever run. A group is documented when its subcommands are.
private func mentionsCommand(_ invocation: String, in examples: String) -> Bool {
    for line in examples.components(separatedBy: "\n") {
        var searchStart = line.startIndex
        while let found = line.range(of: invocation, range: searchStart..<line.endIndex) {
            let startsToken = found.lowerBound == line.startIndex
                || " \t|(`$".contains(line[line.index(before: found.lowerBound)])
            let endsToken = found.upperBound == line.endIndex
                || !isVerbCharacter(line[found.upperBound])
            if startsToken, endsToken { return true }
            searchStart = found.upperBound
        }
    }
    return false
}

private func isVerbCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "-"
}

/// The body of one `## \`crow …\`` section of the generated reference.
private func section(_ invocation: String, in markdown: String) -> String? {
    guard let start = markdown.range(of: "## `\(invocation)`\n") else { return nil }
    let rest = markdown[start.upperBound...]
    let end = rest.range(of: "\n## `")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
}

// MARK: - The generated reference is complete

/// The ticket's core assertion: no verb and no flag is missing from the
/// generated reference.
///
/// Flags are re-derived by dumping each command type *on its own*, rather than
/// reusing the whole-tree dump the generator indexes by path. That second,
/// independent pass is the point — a generator that mis-joins a nested path
/// (`crow job add` vs `crow add`) would still look self-consistent against its
/// own index.
@Test func generatedDocCoversEveryCommandAndFlag() throws {
    let markdown = try CLIDocs.markdown()

    for command in CLIDocs.tree() where !command.isRoot {
        #expect(
            section(command.invocation, in: markdown) != nil,
            "`\(command.invocation)` has no section in the generated reference"
        )
        #expect(
            markdown.contains("[`\(command.invocation)`](#\(command.anchor))"),
            "`\(command.invocation)` is missing from the command index"
        )
    }

    var asserted = 0
    for (invocation, type) in commandTypesByInvocation() {
        guard let body = section(invocation, in: markdown) else { continue }
        for flag in try longFlagNames(of: type) {
            #expect(
                body.contains("`\(flag)`"),
                "`\(invocation)` accepts \(flag) but the generated reference omits it"
            )
            asserted += 1
        }
    }

    // Positive control. Failing closed on a decode error is not enough on its
    // own: a dump that decodes cleanly but yields no flags would make every
    // assertion above vacuous and still pass. Pin one flag-rich command exactly,
    // and floor the total, so "the independent pass looked at nothing" is itself
    // a failure. The real figure is 147 — the floor leaves room to delete verbs.
    let jobAdd = try longFlagNames(of: JobAdd.self).sorted()
    #expect(jobAdd == [
        "--daily-at", "--disabled", "--interval-seconds", "--name", "--prompt",
        "--prompt-file", "--repo", "--weekdays", "--workspace",
    ])
    #expect(asserted > 100, "only \(asserted) flags were checked — the independent dump is failing open")
}

/// Flag rendering the tables are easy to get quietly wrong: `@OptionGroup`
/// members that must be flattened in, `.customLong` names that differ from the
/// property, repeatable options, positionals, and `.prefixedNo` inversions.
@Test func generatedDocRendersAwkwardArgumentShapes() throws {
    let markdown = try CLIDocs.markdown()

    // @OptionGroup members belong to the command that includes the group.
    let install = try #require(section("crow autostart install", in: markdown))
    for flag in ["--binary", "--host", "--port", "--dev-root", "--socket", "--json"] {
        #expect(install.contains("`\(flag)`"), "crow autostart install is missing \(flag)")
    }

    // .customLong names and repeatable options.
    let jobAdd = try #require(section("crow job add", in: markdown))
    #expect(jobAdd.contains("`--interval-seconds`"))
    #expect(jobAdd.contains("`--prompt-file`"))
    #expect(jobAdd.contains("_(repeatable)_"), "crow job add's --prompt is repeatable")

    // Positional arguments have no flag name to print.
    let setStatus = try #require(section("crow set-status", in: markdown))
    #expect(setStatus.contains("_(positional)_"))
    #expect(setStatus.contains("`<status>`"))

    // .prefixedNo pairs collapse into one row carrying both spellings.
    let notifications = try #require(section("crow notifications set", in: markdown))
    #expect(notifications.contains("`--global-mute`, `--no-global-mute`"))

    // Hidden commands are documented, and labelled as hidden.
    let setPinned = try #require(section("crow set-pinned", in: markdown))
    #expect(setPinned.contains("**Hidden**"))

    // Inherited help/version flags are noted once, not repeated per command.
    #expect(!markdown.contains("| `--help` |"))
}

/// `mentionsCommand` decides whether every hand-written doc check passes, so pin
/// its boundary behaviour instead of trusting it by inspection.
@Test func mentionsCommandRequiresAWholeCommandToken() {
    // Ordinary examples, including one behind a pipe.
    #expect(mentionsCommand("crow set-status", in: "crow set-status --session <uuid> active"))
    #expect(mentionsCommand("crow resync-jira", in: "crow resync-jira"))
    #expect(mentionsCommand("crow web-password set", in: #"printf '%s' "$PW" | crow web-password set --stdin"#))

    // A longer verb must not satisfy a shorter one — the reason plain
    // `contains` was not enough.
    #expect(!mentionsCommand("crow set-status", in: "crow set-status-bulk --session <uuid>"))
    #expect(!mentionsCommand("crow job get", in: "crow job getx --id <uuid>"))

    // Nor may a match that does not start its own token.
    #expect(!mentionsCommand("crow send", in: "xcrow send hello"))

    // A parent group is satisfied by a child's example, deliberately.
    #expect(mentionsCommand("crow job", in: "crow job list"))
}

// MARK: - The committed reference is current

@Test func committedGeneratedDocIsUpToDate() throws {
    let committed = try repoFile(CLIDocs.outputPath)
    let generated = try CLIDocs.markdown()
    // Compared as a Bool so a stale file reports one line, not both copies of a
    // 1500-line document.
    let current = committed == generated
    #expect(
        current,
        "\(CLIDocs.outputPath) is stale — run `make docs` and commit the result"
    )
}

// MARK: - The hand-written docs mention every command

/// `docs/cli-reference.md` is the prose guide — written by hand, so it is the
/// one that actually drifts. Requiring the full invocation path means a new verb
/// cannot slip in behind a section that merely looks related.
@Test func handWrittenReferenceDocumentsEveryCommand() throws {
    let examples = codeBlocks(of: try repoFile("docs/cli-reference.md"))

    /// Path → why it is deliberately absent.
    let exempt = [
        "crow generate-docs": "repo maintenance, not part of the control plane",
    ]

    for invocation in invocations where exempt[invocation] == nil {
        // Bound to a Bool first: expanding the match inside the macro puts the
        // whole 1000-line document in the failure output.
        let documented = mentionsCommand(invocation, in: examples)
        #expect(
            documented,
            "`\(invocation)` has no worked example in docs/cli-reference.md — write it up, or exempt it with a reason"
        )
    }
}

/// The Manager context and its on-demand CLI reference (CROW-1443). Both are a
/// SwiftPM resource of CrowEngine, so dev builds and the app scaffold from the
/// same files — never the repo-root `CLAUDE.md`, which is repo documentation.
private let managerContextDir = "Packages/CrowEngine/Sources/CrowEngine/Resources/ManagerContext"
private let managerContextPath = "\(managerContextDir)/manager-context.md"
private let cliSkillReferencePath = "\(managerContextDir)/crow-cli/reference.md"

/// Mirrors `ManagerContext.maxBytes` in CrowEngine. This package does not link
/// CrowEngine (CI's Linux lane builds only CrowCLI), so the cap is restated.
private let managerContextMaxBytes = 12 * 1024

/// The `crow-cli` skill's reference is how an agent learns a verb the Manager
/// context does not list, so a verb missing here is a verb no agent knows it
/// can call. It is a curated cheat sheet rather than a full reference, so
/// genuinely internal verbs are exempt — each with its reason, because an
/// unexplained exemption is how drift returns.
@Test func cliSkillReferenceDocumentsEveryUserFacingVerb() throws {
    let examples = codeBlocks(of: try repoFile(cliSkillReferencePath))

    let exempt = [
        "crow setup": "first-run installer, not a control-plane verb",
        "crow hook-event": "invoked by agent hook configs, never by hand",
        "crow set-pinned": "hidden deprecated alias for set-locked",
        "crow generate-docs": "repo maintenance, not part of the control plane",
    ]

    for invocation in invocations where exempt[invocation] == nil {
        let documented = mentionsCommand(invocation, in: examples)
        #expect(
            documented,
            "`\(invocation)` is missing from the crow-cli skill's reference.md — agents read it to learn what they can run"
        )
    }
}

/// Every session under the dev root loads the Manager context on every turn
/// (Claude Code walks `CLAUDE.md` files up from the working directory), so it
/// has a hard size cap. Per-verb detail belongs in the crow-cli reference.
@Test func managerContextStaysUnderSizeCap() throws {
    let bytes = try repoFile(managerContextPath).utf8.count
    #expect(
        bytes <= managerContextMaxBytes,
        "\(managerContextPath) is \(bytes) bytes, over the \(managerContextMaxBytes)-byte cap — move per-verb detail to the crow-cli reference (CROW-1443)"
    )
}

/// The Manager context must point agents at the on-demand reference, or a
/// verb it does not list is a verb they guess at.
@Test func managerContextPointsAtTheCLISkill() throws {
    let doc = try repoFile(managerContextPath)
    #expect(doc.contains("`crow-cli` skill"), "\(managerContextPath) no longer points at the crow-cli skill")
    #expect(doc.contains(".claude/skills/crow-cli/reference.md"), "\(managerContextPath) no longer names the reference file for agents without skills")
    #expect(doc.contains("## Known Issues / Corrections"), "Scaffolder preserves the operator's corrections by splitting on this heading")
}

/// The Manager context lists the verbs most sessions need, outside the
/// reference that `cliSkillReferenceDocumentsEveryUserFacingVerb` guards. A
/// renamed or removed verb must not linger there, where every session reads it.
@Test func managerContextNamesOnlyRealVerbs() throws {
    let examples = codeBlocks(of: try repoFile(managerContextPath))
    let verb = try NSRegularExpression(pattern: #"(?<![\w/-])crow ([a-z][a-z-]*)"#)
    let range = NSRange(examples.startIndex..., in: examples)
    let named = verb.matches(in: examples, range: range).compactMap {
        Range($0.range(at: 1), in: examples).map { "crow \(examples[$0])" }
    }
    #expect(!named.isEmpty, "found no crow verbs in \(managerContextPath)'s code blocks")
    for invocation in Set(named) {
        #expect(invocations.contains(invocation), "\(managerContextPath) names `\(invocation)`, which is not a crow command")
    }
}

/// CROW-1079: an additional Manager self-renames from its first ask via
/// `crow rename-session`. The instruction lives only in the Manager's
/// scaffolded context, so if it falls out the behavior silently disappears.
@Test func managerContextExplainsSelfRename() throws {
    let doc = try repoFile(managerContextPath)
    #expect(
        doc.contains("crow rename-session --session \"$CROW_SESSION_ID\""),
        "\(managerContextPath) no longer tells additional Managers to self-rename via crow rename-session (CROW-1079)"
    )
    // The primary-Manager guard is what keeps the nav pill as "Manager".
    #expect(
        doc.contains("00000000-0000-0000-0000-000000000000"),
        "\(managerContextPath) dropped the primary-Manager guard for self-rename (CROW-1079)"
    )
}

// MARK: - Independent view of the command tree

/// Walks `CommandConfiguration` a second time, keeping the concrete types so
/// each can be dumped on its own.
private func commandTypesByInvocation() -> [(String, ParsableCommand.Type)] {
    var found: [(String, ParsableCommand.Type)] = []

    func walk(_ type: ParsableCommand.Type, path: [String]) {
        if path.count > 1 { found.append((path.joined(separator: " "), type)) }
        for subcommand in type.configuration.subcommands {
            walk(subcommand, path: path + [subcommand._commandName])
        }
    }

    walk(CrowCommand.self, path: ["crow"])
    return found
}

/// The long flag names one command accepts, read straight out of its own
/// `--experimental-dump-help` payload. `--help` / `--version` are inherited by
/// every command and documented once in the reference's preamble.
///
/// Deliberately fails closed. This is the independent check on the generator, so
/// swallowing a decode error and returning `[]` would let a `_dumpHelp()` shape
/// change silently skip every flag assertion while the test still reported
/// green.
///
/// `arguments` is therefore decoded as **required** — ArgumentParser appends a
/// help flag to every command, so the key is always present, and treating it as
/// optional would turn a renamed key into the same quiet no-op `try?` was.
/// `names` stays optional because positional arguments genuinely have none; the
/// positive control in the caller is what guards *that* key against renaming.
private func longFlagNames(of type: ParsableCommand.Type) throws -> [String] {
    struct Dump: Decodable {
        struct Command: Decodable {
            struct Argument: Decodable {
                struct Name: Decodable {
                    let kind: String
                    let name: String
                }
                /// Absent for positionals.
                let names: [Name]?
            }
            let arguments: [Argument]
        }
        let command: Command
    }

    let dump = try JSONDecoder().decode(Dump.self, from: Data(type._dumpHelp().utf8))

    var flags: [String] = []
    for argument in dump.command.arguments {
        for name in argument.names ?? [] where name.kind == "long" {
            let flag = "--" + name.name
            if flag != "--help", flag != "--version" { flags.append(flag) }
        }
    }
    return flags
}
