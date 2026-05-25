import ArgumentParser

/// Root command for the Crow CLI.
///
/// All subcommands are registered here. The `@main` entry point in the
/// executable target calls `Crow.main()` to start argument parsing.
public struct CrowCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "crow",
        abstract: "CLI for Crow — manage sessions, terminals, and metadata",
        version: CLIVersion.version,
        subcommands: [
            Setup.self,
            NewSession.self,
            RenameSession.self,
            SelectSession.self,
            ListSessions.self,
            GetSession.self,
            SetStatus.self,
            DeleteSession.self,
            SetTicket.self,
            AddWorktree.self,
            ListWorktrees.self,
            NewTerminal.self,
            ListTerminals.self,
            CloseTerminal.self,
            RenameTerminal.self,
            Send.self,
            AddLink.self,
            ListLinks.self,
            HookEventCmd.self,
        ]
    )

    public init() {}
}
