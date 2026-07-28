import ArgumentParser
import Foundation

/// Renders `docs/cli.md` from the `CrowCommand` tree's own ArgumentParser
/// metadata, so the reference cannot drift from the commands it describes
/// (CROW-808).
///
/// Two sources are stitched together, deliberately:
///
/// - The **command layer** (name, abstract, discussion, hidden-ness, nesting)
///   comes from `CommandConfiguration`, which has been stable public API for
///   years.
/// - The **argument layer** comes from the JSON that
///   `ParsableCommand._dumpHelp()` emits — the same payload behind
///   `--experimental-dump-help`. There is no public API for walking a command's
///   `@Option`/`@Flag` declarations, so this is the only way to get flag help
///   text without a macro or reflection hack.
///
/// The JSON is decoded into local types rather than by importing
/// `ArgumentParserToolInfo`, because that module is not a library product of
/// swift-argument-parser and therefore cannot be depended on. Every field is
/// optional and only fields present in 1.5.0 (the manifest's floor) are read —
/// `Package.resolved` is not committed, so any 1.x may be resolved and the
/// generated file has to stay byte-identical across them.
public enum CLIDocs {
    /// Where the generated reference lives, relative to the repo root.
    public static let outputPath = "docs/cli.md"

    /// How many commands the reference documents — everything but the bare `crow` root.
    public static var documentedCommandCount: Int { tree().count - 1 }

    // MARK: - Model

    /// One node of the command tree, with its full invocation path.
    struct Command {
        /// e.g. `["crow", "job", "add"]`.
        let path: [String]
        let abstract: String
        let discussion: String
        let isHidden: Bool
        let aliases: [String]
        let defaultSubcommand: String?
        let subcommandPaths: [[String]]

        /// e.g. `crow job add`.
        var invocation: String { path.joined(separator: " ") }
        /// GitHub-style heading anchor for `## \`crow job add\``.
        var anchor: String { path.joined(separator: "-") }
        var isRoot: Bool { path.count == 1 }
    }

    /// One `@Option` / `@Flag` / `@Argument` on a command.
    struct Argument {
        enum Kind: String {
            case positional, option, flag
        }

        let kind: Kind
        /// Rendered with their dashes, e.g. `["--session"]`. Empty for positionals.
        /// A merged inversion pair carries both spellings.
        var names: [String]
        let valueName: String?
        let isOptional: Bool
        let isRepeating: Bool
        let defaultValue: String?
        let abstract: String
        let allValues: [String]

        /// How the argument appears in a usage line. Positionals fall back to
        /// their value name; merged inversion pairs show both spellings.
        var displayName: String {
            names.isEmpty ? "<\(valueName ?? "value")>" : names.joined(separator: "|")
        }
    }

    // MARK: - Command tree

    /// Every command reachable from `crow`, root first, then depth-first in
    /// declaration order.
    static func tree() -> [Command] {
        var commands: [Command] = []
        walk(CrowCommand.self, path: ["crow"], into: &commands)
        return commands
    }

    private static func walk(
        _ type: ParsableCommand.Type,
        path: [String],
        into commands: inout [Command]
    ) {
        let configuration = type.configuration
        let subcommandPaths = configuration.subcommands.map { path + [$0._commandName] }

        commands.append(Command(
            path: path,
            abstract: configuration.abstract.trimmed,
            discussion: configuration.discussion.trimmed,
            isHidden: !configuration.shouldDisplay,
            aliases: configuration.aliases,
            defaultSubcommand: configuration.defaultSubcommand?._commandName,
            subcommandPaths: subcommandPaths
        ))

        for subcommand in configuration.subcommands {
            walk(subcommand, path: path + [subcommand._commandName], into: &commands)
        }
    }

    // MARK: - Arguments

    /// Arguments for every command, keyed by invocation path (`"crow job add"`).
    ///
    /// One dump of the whole tree rather than one per command: the per-command
    /// dump loses the super-command chain, and the root dump already carries
    /// every nested command.
    static func argumentsByPath() throws -> [String: [Argument]] {
        let dumped = try JSONDecoder().decode(
            DumpedTool.self, from: Data(CrowCommand._dumpHelp().utf8)
        )
        var result: [String: [Argument]] = [:]
        index(dumped.command, path: ["crow"], into: &result)
        return result
    }

    private static func index(
        _ dumped: DumpedCommand,
        path: [String],
        into result: inout [String: [Argument]]
    ) {
        let arguments = (dumped.arguments ?? []).compactMap(Argument.init)
        result[path.joined(separator: " ")] = mergingInversions(arguments)
        for subcommand in dumped.subcommands ?? [] {
            index(subcommand, path: path + [subcommand.commandName], into: &result)
        }
    }

    /// Collapse `@Flag(inversion: .prefixedNo)` pairs into one row.
    ///
    /// The dump reports `--global-mute` and `--no-global-mute` as two arguments
    /// carrying the same help text, which doubles the size of the table and the
    /// usage line for something the reader thinks of as a single toggle.
    private static func mergingInversions(_ arguments: [Argument]) -> [Argument] {
        var merged: [Argument] = []
        for argument in arguments {
            guard argument.kind == .flag,
                  argument.names.count == 1,
                  let negated = argument.names.first,
                  negated.hasPrefix("--no-"),
                  let positive = merged.lastIndex(where: {
                      $0.names == ["--" + negated.dropFirst("--no-".count)]
                          && $0.abstract == argument.abstract
                  })
            else {
                merged.append(argument)
                continue
            }
            merged[positive].names.append(negated)
        }
        return merged
    }

    // MARK: - Rendering

    /// The full contents of `docs/cli.md`.
    public static func markdown() throws -> String {
        let arguments = try argumentsByPath()
        let all = tree()
        // Keep-first rather than uniqueKeysWithValues: two commands sharing an
        // invocation path is a CLI bug, and the docs tool should report it as a
        // duplicated section rather than trap while generating.
        let byPath = Dictionary(all.map { ($0.invocation, $0) }, uniquingKeysWith: { first, _ in first })
        // Alphabetical so a reordered `subcommands:` array never rewrites the file.
        let documented = all.filter { !$0.isRoot }.sorted { $0.invocation < $1.invocation }

        var out = header(root: all[0])
        out += "\n## Command index\n\n"
        out += "| Command | Summary |\n| --- | --- |\n"
        for command in documented {
            let summary = command.abstract.isEmpty ? "—" : command.abstract
            out += "| [`\(command.invocation)`](#\(command.anchor)) | \(escapeCell(summary)) |\n"
        }
        out += "\n---\n\n"

        for command in documented {
            out += section(command, arguments: arguments[command.invocation] ?? [], byPath: byPath)
        }
        return out
    }

    private static func header(root: Command) -> String {
        """
        <!-- Generated from ArgumentParser metadata by `crow generate-docs`. Do not edit by hand. -->
        <!-- Regenerate with `make docs` after changing anything in Packages/CrowCLI/Sources/CrowCLILib/Commands/. -->

        # `crow` CLI — generated reference

        \(root.abstract).

        Every subcommand and flag the `crow` binary accepts, generated from the commands themselves \
        so it cannot drift. For prose, worked examples, JSON response shapes and the gotchas that \
        matter in practice, read [`cli-reference.md`](cli-reference.md) instead — this file is the \
        exhaustive surface, that one is the guide.

        `--help` is accepted everywhere and `crow --version` prints the build version; neither is \
        repeated per command below. Commands marked **hidden** are omitted from `crow --help` but \
        still work.

        ---

        """
    }

    private static func section(
        _ command: Command,
        arguments: [Argument],
        byPath: [String: Command]
    ) -> String {
        var out = "## `\(command.invocation)`\n\n"

        if !command.abstract.isEmpty {
            out += "\(command.abstract).\n\n"
        }
        if command.isHidden {
            out += "**Hidden** — not listed in `crow --help`.\n\n"
        }
        if !command.aliases.isEmpty {
            out += "Aliases: \(command.aliases.map { "`\($0)`" }.joined(separator: ", ")).\n\n"
        }

        out += "```\n\(usage(command, arguments: arguments))\n```\n\n"

        if !command.discussion.isEmpty {
            out += "\(renderDiscussion(command.discussion))\n\n"
        }

        if !command.subcommandPaths.isEmpty {
            let links = command.subcommandPaths.compactMap { path -> String? in
                guard let sub = byPath[path.joined(separator: " ")] else { return nil }
                return "[`\(sub.path.last ?? "")`](#\(sub.anchor))"
            }
            out += "Subcommands: \(links.joined(separator: ", ")).\n\n"
            if let fallback = command.defaultSubcommand {
                out += "Bare `\(command.invocation)` runs `\(fallback)`.\n\n"
            }
        }

        if !arguments.isEmpty {
            out += "| Flag | Value | Required | Description |\n| --- | --- | --- | --- |\n"
            for argument in arguments {
                out += row(argument)
            }
            out += "\n"
        }

        return out + "---\n\n"
    }

    private static func row(_ argument: Argument) -> String {
        let name = argument.kind == .positional
            ? "_(positional)_"
            : argument.names.map { "`\($0)`" }.joined(separator: ", ")

        var value = argument.valueName.map { "`<\($0)>`" } ?? "—"
        if argument.kind == .flag { value = "—" }
        if argument.isRepeating { value += " _(repeatable)_" }

        // Help strings rarely end in a period, so terminate before appending.
        var description = argument.abstract.isEmpty ? "—" : argument.abstract
        if !argument.allValues.isEmpty {
            description = description.sentenceTerminated
                + " Values: \(argument.allValues.map { "`\($0)`" }.joined(separator: ", "))."
        }
        if let fallback = argument.defaultValue, !fallback.isEmpty {
            description = description.sentenceTerminated + " Default: `\(fallback)`."
        }

        return "| \(escapeCell(name)) | \(escapeCell(value)) | \(argument.isOptional ? "no" : "yes") "
            + "| \(escapeCell(description)) |\n"
    }

    /// A synthesised usage line — optional parts bracketed, repeatables suffixed.
    private static func usage(_ command: Command, arguments: [Argument]) -> String {
        var parts = [command.invocation]
        if !command.subcommandPaths.isEmpty {
            let names = command.subcommandPaths.compactMap(\.last).joined(separator: "|")
            parts.append(command.defaultSubcommand == nil ? "<\(names)>" : "[\(names)]")
        }
        for argument in arguments {
            var part: String
            switch argument.kind {
            case .flag:
                part = argument.displayName
            case .option:
                part = "\(argument.displayName) <\(argument.valueName ?? "value")>"
            case .positional:
                part = "<\(argument.valueName ?? "value")>"
            }
            if argument.isRepeating { part += " ..." }
            parts.append(argument.isOptional ? "[\(part)]" : part)
        }
        return parts.joined(separator: " ")
    }

    /// A `discussion:` is plain text written for a terminal, where an indented
    /// line means "this is a command to type". Markdown needs that spelled out,
    /// so indented runs become fenced blocks; everything else passes through.
    private static func renderDiscussion(_ discussion: String) -> String {
        var out: [String] = []
        var fenced = false
        for line in discussion.components(separatedBy: "\n") {
            let indented = line.hasPrefix("  ") && !line.trimmed.isEmpty
            if indented != fenced {
                out.append("```")
                fenced = indented
            }
            out.append(fenced ? line.trimmed : line)
        }
        if fenced { out.append("```") }
        return out.joined(separator: "\n")
    }

    /// `|` terminates a Markdown table cell, so it has to be escaped — several
    /// help strings enumerate choices as `active|paused|…`.
    private static func escapeCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - `_dumpHelp()` JSON

/// Mirrors `ToolInfoV0` closely enough to read, and no further. Every field is
/// optional so a newer swift-argument-parser adding or dropping keys degrades
/// instead of throwing.
private struct DumpedTool: Decodable {
    let command: DumpedCommand
}

private struct DumpedCommand: Decodable {
    let commandName: String
    let subcommands: [DumpedCommand]?
    let arguments: [DumpedArgument]?
}

private struct DumpedArgument: Decodable {
    struct Name: Decodable {
        let kind: String
        let name: String

        /// `long` → `--flag`, `short` → `-f`, `longWithSingleDash` → `-flag`.
        var rendered: String {
            switch kind {
            case "long": return "--\(name)"
            case "longWithSingleDash": return "-\(name)"
            default: return "-\(name)"
            }
        }
    }

    let kind: String
    let isOptional: Bool?
    let isRepeating: Bool?
    let names: [Name]?
    let valueName: String?
    let defaultValue: String?
    let abstract: String?
    /// The stored key in 1.5.0; later versions also expose `allValueStrings`.
    let allValues: [String]?
    let allValueStrings: [String]?
}

extension CLIDocs.Argument {
    /// `nil` for `--help` / `--version`, which every command inherits and no
    /// per-command table should repeat.
    fileprivate init?(_ dumped: DumpedArgument) {
        guard let kind = Kind(rawValue: dumped.kind) else { return nil }
        let names = (dumped.names ?? []).map(\.rendered)
        guard !names.contains("--help"), !names.contains("--version") else { return nil }

        self.kind = kind
        self.names = names
        self.valueName = dumped.valueName?.nonBlank
        self.isOptional = dumped.isOptional ?? true
        self.isRepeating = dumped.isRepeating ?? false
        self.defaultValue = dumped.defaultValue?.nonBlank
        self.abstract = (dumped.abstract ?? "").trimmed
        self.allValues = dumped.allValues ?? dumped.allValueStrings ?? []
    }
}

// MARK: - Small helpers

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    fileprivate var nonBlank: String? { trimmed.isEmpty ? nil : self }

    /// The string with a trailing `.` added unless it already closes a sentence.
    fileprivate var sentenceTerminated: String {
        guard let last, !".!?:".contains(last) else { return self }
        return self + "."
    }
}
