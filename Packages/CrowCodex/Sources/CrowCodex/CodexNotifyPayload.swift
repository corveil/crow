import Foundation

/// Translates OpenAI Codex's notify-command JSON payload into a hook-event
/// shape the rest of Crow can consume. Codex invokes the configured `notify`
/// command with the JSON payload as the final positional argument; the
/// payload uses kebab-case keys (`agent-turn-complete`, `thread-id`,
/// `turn-id`, `cwd`, `last-assistant-message`).
///
/// Returns a `(eventName, payload)` pair as plain strings — `CrowCodex` has
/// no dependency on `CrowIPC`'s `JSONValue` type, so the CLI converts the
/// `[String: String]` payload into the JSON-RPC shape at the boundary.
public enum CodexNotifyPayload {
    public struct Translation: Sendable, Equatable {
        public let eventName: String
        public let payload: [String: String]
    }

    /// Translate a Codex notify JSON string. The mapping is intentionally
    /// minimal for MVP — the notify path is a Tier-2 fallback, so we only
    /// need to recognize `agent-turn-complete` to drive the `.done`
    /// transition. Anything else falls through as a generic `Notification`
    /// event (no state change after the blanket clear).
    public static func translate(_ json: String) -> Translation {
        let data = json.data(using: .utf8) ?? Data()
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Unparseable — surface the raw text for debugging visibility.
            return Translation(
                eventName: "Notification",
                payload: ["message": json]
            )
        }

        // Forward all string-valued top-level keys, normalizing kebab-case
        // to snake_case so the signal source / RPC handler doesn't need a
        // per-agent switch on key style.
        var payload: [String: String] = [:]
        for (key, value) in root {
            guard let s = stringify(value) else { continue }
            payload[normalizeKey(key)] = s
        }

        let type = (root["type"] as? String) ?? ""
        switch type {
        case "agent-turn-complete":
            return Translation(eventName: "Stop", payload: payload)
        default:
            return Translation(eventName: "Notification", payload: payload)
        }
    }

    /// Normalize Codex's kebab-case keys to the snake_case the rest of the
    /// pipeline expects (e.g. `cwd` stays `cwd`, `turn-id` becomes
    /// `turn_id`, `last-assistant-message` becomes `last_assistant_message`).
    private static func normalizeKey(_ key: String) -> String {
        key.replacingOccurrences(of: "-", with: "_")
    }

    /// Best-effort string extraction so callers can pass the payload through
    /// to a string-keyed dict. Numbers and booleans get stringified; nested
    /// objects/arrays are dropped (we don't currently need them).
    private static func stringify(_ value: Any) -> String? {
        switch value {
        case let s as String:
            return s
        case let i as Int:
            return String(i)
        case let d as Double:
            return String(d)
        case let b as Bool:
            return String(b)
        default:
            return nil
        }
    }
}
