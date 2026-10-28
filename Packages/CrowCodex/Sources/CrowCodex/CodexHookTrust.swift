import Foundation

/// Codex's **per-hook** trust identity, reproduced so Crow can pre-approve its
/// own `.codex/hooks.json` entries (CROW-1381).
///
/// Folder trust (`CodexTrustSeeder`, `[projects."<path>"]`) is not enough.
/// Codex runs a non-managed hook only when `config.toml` carries a matching
/// ```toml
/// [hooks.state."<abs>/.codex/hooks.json:<event>:<group>:<handler>"]
/// trusted_hash = "sha256:…"
/// ```
/// (`hook_trust_status` in `codex-rs/hooks/src/engine/discovery.rs`). Without
/// it the TUI shows "Hooks need review" and `codex exec` skips the hook. Every
/// Crow worktree has a new path and every session bakes a new UUID into the
/// commands, so both the key and the hash are new each session.
///
/// The hash is upstream's `hook_hash`: the normalized handler, wrapped as
/// `{event_name, matcher?, hooks: [handler]}`, serialized to TOML, converted to
/// JSON with sorted keys and no whitespace, then SHA-256'd (`version_for_toml`
/// in `codex-rs/config/src/fingerprint.rs`). `None` fields drop out in the TOML
/// step. Crow writes no matcher and no `statusMessage`, and Codex ignores the
/// matcher on `Stop`/`UserPromptSubmit`/`Interrupt` anyway, so the identity is
/// `{"event_name":…,"hooks":[{"async":…,"command":…,"timeout":…,"type":"command"}]}`.
/// Verified against `codex app-server`'s `hooks/list` `currentHash` on 0.147.0
/// and 0.165.0.
///
/// This only ever hashes the document **Crow generates**, never a file read
/// from disk. A tampered or user-authored `hooks.json` therefore hashes
/// differently and stays untrusted.
enum CodexHookTrust {

    /// The `hooks.state` key segment for a `hooks.json` event name
    /// (`hook_event_key_label` in `codex-rs/hooks/src/lib.rs`). `nil` for an
    /// event Crow doesn't write.
    static func eventKeyLabel(_ event: String) -> String? {
        switch event {
        case "SessionStart": return "session_start"
        case "PreToolUse": return "pre_tool_use"
        case "PostToolUse": return "post_tool_use"
        case "UserPromptSubmit": return "user_prompt_submit"
        case "Stop": return "stop"
        case "PermissionRequest": return "permission_request"
        case "Interrupt": return "interrupt"
        default: return nil
        }
    }

    /// The `hooks.state` key for handler 0 of group 0 of `eventLabel` in the
    /// `.codex/hooks.json` under `projectPath` — the only slot Crow writes.
    static func stateKey(projectPath: String, eventLabel: String) -> String {
        "\(stateKeyPrefix(projectPath: projectPath))\(eventLabel):0:0"
    }

    /// The prefix every `hooks.state` key for `projectPath`'s `hooks.json` shares.
    static func stateKeyPrefix(projectPath: String) -> String {
        let hooksPath = ((projectPath as NSString)
            .appendingPathComponent(".codex") as NSString)
            .appendingPathComponent(CodexHookConfigWriter.fileName)
        return "\(hooksPath):"
    }

    /// `sha256:<hex>` for one command handler, as Codex computes it.
    ///
    /// `timeout` must be the value Codex normalizes to (Crow writes values that
    /// are already in range). `async` is the declared flag, not whether Codex
    /// actually runs it async.
    static func commandHash(
        eventLabel: String, command: String, timeout: Int, async: Bool
    ) -> String {
        let json = "{\"event_name\":\(jsonString(eventLabel)),\"hooks\":[{"
            + "\"async\":\(async ? "true" : "false"),"
            + "\"command\":\(jsonString(command)),"
            + "\"timeout\":\(timeout),"
            + "\"type\":\"command\"}]}"
        return "sha256:" + SHA256Digest.hex(Array(json.utf8))
    }

    /// A JSON string literal escaped exactly as `serde_json` does: `"` and `\`,
    /// the short escapes, other C0 controls as lowercase `\u00xx`, and
    /// everything else (including `/` and non-ASCII) verbatim. Foundation's
    /// encoders differ on `/` and on the hex case, which would change the hash.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
