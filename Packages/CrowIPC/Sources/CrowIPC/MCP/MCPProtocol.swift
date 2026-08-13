import Foundation

/// The MCP wire envelope (CROW-1004).
///
/// ### Why this does not reuse `JSONRPCRequest` / `JSONRPCResponse`
///
/// The types in `Protocol.swift` are a deliberately narrow subset of JSON-RPC 2.0,
/// shaped for Crow's own CLI ↔ daemon channel: `id` is a non-optional `Int`,
/// `result` is always a `[String: JSONValue]` **dictionary**, `JSONRPCError` has no
/// `data` field, and notifications have no representation at all.
///
/// MCP needs all four of those things. Its ids are string-or-number (and absent for
/// notifications), `tools/call` results are objects but `server/discover` returns
/// arrays inside them, `UnsupportedProtocolVersionError` **must** carry
/// `data.supported`, and `notifications/initialized` is a notification with no id.
///
/// So MCP gets its own envelope and converts inward: `MCPServer` builds a
/// `JSONRPCRequest` with a synthetic `Int` id when it calls into the router. The two
/// dialects meet at exactly one place, which is the point.
public enum MCPProtocol {

    // MARK: - Versions

    /// The modern, stateless revision: per-request `_meta`, mandatory
    /// `server/discover`, no sessions, no GET stream.
    public static let modernVersion = "2026-07-28"

    /// The legacy revision we answer `initialize` with. `2025-11-25` is the last
    /// handshake-based revision, so it is the newest thing a legacy client can ask
    /// for and get an exact match on.
    public static let legacyVersion = "2025-11-25"

    /// Legacy revisions we will accept in an `initialize` request. A client asking
    /// for one of these gets it echoed back verbatim, per the legacy negotiation
    /// rule ("if the server supports the requested version it MUST respond with the
    /// same version"). Anything else gets `legacyVersion`, which is also per spec
    /// ("otherwise the server MUST respond with another protocol version it
    /// supports").
    public static let supportedLegacyVersions: Set<String> = [
        "2025-11-25", "2025-06-18", "2025-03-26",
    ]

    /// Everything we speak, newest first — the `supported` array in a `-32022`.
    public static let supportedVersions: [String] = [
        modernVersion, "2025-11-25", "2025-06-18", "2025-03-26",
    ]

    /// The `_meta` key carrying the protocol version on a modern request, and the
    /// HTTP header that mirrors it.
    public static let metaVersionKey = "io.modelcontextprotocol/protocolVersion"
    public static let protocolVersionHeader = "MCP-Protocol-Version"

    // MARK: - Error codes

    /// MCP's own codes sit alongside the JSON-RPC standard ones. `-32020` and
    /// `-32022` are allocated from the range the MCP spec reserves for
    /// protocol-defined errors; they are not JSON-RPC standard codes and must not
    /// be confused with `RPCErrorCode`'s.
    public enum ErrorCode {
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603
        /// `HeaderMismatch` — an HTTP header disagrees with the request body.
        public static let headerMismatch = -32020
        /// `UnsupportedProtocolVersionError` — carries `data.supported`.
        public static let unsupportedProtocolVersion = -32022
    }

    // MARK: - Era

    /// Which dialect a single request is speaking.
    ///
    /// This is decided **per request**, not per connection, because the modern
    /// revision has no connection state to hang it on. A dual-era server is allowed
    /// to serve both concurrently on one endpoint, which is exactly what we do.
    public enum Era: Sendable, Equatable {
        /// Per-request `_meta` carries a protocol version (revision 2026-07-28+).
        case modern(version: String)
        /// The `initialize` handshake, or any request on a connection that opened
        /// with one (revision 2025-11-25 and earlier).
        case legacy
    }

    /// Classify a request.
    ///
    /// A body carrying `_meta.io.modelcontextprotocol/protocolVersion` is modern —
    /// that field is the modern era's defining feature and legacy clients never send
    /// it. Everything else is legacy, which is the safe default: a legacy client that
    /// is misread as modern gets rejected for missing headers it has never heard of,
    /// while a modern client misread as legacy simply gets an answer it can still
    /// parse (the extra `resultType` key aside, the shapes agree).
    public static func era(of request: MCPRequest) -> Era {
        if let version = request.metaProtocolVersion {
            return .modern(version: version)
        }
        return .legacy
    }

    /// Whether we implement `version`. Used to decide `-32022`.
    public static func supports(version: String) -> Bool {
        supportedVersions.contains(version)
    }
}

// MARK: - Request id

/// A JSON-RPC id as MCP actually uses it: a string, a number, or absent.
///
/// `null` is representable because JSON-RPC allows it in an error response to a
/// request that could not be parsed. It is deliberately distinct from `.absent`,
/// which means *notification* — a message we must answer with `202 Accepted` and no
/// body rather than with a response object.
public enum MCPRequestID: Sendable, Equatable {
    case string(String)
    case number(Int)
    case null
    case absent

    /// True when this message is a notification and therefore takes no response.
    public var isNotification: Bool { self == .absent }

    var jsonValue: JSONValue {
        switch self {
        case .string(let s): return .string(s)
        case .number(let n): return .int(n)
        case .null, .absent: return .null
        }
    }
}

// MARK: - Request

/// One decoded MCP request or notification.
public struct MCPRequest: Sendable, Equatable {
    public let id: MCPRequestID
    public let method: String
    public let params: [String: JSONValue]

    public init(id: MCPRequestID, method: String, params: [String: JSONValue] = [:]) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// `params._meta`, where the modern revision puts version and client identity.
    public var meta: [String: JSONValue] {
        params["_meta"]?.objectValue ?? [:]
    }

    /// The modern per-request protocol version, if this is a modern request.
    public var metaProtocolVersion: String? {
        meta[MCPProtocol.metaVersionKey]?.stringValue
    }

    /// The value the `Mcp-Name` header must mirror: `params.name` for `tools/call`
    /// and `prompts/get`, `params.uri` for `resources/read`. Nil when the method
    /// takes neither, in which case the header must be absent.
    public var headerMirroredName: String? {
        params["name"]?.stringValue ?? params["uri"]?.stringValue
    }

    /// Decode one JSON message.
    ///
    /// Returns nil for anything that is not a JSON-RPC *request or notification* —
    /// including a response, which clients are forbidden from POSTing. A `params`
    /// that is present but not an object is treated as empty rather than rejected:
    /// every method here reads named parameters, so a positional array simply finds
    /// nothing, and the handler's own "missing required argument" message is a more
    /// useful diagnostic than a parse error.
    public static func decode(_ data: Data) -> MCPRequest? {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue,
              let method = object["method"]?.stringValue
        else { return nil }

        let id: MCPRequestID
        switch object["id"] {
        case .some(.string(let s)): id = .string(s)
        case .some(.int(let n)): id = .number(n)
        case .some(.null): id = .null
        case .none: id = .absent
        // A double id is legal JSON but not a legal JSON-RPC id in practice;
        // treat it as malformed rather than silently truncating to Int.
        default: return nil
        }

        return MCPRequest(
            id: id,
            method: method,
            params: object["params"]?.objectValue ?? [:])
    }
}

// MARK: - Response

/// One MCP response, ready to serialize.
public struct MCPResponse: Sendable, Equatable {
    public let id: MCPRequestID
    public let payload: Payload

    public enum Payload: Sendable, Equatable {
        case result([String: JSONValue])
        case error(code: Int, message: String, data: [String: JSONValue]?)
    }

    public static func result(id: MCPRequestID, _ result: [String: JSONValue]) -> MCPResponse {
        MCPResponse(id: id, payload: .result(result))
    }

    public static func error(
        id: MCPRequestID,
        code: Int,
        message: String,
        data: [String: JSONValue]? = nil
    ) -> MCPResponse {
        MCPResponse(id: id, payload: .error(code: code, message: message, data: data))
    }

    /// `UnsupportedProtocolVersionError`, with the `supported` list the spec
    /// requires so the client can retry rather than give up.
    public static func unsupportedVersion(id: MCPRequestID, requested: String) -> MCPResponse {
        .error(
            id: id,
            code: MCPProtocol.ErrorCode.unsupportedProtocolVersion,
            message: "Unsupported protocol version",
            data: [
                "supported": .array(MCPProtocol.supportedVersions.map { .string($0) }),
                "requested": .string(requested),
            ])
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
        ]
        switch payload {
        case .result(let result):
            object["result"] = .object(result)
        case .error(let code, let message, let data):
            var error: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
            if let data { error["data"] = .object(data) }
            object["error"] = .object(error)
        }
        return .object(object)
    }

    /// Serialized bytes. `sortedKeys` so the same response is byte-identical run to
    /// run, which is what makes the tests assertable.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(jsonValue)) ?? Data("{}".utf8)
    }
}
