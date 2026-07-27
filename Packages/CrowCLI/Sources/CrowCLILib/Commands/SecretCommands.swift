import ArgumentParser
import CrowIPC
import Foundation

// Local-only secret surfaces: the AI gateways and the web-access password
// (CROW-815). These reach the daemon over the Unix socket, which is local by
// construction; the same RPC methods are refused on the remote `/rpc` WebSocket
// by `RPCWebSocketHandler.localOnlyDenial`. The web Settings UI drives the
// equivalent HTTP routes in `SecretRoutes`.

/// Which gateway a `crow gateway` subcommand addresses: the Manager's, or one
/// workspace's. Shared by get/set/clear so the selector behaves identically.
public struct GatewayTargetOptions: ParsableArguments {
    @Flag(name: .long, help: "Target the Manager AI gateway")
    public var manager: Bool = false

    @Option(name: .long, help: "Target a workspace's AI gateway (workspace name or UUID)")
    public var workspace: String?

    public init() {}

    /// Called explicitly from each subcommand's `validate()` rather than relying
    /// on option-group validation, so the check runs at a predictable point.
    public func validateTarget() throws {
        switch (manager, workspace) {
        case (true, .some):
            throw ValidationError("--manager and --workspace are mutually exclusive.")
        case (false, nil):
            throw ValidationError("Exactly one of --manager or --workspace is required.")
        case (false, .some(let workspace)):
            guard !workspace.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ValidationError("--workspace must not be blank.")
            }
        case (true, nil):
            break
        }
    }

    /// The target selector as RPC params.
    public var params: [String: JSONValue] {
        if let workspace { return ["workspace": .string(workspace)] }
        return ["target": .string("manager")]
    }
}

/// Parent command for AI gateway management: `crow gateway <subcommand>`.
///
/// A gateway is a base URL plus the auth headers sent with it; agents launched
/// into the workspace (or the Manager) inherit them as `ANTHROPIC_BASE_URL` /
/// `ANTHROPIC_CUSTOM_HEADERS`. Header values may be `op://…` 1Password
/// references, resolved at launch so the secret never rests in `config.json`.
///
/// Local-only: these run over the Unix socket and are refused for remote web
/// clients, because the headers are credentials.
public struct Gateway: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gateway",
        abstract: "Manage AI gateways (local-only)",
        subcommands: [GatewayGet.self, GatewaySet.self, GatewayClear.self]
    )

    public init() {}
}

public struct GatewayGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show a gateway's base URL and header names",
        discussion: """
        Header values are blanked by default so the output is safe to share. \
        Pass --reveal to print the stored values (which may be op:// references \
        rather than the secrets themselves).
        """
    )

    @OptionGroup public var target: GatewayTargetOptions

    @Flag(name: .long, help: "Print header values instead of blanking them")
    public var reveal: Bool = false

    public init() {}

    public func validate() throws {
        try target.validateTarget()
    }

    public func run() throws {
        var params = target.params
        params["reveal"] = .bool(reveal)
        printJSON(try rpc("gateway-get", params: params))
    }
}

public struct GatewaySet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a gateway's base URL and headers",
        discussion: """
        Replaces the whole gateway: --base-url and at least one --header are \
        both required (a gateway needs both, or neither). A --header with a \
        blank value keeps the secret already stored under that name, so the base \
        URL can be changed without restating credentials:

          crow gateway set --manager --base-url https://gw.example.com --header "X-Api-Key:"

        Header values may be op:// 1Password references, resolved at agent \
        launch so the secret never rests in config.json.
        """
    )

    @OptionGroup public var target: GatewayTargetOptions

    @Option(name: .customLong("base-url"), help: "Gateway base URL")
    public var baseURL: String

    @Option(name: .long, parsing: .singleValue, help: "Header as 'Name: Value' (repeatable)")
    public var header: [String] = []

    public init() {}

    public func validate() throws {
        try target.validateTarget()
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("--base-url must not be blank. Use `crow gateway clear` to remove a gateway.")
        }
        guard !header.isEmpty else {
            throw ValidationError("At least one --header is required (a gateway needs both a base URL and a header).")
        }
        try header.forEach(validateHeaderLine)
    }

    public func run() throws {
        var params = target.params
        params["base_url"] = .string(baseURL)
        params["header_lines"] = .array(header.map { .string($0) })
        printJSON(try rpc("gateway-set", params: params))
    }
}

public struct GatewayClear: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Remove a gateway"
    )

    @OptionGroup public var target: GatewayTargetOptions

    public init() {}

    public func validate() throws {
        try target.validateTarget()
    }

    public func run() throws {
        var params = target.params
        params["clear"] = .bool(true)
        printJSON(try rpc("gateway-set", params: params))
    }
}

/// Parent command for the web-access password: `crow web-password <subcommand>`.
///
/// The password gates the daemon's web UI for non-loopback clients. It is stored
/// as a PBKDF2-HMAC-SHA256 hash; the plaintext is never persisted and never
/// travels over anything but the local Unix socket.
public struct WebPassword: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "web-password",
        abstract: "Manage the web-access password (local-only)",
        subcommands: [WebPasswordStatus.self, WebPasswordSet.self, WebPasswordClear.self]
    )

    public init() {}
}

public struct WebPasswordStatus: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether a web-access password is set"
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("web-password-get"))
    }
}

public struct WebPasswordSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set or change the web-access password",
        discussion: """
        Prompts twice with echo off. For scripts, pipe the password and pass \
        --stdin:

          printf '%s' "$PW" | crow web-password set --stdin

        There is no --password flag on purpose — a plaintext password in argv is \
        visible in shell history and to local `ps`. Changing the password does \
        not require the old one; the local-only gate is the control.
        """
    )

    @Flag(name: .long, help: "Read the password from stdin instead of prompting")
    public var stdin: Bool = false

    public init() {}

    public func run() throws {
        let password = try SecretArgs.readPassword(useStdin: stdin)
        printJSON(try rpc("web-password-set", params: ["password": .string(password)]))
    }
}

public struct WebPasswordClear: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Remove the web-access password",
        discussion: """
        With no password set, remote web clients are no longer challenged — \
        check how the daemon is bound before clearing it.
        """
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("web-password-set", params: ["clear": .bool(true)]))
    }
}
