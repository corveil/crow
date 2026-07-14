import Foundation

/// Routes JSON-RPC method names to async handler closures.
///
/// Each handler receives the request's `params` dictionary (or an empty
/// dictionary if none were sent) and returns a result dictionary. Errors
/// thrown by handlers are converted to JSON-RPC error responses:
/// - Errors conforming to ``RPCErrorCoded`` use their specific error code.
/// - All other errors are reported as `-32000` (application error).
public final class CommandRouter: Sendable {
    public typealias Handler = @Sendable ([String: JSONValue]) async throws -> [String: JSONValue]

    private let handlers: [String: Handler]

    /// Optional next router consulted when this one has no handler for a method.
    /// Lets a curated router (e.g. the daemon's) delegate everything it doesn't
    /// explicitly own to a fuller one (the engine surface) so a method can never
    /// be silently missing (CROW-581).
    private let fallback: CommandRouter?

    public init(handlers: [String: Handler], fallback: CommandRouter? = nil) {
        self.handlers = handlers
        self.fallback = fallback
    }

    public func handle(request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let handler = handlers[request.method] else {
            if let fallback {
                return await fallback.handle(request: request)
            }
            return .error(id: request.id, code: RPCErrorCode.methodNotFound, message: "Unknown method: \(request.method)")
        }

        do {
            let result = try await handler(request.params ?? [:])
            return .success(id: request.id, result: result)
        } catch let coded as RPCErrorCoded {
            return .error(id: request.id, code: coded.rpcErrorCode, message: coded.localizedDescription)
        } catch {
            return .error(id: request.id, code: RPCErrorCode.applicationError, message: error.localizedDescription)
        }
    }
}
