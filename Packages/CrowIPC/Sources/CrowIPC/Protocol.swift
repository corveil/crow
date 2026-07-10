import Foundation
// Import the platform C library directly for `SOCK_STREAM` rather than relying
// on Foundation re-exporting it (behavior differs by toolchain), matching the
// sibling socket files.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// On Linux, Glibc types `SOCK_STREAM` as `__socket_type` rather than `Int32`,
// so `socket(_:_:_:)` needs the raw value. On Darwin it is already `Int32`.
#if canImport(Glibc)
let crowSockStream = Int32(SOCK_STREAM.rawValue)
#else
let crowSockStream = SOCK_STREAM
#endif

// MARK: - JSON-RPC 2.0 Protocol Types

/// A JSON-RPC 2.0 request sent from the CLI client to the socket server.
public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let method: String
    public let params: [String: JSONValue]?

    public init(id: Int, method: String, params: [String: JSONValue]? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A JSON-RPC 2.0 response returned from the socket server to the CLI client.
public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public var result: [String: JSONValue]?
    public var error: JSONRPCError?

    public static func success(id: Int, result: [String: JSONValue]) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    public static func error(id: Int, code: Int, message: String) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: nil, error: JSONRPCError(code: code, message: message))
    }
}

/// Structured error payload within a JSON-RPC 2.0 response.
public struct JSONRPCError: Codable, Sendable {
    public let code: Int
    public let message: String
}

// MARK: - JSON Value (type-erased for flexible params/results)

/// Type-erased JSON value used for flexible RPC parameters and results.
///
/// Supports all JSON primitives (string, int, double, bool, null)
/// and compound types (array, object). Each case provides a typed
/// accessor property that returns `nil` for mismatched types.
public enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let d) = self { return d }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Error Codes

/// Standard JSON-RPC 2.0 error codes plus the application-level error code.
public enum RPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    public static let applicationError = -32000
}

// MARK: - RPCErrorCoded Protocol

/// Conforming errors provide a specific JSON-RPC error code so the
/// `CommandRouter` can return it instead of the generic `-32000`.
public protocol RPCErrorCoded: Error {
    var rpcErrorCode: Int { get }
}
