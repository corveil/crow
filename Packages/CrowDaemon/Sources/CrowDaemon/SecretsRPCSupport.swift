import CrowCore
import CrowEngine
import CrowIPC
import Foundation

/// Param decoding and response encoding for the `gateway-*` / `web-password-*`
/// RPC methods (CROW-815) — the CLI-facing analog of the `SecretRoutes` HTTP
/// bodies. The validation itself is *not* duplicated here: the handlers feed
/// what this decodes straight into ``SecretRoutes/buildGateway(_:)`` and
/// ``SecretRoutes/mergingPreservedHeaders(incoming:stored:)``, which own the
/// both-or-neither invariant and the "blank value keeps the stored secret"
/// contract.
///
/// These methods are reachable over the local Unix socket only — the `/rpc`
/// WebSocket path refuses them in ``RPCWebSocketHandler/localOnlyDenial(for:devRoot:)``.
enum SecretsRPC {
    /// Which gateway a `gateway-*` call addresses.
    enum GatewayTarget: Equatable {
        case manager
        /// A workspace, referenced by UUID or by name (see ``resolveWorkspace(_:in:)``).
        case workspace(String)
    }

    /// Decode the target selector: exactly one of `target: "manager"` or
    /// `workspace: "<name|uuid>"`.
    static func decodeTarget(_ params: [String: JSONValue]) throws -> GatewayTarget {
        let target = params["target"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        let workspace = params["workspace"]?.stringValue?.trimmingCharacters(in: .whitespaces)

        switch (target, workspace) {
        case let (.some(target), nil) where !target.isEmpty:
            guard target == "manager" else {
                throw DaemonRPCError.invalidParams("target must be \"manager\" (got \"\(target)\")")
            }
            return .manager
        case let (nil, .some(workspace)) where !workspace.isEmpty:
            return .workspace(workspace)
        case (.some, .some):
            throw DaemonRPCError.invalidParams("target and workspace are mutually exclusive")
        default:
            throw DaemonRPCError.invalidParams("one of target=\"manager\" or workspace=<name|uuid> is required")
        }
    }

    /// Find a workspace by UUID, falling back to a case-insensitive name match.
    ///
    /// Delegates to ``WorkspaceRPC/resolveIndex(_:in:)`` so `gateway-*` and
    /// `workspace-*` can't drift on what `--workspace Corveil` means; the only
    /// thing added here is the error-type translation for the gateway handlers,
    /// which predate `mapRPCError` and throw `DaemonRPCError` directly.
    static func resolveWorkspace(_ ref: String, in config: AppConfig) throws -> Int {
        do {
            return try WorkspaceRPC.resolveIndex(ref, in: config)
        } catch let error as RPCError {
            switch error {
            case .invalidParams(let message): throw DaemonRPCError.invalidParams(message)
            case .applicationError(let message): throw DaemonRPCError.applicationError(message)
            }
        }
    }

    /// Decode `header_lines: ["Name: Value", …]` into a header map.
    ///
    /// Parsing goes through ``WorkspaceGateway/parseHeaderLines(_:)`` so the CLI,
    /// the Settings UI, and the gateway model all split headers the same way. A
    /// blank *value* is preserved (it means "keep the stored secret"); a line
    /// with no colon or a blank name is rejected here rather than silently
    /// dropped, since a typo'd flag should not quietly produce an empty gateway.
    ///
    /// One entry must mean one header. `parseHeaderLines` splits on newlines, so
    /// an entry containing `\n` would smuggle in extra headers past the per-entry
    /// check below — reject embedded newlines instead of silently expanding them.
    static func decodeHeaderLines(_ value: JSONValue?) throws -> [String: String] {
        guard let lines = value?.arrayValue else { return [:] }
        let texts = try lines.map { line -> String in
            guard let text = line.stringValue else {
                throw DaemonRPCError.invalidParams("header_lines must be an array of strings")
            }
            return text
        }
        for text in texts {
            // Quote-wrapped values and quote-carrying names are NOT checked here —
            // `SecretRoutes.buildGateway` owns those rules for both this path and
            // the web's, and every entry decoded here flows into it (see the
            // "gateway-set" handler in RPCHandlers). Adding them here would shadow
            // that message, so the CLI and the browser would report different text
            // for the same mistake (CROW-969). The checks below stay because they
            // are *line-shape* rules: they must run before `parseHeaderLines`
            // collapses these lines into a map.
            //
            // CharacterSet, not `contains("\n")`: Swift treats CRLF as a single
            // Character, so a grapheme comparison misses "\r\n" entirely.
            guard text.rangeOfCharacter(from: .newlines) == nil else {
                throw DaemonRPCError.invalidParams(
                    "A header must be a single line — '\(text)' contains a newline.")
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":"),
                  !String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).isEmpty else {
                throw DaemonRPCError.invalidParams(
                    "'\(text)' is not a valid header. Expected 'Name: Value'.")
            }
        }
        return WorkspaceGateway.parseHeaderLines(texts.joined(separator: "\n"))
    }

    /// Encode a gateway for a `gateway-get` response.
    ///
    /// Header *values* are blanked unless `reveal` — mirroring
    /// `SettingsSecrets.strippedForTransport`, so the default output is safe to
    /// paste into a ticket. Keys and the base URL always pass through.
    static func gatewayJSON(_ gateway: WorkspaceGateway?, reveal: Bool) -> [String: JSONValue] {
        guard let gateway else {
            return ["gateway_set": .bool(false), "base_url": .string(""), "headers": .object([:])]
        }
        let headers = gateway.customHeaders.mapValues { JSONValue.string(reveal ? $0 : "") }
        return [
            "gateway_set": .bool(true),
            "base_url": .string(gateway.baseURL),
            "headers": .object(headers),
        ]
    }
}
