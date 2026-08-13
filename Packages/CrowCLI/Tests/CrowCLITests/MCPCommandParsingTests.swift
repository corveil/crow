import ArgumentParser
import CrowCore
import CrowIPC
import Foundation
import Testing

@testable import CrowCLILib

/// Argument handling for `crow mcp` (CROW-1004). No daemon required — these
/// exercise `parseAsRoot` + `validate()` only.
@Suite("crow mcp command parsing")
struct MCPCommandParsingTests {

    private func parse(_ arguments: [String]) throws -> ParsableCommand {
        try CrowCommand.parseAsRoot(arguments)
    }

    /// `parseAsRoot` runs `validate()` as part of parsing, so a rejected argument
    /// surfaces here rather than on a later explicit call. Asserting on the parse is
    /// therefore what actually pins the user-visible behaviour.
    private func expectRejected(_ arguments: [String], _ comment: Comment? = nil) {
        #expect(throws: (any Error).self, comment) { _ = try self.parse(arguments) }
    }

    // MARK: - Registration

    @Test("The mcp verb group is registered with its subcommands")
    func registered() throws {
        #expect(CrowCommand.configuration.subcommands.contains { $0 == MCP.self })
        let names = MCP.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("serve"))
        #expect(names.contains("token"))
        let tokenNames = MCPToken.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(tokenNames) == ["list", "mint", "revoke"])
    }

    // MARK: - serve

    @Test("serve takes no arguments by default")
    func serveDefaults() throws {
        let command = try parse(["mcp", "serve"])
        let serve = try #require(command as? MCPServe)
        #expect(serve.scope.isEmpty)
    }

    @Test("serve accepts repeated known scopes")
    func serveScopes() throws {
        let command = try parse(["mcp", "serve", "--scope", "board:read", "--scope", "sessions:read"])
        let serve = try #require(command as? MCPServe)
        #expect(serve.scope == ["board:read", "sessions:read"])
    }

    @Test("serve rejects an unknown scope")
    func serveRejectsUnknownScope() {
        expectRejected(["mcp", "serve", "--scope", "sessions:write"])
    }

    // MARK: - token mint

    @Test("mint requires a name and at least one scope")
    func mintRequiresNameAndScope() {
        // A token granting nothing authenticates fine and then shows an empty tool
        // list, which reads as a broken server rather than a misconfigured token.
        expectRejected(["mcp", "token", "mint", "--name", "bot"], "no --scope")
        expectRejected(["mcp", "token", "mint", "--scope", "board:read"], "no --name")
    }

    @Test("mint accepts a well-formed invocation")
    func mintHappyPath() throws {
        let mint = try #require(
            try parse(["mcp", "token", "mint", "--name", "grok-bot", "--scope", "board:read"])
                as? MCPTokenMint)
        #expect(mint.name == "grok-bot")
        #expect(mint.scope == ["board:read"])
        #expect(mint.expiresIn == nil)
        #expect(!mint.noExpiry)
    }

    @Test("mint rejects an unknown scope by name")
    func mintRejectsUnknownScope() {
        expectRejected(["mcp", "token", "mint", "--name", "b", "--scope", "admin"])
    }

    @Test("mint rejects a blank or control-character name")
    func mintRejectsBadNames() {
        for name in ["", "   ", "bad\u{0007}name"] {
            expectRejected(["mcp", "token", "mint", "--name", name, "--scope", "board:read"])
        }
    }

    @Test("--expires-in accepts a unit-suffixed duration")
    func mintExpiresIn() throws {
        let mint = try #require(
            try parse([
                "mcp", "token", "mint", "--name", "b", "--scope", "board:read",
                "--expires-in", "30d",
            ]) as? MCPTokenMint)
        #expect(mint.expiresIn == "30d")
    }

    @Test("--expires-in rejects a bare number")
    func mintRejectsBareNumber() {
        // "90" is ambiguous between seconds and days — seven orders of magnitude of
        // difference in what a leaked token buys.
        expectRejected([
            "mcp", "token", "mint", "--name", "b", "--scope", "board:read", "--expires-in", "90",
        ])
    }

    @Test("--no-expiry and --expires-in are mutually exclusive")
    func mintExclusiveExpiryFlags() {
        expectRejected([
            "mcp", "token", "mint", "--name", "b", "--scope", "board:read",
            "--expires-in", "30d", "--no-expiry",
        ])
    }

    @Test("--no-expiry alone is accepted")
    func mintNoExpiry() throws {
        let mint = try #require(
            try parse([
                "mcp", "token", "mint", "--name", "cowork", "--scope", "board:read", "--no-expiry",
            ]) as? MCPTokenMint)
        #expect(mint.noExpiry)
    }

    // MARK: - token revoke

    @Test("revoke takes exactly one of --id or --name")
    func revokeSelector() throws {
        expectRejected(["mcp", "token", "revoke"], "neither selector")
        expectRejected(
            ["mcp", "token", "revoke", "--id", UUID().uuidString, "--name", "bot"], "both selectors")

        _ = try #require(try parse(["mcp", "token", "revoke", "--name", "bot"]) as? MCPTokenRevoke)
        _ = try #require(
            try parse(["mcp", "token", "revoke", "--id", UUID().uuidString]) as? MCPTokenRevoke)
    }

    @Test("revoke rejects a non-UUID id")
    func revokeRejectsNonUUID() {
        expectRejected(["mcp", "token", "revoke", "--id", "grok-bot"])
    }

    @Test("token list takes no arguments")
    func listParses() throws {
        _ = try #require(try parse(["mcp", "token", "list"]) as? MCPTokenList)
    }
}
