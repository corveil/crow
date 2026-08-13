import CrowCore
import Foundation

/// What the transport should do with one handled message.
///
/// The two transports need different things from the same core: HTTP has status
/// codes and the spec pins several of them, while stdio only needs to know whether
/// there are bytes to write. So the core returns intent and each transport maps it.
public enum MCPOutcome: Sendable, Equatable {
    /// Write these bytes (HTTP: 200 `application/json`).
    case reply(MCPResponse)
    /// A notification — the spec requires HTTP `202 Accepted` with **no body**, and
    /// stdio simply writes nothing.
    case accepted
    /// Unknown method. HTTP 404 + a JSON-RPC `-32601` body, which is what lets a
    /// client tell a modern MCP server from a legacy `HTTP+SSE` server that does not
    /// host this endpoint at all.
    case unknownMethod(MCPResponse)
    /// A request we refuse before dispatch: unsupported protocol version (`-32022`)
    /// or a header that disagrees with the body (`-32020`). HTTP 400 — and the body
    /// matters, because a dual-era *client* inspects it to decide whether to fall
    /// back to `initialize` or retry with a supported version.
    case badRequest(MCPResponse)

    /// The bytes to write, if any.
    public var responseData: Data? {
        switch self {
        case .accepted: return nil
        case .reply(let r), .unknownMethod(let r), .badRequest(let r): return r.encoded()
        }
    }
}

/// The dual-era MCP server core (CROW-1004).
///
/// One endpoint serves both protocol eras, which the spec explicitly permits:
/// *"A dual-era server MAY serve both eras concurrently on the same endpoint or
/// process."* It has to, in practice — revision `2026-07-28` removed the
/// `initialize` handshake only weeks ago, and the clients this exists for still open
/// with one.
///
/// The server is **stateless**. It holds no session, remembers no handshake, and
/// derives everything it needs from the request in hand plus the scopes the
/// transport authenticated. That is the modern revision's model, and it happens to
/// be what makes the legacy path safe too: there is no per-connection state for a
/// second caller to inherit.
///
/// Transport-agnostic by construction — `invoke` is injected, so the daemon passes
/// its `CommandRouter` and `crow mcp serve` passes a Unix-socket round trip, and
/// both are exercised by the same tests against a stub.
public struct MCPServer: Sendable {
    public let serverName: String
    public let serverVersion: String

    public init(serverName: String = "crow", serverVersion: String) {
        self.serverName = serverName
        self.serverVersion = serverVersion
    }

    /// Guidance handed to the model alongside the tool list.
    static let instructions = """
        Crow orchestrates AI coding sessions across git worktrees. This server is \
        read-only: it can report on sessions, tickets and reviews, but cannot create, \
        modify or message them. Start with get_board_summary for the shape of the \
        board, list_stuck_sessions for what needs a human, and get_session for one \
        session's detail.
        """

    /// Capabilities we advertise. Tools only — no resources, prompts, logging, or
    /// `listChanged` (the set is a compile-time constant, so there is nothing to
    /// notify about).
    static var capabilities: JSONValue { .object(["tools": .object([:])]) }

    // MARK: - Entry point

    /// Handle one raw JSON message.
    public func handle(
        _ data: Data,
        scopes: Set<MCPScope>,
        invoke: @escaping MCPInvoke
    ) async -> MCPOutcome {
        guard let request = MCPRequest.decode(data) else {
            return .badRequest(.error(
                id: .null,
                code: MCPProtocol.ErrorCode.parseError,
                message: "Malformed JSON-RPC request"))
        }
        return await handle(request, scopes: scopes, invoke: invoke)
    }

    /// Handle one decoded request. Split out so the HTTP transport can validate
    /// headers against the same decoded body it dispatches.
    public func handle(
        _ request: MCPRequest,
        scopes: Set<MCPScope>,
        invoke: @escaping MCPInvoke
    ) async -> MCPOutcome {
        let era = MCPProtocol.era(of: request)

        // Modern requests declare their version on every message and we accept or
        // reject each one independently — there is no handshake to have settled it.
        if case .modern(let version) = era, !MCPProtocol.supports(version: version) {
            return .badRequest(.unsupportedVersion(id: request.id, requested: version))
        }

        // Notifications take no response at all. `notifications/initialized` is the
        // only one a legacy client sends us; anything else unknown is still
        // swallowed, because answering a notification is itself a protocol error.
        if request.id.isNotification {
            return .accepted
        }

        switch request.method {
        case "server/discover":
            return .reply(.result(id: request.id, discoverResult()))

        case "initialize":
            return .reply(.result(id: request.id, initializeResult(request)))

        case "ping":
            // Both eras; the spec defines it as an empty result.
            return .reply(.result(id: request.id, [:]))

        case "tools/list":
            var result: [String: JSONValue] = [
                "tools": .array(MCPToolCatalog.tools(for: scopes).map(\.definitionJSON)),
            ]
            if case .modern = era { result["resultType"] = .string("complete") }
            return .reply(.result(id: request.id, result))

        case "tools/call":
            return await callTool(request, era: era, scopes: scopes, invoke: invoke)

        default:
            return .unknownMethod(.error(
                id: request.id,
                code: MCPProtocol.ErrorCode.methodNotFound,
                message: "Unknown method: \(request.method)"))
        }
    }

    // MARK: - Methods

    private func discoverResult() -> [String: JSONValue] {
        [
            "resultType": .string("complete"),
            "supportedVersions": .array(MCPProtocol.supportedVersions.map { .string($0) }),
            "capabilities": Self.capabilities,
            "instructions": .string(Self.instructions),
            "_meta": .object([
                "io.modelcontextprotocol/serverInfo": .object([
                    "name": .string(serverName),
                    "version": .string(serverVersion),
                ]),
            ]),
        ]
    }

    /// The legacy handshake.
    ///
    /// Version rule, straight from the legacy lifecycle spec: echo the requested
    /// version when we support it, otherwise answer with one we do. Note this is
    /// **not** an error case — a legacy client that can't live with our answer is
    /// the one that disconnects.
    private func initializeResult(_ request: MCPRequest) -> [String: JSONValue] {
        let requested = request.params["protocolVersion"]?.stringValue ?? ""
        let agreed = MCPProtocol.supportedLegacyVersions.contains(requested)
            ? requested
            : MCPProtocol.legacyVersion
        return [
            "protocolVersion": .string(agreed),
            "capabilities": Self.capabilities,
            "serverInfo": .object([
                "name": .string(serverName),
                "title": .string("Crow"),
                "version": .string(serverVersion),
            ]),
            "instructions": .string(Self.instructions),
        ]
    }

    private func callTool(
        _ request: MCPRequest,
        era: MCPProtocol.Era,
        scopes: Set<MCPScope>,
        invoke: @escaping MCPInvoke
    ) async -> MCPOutcome {
        guard let name = request.params["name"]?.stringValue else {
            return .reply(.error(
                id: request.id,
                code: MCPProtocol.ErrorCode.invalidParams,
                message: "tools/call requires a `name`"))
        }
        // Unknown and out-of-scope are answered identically on purpose: a distinct
        // "you lack the scope" would let a narrow token enumerate the tools it
        // cannot see, which is the same leak that filtering `tools/list` closes.
        guard let tool = MCPToolCatalog.tool(named: name, scopes: scopes) else {
            return .reply(.error(
                id: request.id,
                code: MCPProtocol.ErrorCode.invalidParams,
                message: "Unknown tool: \(name)"))
        }

        let arguments = request.params["arguments"]?.objectValue ?? [:]
        do {
            let value = try await tool.run(arguments, invoke)
            return .reply(.result(id: request.id, toolResult(value, era: era)))
        } catch let error as MCPToolInputError {
            // Actionable: the model can fix an argument and retry, so this is a tool
            // execution error rather than a protocol one.
            return .reply(.result(id: request.id, toolError(error.message, era: era)))
        } catch {
            // The daemon refused or is down. Also a tool execution error — a client
            // that sees `isError` can say so; a transport failure just looks broken.
            return .reply(.result(
                id: request.id,
                toolError("Crow daemon error: \(error.localizedDescription)", era: era)))
        }
    }

    // MARK: - Result shaping

    /// A successful tool result carries the data twice: once as `structuredContent`
    /// for clients that validate, and once as JSON text in `content`, which the spec
    /// asks for so a client that only reads `content` still gets the data.
    private func toolResult(_ value: JSONValue, era: MCPProtocol.Era) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(jsonText(value)),
            ])]),
            "structuredContent": value,
            "isError": .bool(false),
        ]
        if case .modern = era { result["resultType"] = .string("complete") }
        return result
    }

    private func toolError(_ message: String, era: MCPProtocol.Era) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(message),
            ])]),
            "isError": .bool(true),
        ]
        if case .modern = era { result["resultType"] = .string("complete") }
        return result
    }

    private func jsonText(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    // MARK: - HTTP header validation

    /// Validate the mirrored HTTP headers a modern request must carry.
    ///
    /// The modern Streamable HTTP transport duplicates `method` and `params.name`
    /// into `Mcp-Method` / `Mcp-Name` so intermediaries can route without parsing
    /// the body — which means the two can disagree, and a load balancer acting on
    /// the header while we act on the body is a real vulnerability. The spec's
    /// answer is `400` + `-32020`, and it is mandatory for servers that read the
    /// body. Returns nil when everything agrees.
    ///
    /// Legacy requests are exempt: those headers postdate them, and rejecting a
    /// legacy client for omitting a header it has never heard of would break exactly
    /// the compatibility this server exists to provide.
    ///
    /// `Mcp-Name` may arrive Base64-wrapped as `=?base64?...?=` when the value is
    /// not header-safe; decode before comparing, per the spec's Value Encoding rules.
    public static func headerMismatch(
        request: MCPRequest,
        methodHeader: String?,
        nameHeader: String?,
        versionHeader: String?
    ) -> MCPResponse? {
        guard case .modern(let bodyVersion) = MCPProtocol.era(of: request) else { return nil }

        func mismatch(_ message: String) -> MCPResponse {
            .error(id: request.id, code: MCPProtocol.ErrorCode.headerMismatch, message: message)
        }

        guard let versionHeader, !versionHeader.isEmpty else {
            return mismatch("Missing required header: \(MCPProtocol.protocolVersionHeader)")
        }
        guard versionHeader == bodyVersion else {
            return mismatch(
                "Header mismatch: \(MCPProtocol.protocolVersionHeader) '\(versionHeader)' "
                + "does not match body value '\(bodyVersion)'")
        }
        guard let methodHeader, !methodHeader.isEmpty else {
            return mismatch("Missing required header: Mcp-Method")
        }
        guard methodHeader == request.method else {
            return mismatch(
                "Header mismatch: Mcp-Method '\(methodHeader)' does not match body value '\(request.method)'")
        }

        // `Mcp-Name` is required exactly when the body has a name to mirror.
        let expected = request.headerMirroredName
        let actual = nameHeader.map(decodeHeaderValue)
        switch (expected, actual) {
        case (nil, nil):
            return nil
        case (nil, .some(let got)):
            return mismatch("Header mismatch: Mcp-Name '\(got)' sent for a method with no name")
        case (.some, nil):
            return mismatch("Missing required header: Mcp-Name")
        case (.some(let want), .some(let got)) where want != got:
            return mismatch("Header mismatch: Mcp-Name '\(got)' does not match body value '\(want)'")
        default:
            return nil
        }
    }

    /// Undo the spec's `=?base64?...?=` sentinel wrapping. A value that isn't
    /// wrapped, or whose payload isn't decodable UTF-8, is returned as-is so it
    /// fails the comparison above rather than being silently accepted.
    static func decodeHeaderValue(_ raw: String) -> String {
        let prefix = "=?base64?"
        let suffix = "?="
        guard raw.hasPrefix(prefix), raw.hasSuffix(suffix), raw.count > prefix.count + suffix.count
        else { return raw }
        let body = String(raw.dropFirst(prefix.count).dropLast(suffix.count))
        guard let data = Data(base64Encoded: body),
              let decoded = String(data: data, encoding: .utf8)
        else { return raw }
        return decoded
    }
}
