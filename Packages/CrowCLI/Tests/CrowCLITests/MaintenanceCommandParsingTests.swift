import ArgumentParser
import Testing

@testable import CrowCLILib

// Arg parsing for the tmux/daemon-maintenance verbs (CROW-818). No socket is
// touched: `validate()` runs during `parse()`, so the whole validation surface
// is reachable from here.

private let sampleUUID = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

// MARK: - no-param verbs

@Test func noParamMaintenanceVerbsParseFromBareArgv() throws {
    _ = try RestartManager.parse([])
    _ = try RestartTmuxServer.parse([])
    _ = try ReloadTmuxConfig.parse([])
}

@Test func noParamMaintenanceVerbsRejectStrayArguments() {
    #expect(throws: (any Error).self) { _ = try RestartManager.parse(["--session", sampleUUID]) }
    #expect(throws: (any Error).self) { _ = try RestartTmuxServer.parse(["--yes"]) }
    #expect(throws: (any Error).self) { _ = try ReloadTmuxConfig.parse(["extra"]) }
}

// MARK: - terminal-scoped verbs

@Test func terminalScopedVerbsParseTerminalOption() throws {
    #expect(try LaunchAgent.parse(["--terminal", sampleUUID]).terminal == sampleUUID)
    #expect(try RetryReadiness.parse(["--terminal", sampleUUID]).terminal == sampleUUID)
}

@Test func terminalScopedVerbsRequireTerminal() {
    #expect(throws: (any Error).self) { _ = try LaunchAgent.parse([]) }
    #expect(throws: (any Error).self) { _ = try RetryReadiness.parse([]) }
}

@Test func terminalScopedVerbsRejectInvalidUUID() {
    #expect(throws: (any Error).self) { _ = try LaunchAgent.parse(["--terminal", "nope"]) }
    #expect(throws: (any Error).self) { _ = try RetryReadiness.parse(["--terminal", "nope"]) }
}

@Test func terminalScopedVerbsRejectSessionFlag() {
    // These map 1:1 to RPCs that take only `terminal_id` — unlike every other
    // terminal verb, there is no `--session`. The mismatch must fail loudly at
    // parse time rather than being silently ignored.
    #expect(throws: (any Error).self) {
        _ = try LaunchAgent.parse(["--session", sampleUUID, "--terminal", sampleUUID])
    }
    #expect(throws: (any Error).self) {
        _ = try RetryReadiness.parse(["--session", sampleUUID, "--terminal", sampleUUID])
    }
}

// MARK: - session-scoped host-app verbs

@Test func hostAppVerbsParseSessionOption() throws {
    #expect(try OpenInVSCode.parse(["--session", sampleUUID]).session == sampleUUID)
    #expect(try OpenTerminal.parse(["--session", sampleUUID]).session == sampleUUID)
}

@Test func hostAppVerbsRequireSession() {
    #expect(throws: (any Error).self) { _ = try OpenInVSCode.parse([]) }
    #expect(throws: (any Error).self) { _ = try OpenTerminal.parse([]) }
}

@Test func hostAppVerbsRejectInvalidUUID() {
    #expect(throws: (any Error).self) { _ = try OpenInVSCode.parse(["--session", "not-a-uuid"]) }
    #expect(throws: (any Error).self) { _ = try OpenTerminal.parse(["--session", "not-a-uuid"]) }
}

// MARK: - root registration

@Test func maintenanceVerbsResolveFromRoot() throws {
    // Also proves none of the new names collide with an existing subcommand —
    // notably `open-terminal` vs the pre-existing `new-terminal`/`close-terminal`.
    #expect(try CrowCommand.parseAsRoot(["restart-manager"]) is RestartManager)
    #expect(try CrowCommand.parseAsRoot(["restart-tmux-server"]) is RestartTmuxServer)
    #expect(try CrowCommand.parseAsRoot(["reload-tmux-config"]) is ReloadTmuxConfig)
    #expect(try CrowCommand.parseAsRoot(["launch-agent", "--terminal", sampleUUID]) is LaunchAgent)
    #expect(try CrowCommand.parseAsRoot(["retry-readiness", "--terminal", sampleUUID]) is RetryReadiness)
    #expect(try CrowCommand.parseAsRoot(["open-in-vscode", "--session", sampleUUID]) is OpenInVSCode)
    #expect(try CrowCommand.parseAsRoot(["open-terminal", "--session", sampleUUID]) is OpenTerminal)
}

@Test func openTerminalAndNewTerminalStayDistinct() throws {
    // One word apart, completely unrelated effects: host GUI Terminal.app vs a
    // tmux tab inside Crow. Subcommand matching is exact, so this must hold.
    #expect(try CrowCommand.parseAsRoot(["open-terminal", "--session", sampleUUID]) is OpenTerminal)
    #expect(try CrowCommand.parseAsRoot(["new-terminal", "--session", sampleUUID, "--cwd", "/tmp"]) is NewTerminal)
}
