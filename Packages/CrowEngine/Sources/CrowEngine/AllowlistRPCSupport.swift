import CrowIPC
import Foundation

/// Pure param decode for the `promote-allowlist` RPC (#819).
///
/// Kept out of the router — like `JobRPC` — so the strictness policy is
/// unit-testable without a socket. Deliberately strict where the previous
/// inline decode was lenient: a non-string element used to be dropped by
/// `compactMap`, so a malformed payload promoted a *subset* of the requested
/// patterns and still answered `{"ok":true}`. A partially-applied permission
/// write must never look like a success.
public enum AllowlistRPC {
    /// Decode the `patterns` param: an array of strings, each trimmed, blanks
    /// dropped, deduped, at least one survivor.
    ///
    /// - Throws: `RPCError.invalidParams` when the param is missing, isn't an
    ///   array, holds a non-string element, or is empty after trimming.
    public static func decodePatterns(_ value: JSONValue?) throws -> Set<String> {
        guard let items = value?.arrayValue else {
            throw RPCError.invalidParams("patterns must be an array of strings")
        }
        let strings = items.compactMap(\.stringValue)
        guard strings.count == items.count else {
            throw RPCError.invalidParams("patterns must contain only strings")
        }
        let cleaned = Set(
            strings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !cleaned.isEmpty else {
            throw RPCError.invalidParams("patterns must contain at least one non-blank pattern")
        }
        return cleaned
    }

    /// Canonical `promote-allowlist` response: `ok` for the web caller that has
    /// always read it, plus what the write actually did so a scripted caller can
    /// tell "already global" from "newly granted" (#819).
    public static func promotionJSON(_ promotion: AllowlistPromotion) -> [String: JSONValue] {
        [
            "ok": .bool(true),
            "added": .array(promotion.added.map { .string($0) }),
            "already_global": .array(promotion.alreadyGlobal.map { .string($0) }),
            "global_settings_path": .string(promotion.globalSettingsPath),
        ]
    }
}
