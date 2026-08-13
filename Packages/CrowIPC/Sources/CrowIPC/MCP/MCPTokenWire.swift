import CrowCore
import Foundation

/// Wire shaping and input validation for MCP tokens (CROW-1004).
///
/// Lives in `CrowIPC` rather than beside the RPC handlers so it is covered by the
/// Linux PR lane: `CrowDaemon` is Darwin-only and its tests do not run on pull
/// requests, but `MCPTokenRecord`'s redaction contract and the duration grammar a
/// user types are exactly the things that must not regress unnoticed.
///
/// Only the SHA-256 itself stays in `CrowDaemon`, next to `PasswordHash`, because
/// that is where swift-crypto is a dependency.
public enum MCPTokenWire {

    /// Longest expiry a mint may request: 10 years. Not a security boundary — a
    /// caller wanting longer says `--no-expiry` — but a guard against a fat-fingered
    /// `--expires-in 9999999d` silently overflowing into a nonsense date.
    public static let maxExpirySeconds = 10 * 365 * 24 * 3600

    /// Default lifetime when a mint names neither `--expires-in` nor `--no-expiry`.
    ///
    /// 90 days is a deliberate middle: long enough that a working integration is not
    /// constantly re-credentialed, short enough that a token leaked from a bot host
    /// stops working within a quarter. The ticket's position is that an off-box token
    /// should expire, so "never" has to be typed.
    public static let defaultExpirySeconds = 90 * 24 * 3600

    /// Parse a human duration into seconds: `30s`, `45m`, `12h`, `90d`, `12w`.
    ///
    /// A bare number is **rejected** rather than assumed to be seconds or days.
    /// `--expires-in 90` is ambiguous between "90 days" and "90 seconds", and the
    /// two differ by seven orders of magnitude in how much access a leak buys —
    /// exactly the kind of guess that should be an error message instead.
    public static func parseDuration(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = text.last, let multiplier = durationUnits[unit] else { return nil }
        let numberPart = String(text.dropLast())
        guard !numberPart.isEmpty, let value = Int(numberPart), value > 0 else { return nil }
        // Multiply in a wider type so a huge input clamps rather than trapping.
        let seconds = value.multipliedReportingOverflow(by: multiplier)
        guard !seconds.overflow, seconds.partialValue <= maxExpirySeconds else { return nil }
        return seconds.partialValue
    }

    private static let durationUnits: [Character: Int] = [
        "s": 1, "m": 60, "h": 3600, "d": 86_400, "w": 604_800,
    ]

    /// Human-readable form of the duration grammar, for help text and errors.
    public static let durationHelp =
        "a number with a unit: s (seconds), m (minutes), h (hours), d (days), w (weeks) — e.g. 90d"

    /// Validate a token name. Names appear in `crow mcp token list` and the Settings
    /// UI, so a control character would corrupt both.
    public static func validate(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "a token name is required" }
        if trimmed.count > 100 { return "a token name must be 100 characters or fewer" }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "a token name must not contain control characters"
        }
        return nil
    }

    /// Resolve `scopes` from wire strings, rejecting anything unknown.
    ///
    /// At least one scope is required: a token granting nothing would authenticate
    /// successfully and then show an empty tool list, which reads as a broken server
    /// rather than a misconfigured token.
    public static func parseScopes(_ raw: [String]) -> Result<[MCPScope], MCPTokenValidationError> {
        guard !raw.isEmpty else {
            return .failure(MCPTokenValidationError(
                "at least one --scope is required (\(MCPScope.allCases.map(\.rawValue).sorted().joined(separator: ", ")))"))
        }
        var scopes: Set<MCPScope> = []
        for entry in raw {
            guard let scope = MCPScope.parse(entry) else {
                return .failure(MCPTokenValidationError(
                    "unknown scope '\(entry)' — valid scopes are "
                    + MCPScope.allCases.map(\.rawValue).sorted().joined(separator: ", ")))
            }
            scopes.insert(scope)
        }
        return .success(scopes.sorted())
    }
}

/// A token argument the caller got wrong. Carries only a message — every caller
/// turns it into either a `ValidationError` (CLI) or an `invalidParams` RPC error.
public struct MCPTokenValidationError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

extension MCPTokenRecord {
    /// Redacted form for `mcp-token-list` and the Settings UI — everything a human
    /// needs to identify and revoke a token, and nothing that could authenticate as
    /// one.
    ///
    /// There is no `reveal` variant, unlike `gateway get --reveal`. That is not a
    /// missing feature: a gateway header is stored verbatim and so *can* be shown
    /// again, whereas only a hash of a token was ever stored. The secret is
    /// unrecoverable by construction, which is the point of storing a hash.
    public func publicJSON(now: Date = Date()) -> [String: JSONValue] {
        let formatter = ISO8601DateFormatter()
        return [
            "id": .string(id.uuidString),
            "name": .string(name),
            "prefix": .string(prefix),
            "scopes": .array(scopes.sorted().map { .string($0.rawValue) }),
            "created_at": .string(formatter.string(from: createdAt)),
            "expires_at": expiresAt.map { .string(formatter.string(from: $0)) } ?? .null,
            "expired": .bool(isExpired(now: now)),
        ]
    }
}
