import Foundation
import CrowIPC

/// Error thrown by the engine's RPC handlers, carrying a JSON-RPC error code.
/// Relocated out of `AppDelegate` so `makeEngineRouter` and its handlers can
/// live in CrowEngine (CROW-581 headless-engine migration).
public enum RPCError: Error, LocalizedError, RPCErrorCoded {
    case invalidParams(String)
    case applicationError(String)

    public var rpcErrorCode: Int {
        switch self {
        case .invalidParams: RPCErrorCode.invalidParams
        case .applicationError: RPCErrorCode.applicationError
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidParams(let msg): msg
        case .applicationError(let msg): msg
        }
    }
}
