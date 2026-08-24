import Foundation

/// How Grok Build names its per-working-directory session directory, and the
/// inverse (CROW-1098). Grok pools every session for a given worktree under
/// `~/.grok/sessions/<url-encoded-abs-cwd>/`, where the directory name is the
/// absolute worktree path percent-encoded: `/` → `%2F`, unreserved characters
/// (`A–Z a–z 0–9 - . _ ~`) left as-is. So
/// `/Users/j/Dev/acme-12` → `%2FUsers%2Fj%2FDev%2Facme-12`.
///
/// This is Grok's analogue of Claude's `posixPathSlug` (`-`-replacement), but it
/// is **reversible** — the collector encodes a worktree path to find its session
/// directory, and the backfill scanner decodes a directory name back to the cwd
/// it ran in. Because the directory name *is* the cwd, attribution is exact by
/// construction: no per-file `cwdFilter` head-read is needed, and a
/// wrongly-encoded name simply resolves to a directory that doesn't exist
/// (nothing collected) rather than to another worktree's transcripts (nothing
/// misattributed).
///
/// It lives in CrowCore — not the Grok adapter — so both `GrokAgent.logSources`
/// (CrowGrok) and `BackfillScanner` (CrowCore, which can't import CrowGrok) share
/// the one encode/decode, the same reason `AgentLogSource.posixPathSlug` lives
/// here.
///
/// ⚠️ **Version-pinned re-check target.** The percent-encoding scheme was
/// verified against a real `~/.grok/sessions` tree (#1090, 2026-08-21): dashes
/// are preserved, `/` becomes `%2F`, so Grok encodes the RFC 3986 *unreserved*
/// set (it is not `percent_encoding`'s `NON_ALPHANUMERIC`, which would escape the
/// dashes). grok-build is a closed upstream mirror, so re-confirm this on a Grok
/// version bump — the same re-check discipline as `GrokLaunchArgs`.
public enum GrokSessionDir {
    /// The RFC 3986 unreserved set — the characters Grok leaves un-escaped in the
    /// encoded directory name. Everything else (notably `/`) is percent-encoded.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    /// Encode an absolute worktree path to Grok's session-directory name. Foundation
    /// emits **uppercase** hex (`%2F`, not `%2f`), matching Grok's own output.
    public static func encode(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
    }

    /// Decode a Grok session-directory name back to the absolute cwd it stands for.
    /// Returns `nil` only for a malformed percent-sequence (which a real Grok
    /// directory never has). A decoded value that isn't an absolute path is still
    /// returned verbatim — the caller (the backfill scanner) treats a non-worktree
    /// cwd as a low-confidence orphan rather than erroring.
    public static func decode(_ name: String) -> String? {
        name.removingPercentEncoding
    }
}
