import ArgumentParser
import CrowCore
import CrowIPC
import Foundation

/// The `crow mcp` verb family (CROW-1004).
///
/// Two unrelated jobs under one noun, because both are "MCP" to the person typing:
///
/// - `crow mcp serve` is the **local transport**. It bridges stdin/stdout to the
///   daemon's 0600 Unix socket, so a local client (Cowork, Claude Desktop) speaks
///   MCP without a token — machine locality is the trust boundary, exactly as it is
///   for every other `crow` verb (ADR 0002).
/// - `crow mcp token …` manages the **remote** credential: bearer tokens for
///   `POST /mcp`, which an off-box client (a Grok bot) must present. Those RPCs are
///   local-only on `/rpc` (``RPCWebSocketHandler.localOnlyDenial``), so this CLI is
///   the only way to mint one — the browser reaches the same surface through
///   `SecretRoutes`.
public struct MCP: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve Crow over MCP, and manage the tokens remote clients use",
        subcommands: [MCPServe.self, MCPToken.self]
    )

    public init() {}
}

// MARK: - serve

/// `crow mcp serve` — the stdio transport.
public struct MCPServe: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Serve the read-only MCP surface over stdio (for a local client)",
        discussion: """
        Speaks MCP on stdin/stdout and forwards each tool call to the running \
        `crowd` over its Unix socket. Point a local MCP client at it:

          {"mcpServers": {"crow": {"command": "crow", "args": ["mcp", "serve"]}}}

        No token is needed. The socket is 0600 and reachable only from this \
        machine, so a caller that can run this command could already run every \
        other `crow` verb — a token would gate nothing. Remote clients use \
        `POST /mcp` with a token from `crow mcp token mint` instead.

        The surface is read-only either way, and identical: six tools over five \
        read RPCs. This command cannot send prompts, create sessions, or write \
        anything.

        Unlike every other `crow` verb, stdout here carries framed JSON-RPC rather \
        than one JSON object — it is a transport, not a query. Diagnostics go to \
        stderr.
        """
    )

    @Option(
        name: .long,
        help: """
        Limit the served tools to these scopes (repeatable). Defaults to all \
        read scopes: \(MCPScope.allCases.map(\.rawValue).sorted().joined(separator: ", ")).
        """)
    public var scope: [String] = []

    public init() {}

    public func validate() throws {
        guard !scope.isEmpty else { return }
        if case .failure(let error) = MCPTokenWire.parseScopes(scope) {
            throw ValidationError(error.message)
        }
    }

    public func run() throws {
        let scopes: Set<MCPScope>
        if scope.isEmpty {
            scopes = MCPScope.all
        } else {
            // `validate()` already rejected anything unknown.
            scopes = Set((try? MCPTokenWire.parseScopes(scope).get()) ?? [])
        }
        let server = MCPServer(serverVersion: CLIVersion.version)

        // One JSON object per line, both directions. `readLine` is line-buffered on
        // the client side by every MCP stdio implementation, and a JSON object never
        // contains a bare newline once encoded, so line framing is unambiguous.
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let outcome = runBlocking {
                await server.handle(Data(trimmed.utf8), scopes: scopes) { method, params in
                    // The daemon call is synchronous (a Unix-socket round trip), so
                    // it is hopped off the cooperative pool. Requests are handled
                    // one at a time here by design: an MCP stdio client sends the
                    // next request after the previous reply, and serializing keeps
                    // the socket usage trivially correct.
                    try rpc(method, params: params)
                }
            }
            // A notification produces no bytes; anything else is one line out.
            guard let data = outcome.responseData,
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            print(text)
            fflush(stdout)
        }
    }

    /// Bridge from this synchronous `run()` to the async server core.
    ///
    /// `ParsableCommand.run()` is synchronous and the MCP core is `async`, so each
    /// message is run to completion on a semaphore. That is the right shape here
    /// rather than a wart: stdio MCP is strictly request/response, one at a time.
    private func runBlocking(_ work: @escaping @Sendable () async -> MCPOutcome) -> MCPOutcome {
        let semaphore = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        Task {
            box.value = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? .accepted
    }

    private final class OutcomeBox: @unchecked Sendable {
        var value: MCPOutcome?
    }
}

// MARK: - token

public struct MCPToken: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Mint, list and revoke MCP bearer tokens (local-only)",
        subcommands: [MCPTokenList.self, MCPTokenMint.self, MCPTokenRevoke.self]
    )

    public init() {}
}

public struct MCPTokenList: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List MCP bearer tokens (never the tokens themselves)"
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("mcp-token-list"))
    }
}

public struct MCPTokenMint: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mint",
        abstract: "Mint a scoped MCP bearer token",
        discussion: """
        Prints the token once. It is stored only as a SHA-256 hash, so it cannot \
        be recovered — losing it means minting another and revoking this one.

          crow mcp token mint --name grok-bot --scope board:read

        Expiry defaults to 90 days. Pass --expires-in to choose another, or \
        --no-expiry for a token that never expires — which has to be typed, \
        because an off-box credential that never lapses is a decision, not a \
        default.
        """
    )

    @Option(name: .long, help: "A label for this token, e.g. \"grok-bot\"")
    public var name: String

    @Option(
        name: .long,
        help: """
        Capability to grant (repeatable). One of: \
        \(MCPScope.allCases.map(\.rawValue).sorted().joined(separator: ", ")).
        """)
    public var scope: [String] = []

    @Option(name: .long, help: "Lifetime — \(MCPTokenWire.durationHelp). Defaults to 90d.")
    public var expiresIn: String?

    @Flag(name: .long, help: "Mint a token that never expires (mutually exclusive with --expires-in)")
    public var noExpiry: Bool = false

    public init() {}

    public func validate() throws {
        if let problem = MCPTokenWire.validate(name: name) {
            throw ValidationError(problem)
        }
        if case .failure(let error) = MCPTokenWire.parseScopes(scope) {
            throw ValidationError(error.message)
        }
        if noExpiry, expiresIn != nil {
            throw ValidationError("--no-expiry and --expires-in are mutually exclusive")
        }
        if let expiresIn, MCPTokenWire.parseDuration(expiresIn) == nil {
            throw ValidationError(
                "--expires-in must be \(MCPTokenWire.durationHelp) — got '\(expiresIn)'")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "scopes": .array(scope.map { .string($0.trimmingCharacters(in: .whitespaces)) }),
        ]
        if noExpiry {
            params["no_expiry"] = .bool(true)
        } else if let expiresIn, let seconds = MCPTokenWire.parseDuration(expiresIn) {
            params["expires_in_seconds"] = .int(seconds)
        }
        printJSON(try rpc("mcp-token-mint", params: params))
    }
}

public struct MCPTokenRevoke: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Revoke an MCP bearer token",
        discussion: """
        Revoke by --id (from `crow mcp token list`), or by --name when only one \
        token carries that name. An ambiguous name is refused rather than guessed.
        """
    )

    @Option(name: .long, help: "Token UUID, from `crow mcp token list`")
    public var id: String?

    @Option(name: .long, help: "Token name, when it is unambiguous")
    public var name: String?

    public init() {}

    public func validate() throws {
        let hasID = !(id?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        let hasName = !(name?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        guard hasID != hasName else {
            throw ValidationError("exactly one of --id or --name is required")
        }
        if let id, hasID, UUID(uuidString: id.trimmingCharacters(in: .whitespaces)) == nil {
            throw ValidationError("--id must be a UUID (from `crow mcp token list`)")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let id, !id.trimmingCharacters(in: .whitespaces).isEmpty {
            params["id"] = .string(id.trimmingCharacters(in: .whitespaces))
        }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            params["name"] = .string(name.trimmingCharacters(in: .whitespaces))
        }
        printJSON(try rpc("mcp-token-revoke", params: params))
    }
}
