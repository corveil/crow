import ArgumentParser
import Testing
import CrowCore
@testable import CrowCLILib

// MARK: - `crow agents` command parsing (CROW-811)

@Test func agentsGroupRoutesToSubcommands() throws {
    let list = try Agents.parseAsRoot(["list"])
    #expect(list is AgentsList)
    let set = try Agents.parseAsRoot(["set", "--default", "codex"])
    #expect(set is AgentsSet)
}

/// A command that compiles and tests green is still unreachable until it is
/// registered on the root command.
@Test func rootCommandRegistersAgentsGroup() {
    let names = CrowCommand.configuration.subcommands.map { $0.configuration.commandName }
    #expect(names.contains("agents"))
}

// MARK: - list

@Test func agentsListParsesWithoutFlags() throws {
    _ = try AgentsList.parse([])
}

@Test func agentsListTakesNoFlags() {
    #expect(throws: (any Error).self) { _ = try AgentsList.parse(["--default", "codex"]) }
}

// MARK: - set: flags

/// Pins the `.customLong("default")` workaround — `default` is a Swift keyword, so
/// the property can't carry the flag name and a rename would silently change the
/// CLI surface.
@Test func agentsSetDefaultFlagIsSpelledDefault() throws {
    let cmd = try AgentsSet.parse(["--default", "codex"])
    #expect(cmd.defaultAgent == "codex")
    try cmd.validate()
}

@Test func agentsSetParsesEveryRoleFlag() throws {
    let cmd = try AgentsSet.parse([
        "--work", "codex", "--review", "cursor", "--job", "opencode", "--manager", "claude-code",
    ])
    #expect(cmd.work == "codex")
    #expect(cmd.review == "cursor")
    #expect(cmd.job == "opencode")
    #expect(cmd.manager == "claude-code")
    try cmd.validate()
}

/// An omitted role stays nil so the handler leaves the stored value alone — the
/// reason these are optionals rather than defaulted strings.
@Test func agentsSetLeavesOmittedRolesNil() throws {
    let cmd = try AgentsSet.parse(["--review", "codex"])
    #expect(cmd.review == "codex")
    #expect(cmd.work == nil)
    #expect(cmd.job == nil)
    #expect(cmd.manager == nil)
    #expect(cmd.defaultAgent == nil)
    #expect(cmd.clear.isEmpty)
    try cmd.validate()
}

@Test func agentsSetParsesRepeatableClear() throws {
    let cmd = try AgentsSet.parse(["--clear", "work", "--clear", "job"])
    #expect(cmd.clear == [.work, .job])
    try cmd.validate()
}

/// `--clear` parses into the model enum, so every role is accepted and the CLI
/// never carries its own copy of the role list.
@Test func agentsSetAcceptsEveryRoleForClear() throws {
    for role in SessionKind.allCases {
        let cmd = try AgentsSet.parse(["--clear", role.rawValue])
        #expect(cmd.clear == [role])
        try cmd.validate()
    }
}

@Test func agentsSetRejectsAnUnknownClearRole() {
    #expect(throws: (any Error).self) { _ = try AgentsSet.parse(["--clear", "deploy"]) }
}

/// Repeats collapse and the list is emitted in declaration order — the server is
/// idempotent either way, but a duplicated echo in an error message reads like a bug.
@Test func agentsSetDedupesAndOrdersClearOnTheWire() throws {
    let cmd = try AgentsSet.parse([
        "--clear", "job", "--clear", "work", "--clear", "job",
    ])
    try cmd.validate()
    #expect(cmd.sentParams()["clear"] == .array([.string("work"), .string("job")]))
}

// MARK: - set: rejections

@Test func agentsSetRejectsNoFlags() {
    #expect(setParseError([]).contains("Nothing to set"))
}

/// The conflict check has to run before the generic "nothing to set" guard —
/// otherwise this call satisfies emptiness and the message never mentions --clear.
@Test func agentsSetRejectsClearAndSetOfTheSameRole() {
    let message = setParseError(["--review", "codex", "--clear", "review"])
    #expect(message.contains("review"))
    #expect(message.contains("--clear"))
}

@Test func agentsSetAllowsClearAndSetOfDifferentRoles() throws {
    let cmd = try AgentsSet.parse(["--work", "codex", "--clear", "review"])
    try cmd.validate()
}

@Test func agentsSetRejectsABlankKind() {
    #expect(setParseError(["--work", "   "]).contains("--work"))
    #expect(setParseError(["--default", ""]).contains("--default"))
}

/// A shell-quoting slip shouldn't come back as "'codex ' is not an available
/// agent" — an error pointing at availability when the problem is a stray space
/// (#886 review). Trimming happens before both the blank check and the send, so
/// validation and the wire payload can't disagree.
@Test func agentsSetTrimsSurroundingWhitespaceFromKinds() throws {
    let cmd = try AgentsSet.parse([
        "--default", " codex ", "--work", "codex\t", "--review", "  cursor",
    ])
    try cmd.validate()
    #expect(cmd.sentParams()["default_agent_kind"] == .string("codex"))
    #expect(cmd.sentParams()["by_kind"] == .object([
        "work": .string("codex"), "review": .string("cursor"),
    ]))
}

/// The registry gate is server-side by design: the valid set is whatever crowd
/// registered at boot, and `AgentKind` is an open struct with no case list to
/// check against. So an arbitrary kind parses locally and is rejected by the
/// daemon, not here.
@Test func agentsSetAcceptsAnArbitraryKindStringLocally() throws {
    let cmd = try AgentsSet.parse(["--work", "totally-made-up"])
    try cmd.validate()
}

/// The message a user actually sees on stderr, for asserting we point at the right
/// flag rather than merely throwing something. `parse` runs `validate`, so the
/// rejection surfaces here.
private func setParseError(_ args: [String]) -> String {
    do {
        _ = try AgentsSet.parse(args)
        return ""
    } catch {
        return String(describing: error)
    }
}
