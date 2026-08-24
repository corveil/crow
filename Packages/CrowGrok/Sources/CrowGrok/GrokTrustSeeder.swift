import Foundation

/// Seeds per-folder trust into `~/.grok/trusted_folders.toml` so Grok Build
/// skips its folder-trust gate when Crow auto-launches a session in a fresh
/// worktree. Grok's folder-trust store governs whether it loads (and runs)
/// repo-local hooks / MCP / LSP; an untrusted folder silently skips project
/// hooks, which would break Crow's state detection. This is the analog Crow
/// solves via `ClaudeTrustSeeder` (CROW-600) and `CodexTrustSeeder` (#830).
///
/// Verified against `xai-org/grok-build@main` (2026-07-25,
/// `crates/codegen/xai-grok-workspace/src/trust.rs`), Grok records trust as:
/// ```toml
/// [folders."/abs/repo/root"]
/// trusted = true
/// ```
/// Trust **cascades to subdirectories** (longest-matching-prefix wins), and the
/// store lives at `<grok_home>/trusted_folders.toml`. `decided_at` is optional
/// (`#[serde(default, skip_serializing_if = "Option::is_none")]`), so we omit
/// it. This is the deliberate, bounded alternative to launching with `--trust`
/// (a folder-wide grant) or `--yolo`: we persist trust for *this specific
/// worktree*, and only ever add/flip its `trusted` line, preserving every other
/// folder's decision.
///
/// **Only trust worktrees Crow creates off a trusted base.** `SessionService`
/// seeds trust for `.work`/`.job` git worktrees (branched from a trusted base)
/// and the Manager's devRoot — never for a `.review` clone, whose working tree
/// is `gh repo clone` output at the PR author's head and is therefore
/// attacker-controlled. Trusting such a clone would arm a committed
/// `.grok/hooks/*.json` on launch; review clones fall back to Grok's own
/// folder-trust prompt (the human-gated path), and `prepareReviewClone`
/// additionally strips any committed `.grok/` as defense-in-depth (which also
/// covers a *local/dev* Grok build, where folder-trust is inert and everything
/// is trusted). So this seeder is safe *given that contract* — it does not
/// itself distinguish clone from worktree; the caller does.
///
/// `trusted_folders.toml` carries no secrets, so a plain atomic write is used
/// (unlike `CodexTrustSeeder`'s owner-only `config.toml`).
public enum GrokTrustSeeder {

    public enum Outcome: Equatable {
        /// The trust line was written/updated for the folder path.
        case seeded
        /// Every target path was already trusted; nothing written.
        case alreadyTrusted
        /// Read or write failed.
        case failed(String)
    }

    /// Ensure `<grok_home>/trusted_folders.toml` marks `projectPath` trusted
    /// before Grok launches there. Pass `trustStorePath` to target a different
    /// file (tests); `nil` uses the real store (honoring `$GROK_HOME`).
    @discardableResult
    public static func seedTrust(
        projectPath: String,
        trustStorePath: String? = nil
    ) -> Outcome {
        let tomlPath = trustStorePath ?? defaultStorePath()

        // Grok canonicalizes the workspace key before lookup, which may differ
        // from the path Crow launches with (symlinked dev roots). Trust both
        // spellings so the gate stays quiet regardless of which Grok resolves to.
        var projectPaths = [projectPath]
        let resolved = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().path
        if resolved != projectPath {
            projectPaths.append(resolved)
        }

        let fm = FileManager.default
        let dir = (tomlPath as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return .failed(error.localizedDescription)
        }

        var content = ""
        if let data = fm.contents(atPath: tomlPath) {
            // "Exists but not UTF-8" must not read as "" — that would truncate a
            // store holding the user's other folder decisions on the
            // read-modify-write. Refuse instead.
            guard let text = String(data: data, encoding: .utf8) else {
                return .failed("\(tomlPath) is not valid UTF-8; refusing to rewrite")
            }
            content = text
        }

        let original = content
        for path in projectPaths {
            content = upsertTrusted(content, folderPath: path)
        }

        if content == original {
            return .alreadyTrusted
        }

        do {
            try content.write(toFile: tomlPath, atomically: true, encoding: .utf8)
            return .seeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Store path

    /// `$GROK_HOME/trusted_folders.toml` when `GROK_HOME` is set and non-empty,
    /// otherwise `~/.grok/trusted_folders.toml`. Resolved through `GrokHome` — the
    /// one source of truth shared with the session-log collector (CROW-1098) — so
    /// the trust-seed and log paths never drift; the empty-var-is-unset guard lives
    /// there and mirrors `CodexTrustSeeder`.
    static func defaultStorePath() -> String {
        (GrokHome.path() as NSString).appendingPathComponent("trusted_folders.toml")
    }

    // MARK: - Minimal TOML editing

    /// Insert or update `[folders."<folderPath>"] trusted = true` inside
    /// `content`, preserving every other folder's decision. Merges into an
    /// existing table for this folder (flipping a stale `trusted = false`), or
    /// appends a fresh table when absent.
    static func upsertTrusted(_ content: String, folderPath: String) -> String {
        let header = "[folders.\"\(escapeTomlString(folderPath))\"]"
        var lines = content.components(separatedBy: "\n")

        // Locate this folder's table by its exact serialized header (Grok emits
        // the canonical `toml`-crate spelling, which is what `escapeTomlString`
        // reproduces). Bound it at the next table header.
        var sectionStart: Int? = nil
        var sectionEnd = lines.count
        for (i, raw) in lines.enumerated() {
            let trimmed = stripInlineComment(raw).trimmingCharacters(in: .whitespaces)
            if sectionStart == nil {
                if trimmed == header { sectionStart = i }
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                sectionEnd = i
                break
            }
        }

        if let start = sectionStart {
            // Update `trusted` in place if present, else insert after the header.
            for i in (start + 1)..<sectionEnd {
                if lineKey(of: lines[i]) == "trusted" {
                    lines[i] = "trusted = true"
                    return lines.joined(separator: "\n")
                }
            }
            lines.insert("trusted = true", at: start + 1)
            return lines.joined(separator: "\n")
        }

        // Absent — append a fresh table, separated by a blank line.
        if !content.isEmpty && !content.hasSuffix("\n") {
            lines.append("")
        }
        if let last = lines.last, !last.isEmpty {
            lines.append("")
        }
        lines.append(header)
        lines.append("trusted = true")
        return lines.joined(separator: "\n")
    }

    /// The bare `key` of a `key = value` TOML line, ignoring comments and
    /// blank/section lines. `nil` for anything else.
    private static func lineKey(of raw: String) -> String? {
        let trimmed = stripInlineComment(raw).trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("[") { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : String(key)
    }

    /// Strip a TOML end-of-line `# comment` outside a double-quoted string.
    private static func stripInlineComment(_ line: String) -> String {
        var inQuotes = false
        var escaped = false
        var out = ""
        for ch in line {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { out.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); out.append(ch); continue }
            if ch == "#" && !inQuotes { break }
            out.append(ch)
        }
        return out
    }

    /// Escape a string for a TOML **basic** (double-quoted) key/value. A path
    /// with a quote/backslash/control character would otherwise break the
    /// `[folders."…"]` header. Matches `CodexHookConfigWriter.escapeTomlString`.
    static func escapeTomlString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
