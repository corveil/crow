import Foundation

/// A parsed `MAJOR.MINOR.PATCH[-PRERELEASE]` version of a coding-agent CLI,
/// shared by the harness capability probes that gate a flag on an upstream
/// release — OpenCode's TUI `--auto` window (`OpenCodeLaunchArgs`) and Codex's
/// async-hook minimum (`CodexVersionProbe`). Hoisted into CrowCore when the
/// second probe needed it (CROW-999) so the comparison lives in one place.
///
/// Ordering follows semver precedence, **including** the rule that a
/// pre-release sorts below the release it precedes: `0.148.0-alpha.9 <
/// 0.148.0`. That is the whole point for a minimum-version gate. An alpha of
/// the target release is not the target release, and a capability that lands
/// partway through an alpha series (Codex async hooks landed in
/// `0.148.0-alpha.9`, not `alpha.1`) is only reliably present once the stable
/// ships — so "≥ 0.148.0" must reject every `0.148.0-*`.
///
/// Pre-release *identifiers* are compared as one opaque string rather than by
/// semver's dot-separated numeric/alphanumeric rules. Crow only ever asks "is
/// this at least X.Y.Z?", and every pre-release of `X.Y.Z` answers no however
/// the identifiers order among themselves — so the full rule would be
/// untested weight.
///
/// Build metadata (`+…`) is parsed off and discarded: semver excludes it from
/// precedence.
public struct AgentSemVer: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The `-…` suffix without its leading hyphen (`"alpha.9"`), or `nil` for
    /// a release build.
    public let preRelease: String?

    public init(_ major: Int, _ minor: Int, _ patch: Int, preRelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preRelease = preRelease
    }

    public static func < (lhs: AgentSemVer, rhs: AgentSemVer) -> Bool {
        let l = (lhs.major, lhs.minor, lhs.patch)
        let r = (rhs.major, rhs.minor, rhs.patch)
        if l != r { return l < r }
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil): return false
        case (nil, .some): return false   // a release outranks its pre-releases
        case (.some, nil): return true
        case let (.some(a), .some(b)): return a < b
        }
    }

    /// Parse a version from a **whole** token — the entire string must be the
    /// version, modulo an optional leading `v`.
    ///
    /// Whole-token matching is the point, not an accident. A "first
    /// `\d+\.\d+\.\d+` anywhere" scan happily reads `22.22.2` out of a path
    /// like `/Users/x/.nvm/versions/node/v22.22.2/bin/codex`, which real
    /// `--version` output can carry (a wrapper printing its own resolution, a
    /// warning line naming the binary). Anchoring on the token means such a
    /// path fails to parse instead of silently yielding a wrong — and possibly
    /// gate-passing — version.
    ///
    /// Returns `nil` for anything that isn't exactly three dot-separated
    /// non-empty digit runs, including values too large for `Int`.
    public static func parse(token: String) -> AgentSemVer? {
        var body = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }

        // Build metadata is not part of precedence — drop it first so a `-`
        // inside it can't be mistaken for the pre-release separator.
        if let plus = body.firstIndex(of: "+") { body = String(body[body.startIndex..<plus]) }

        var preRelease: String? = nil
        if let hyphen = body.firstIndex(of: "-") {
            let suffix = String(body[body.index(after: hyphen)...])
            guard !suffix.isEmpty else { return nil }
            preRelease = suffix
            body = String(body[body.startIndex..<hyphen])
        }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        return AgentSemVer(numbers[0], numbers[1], numbers[2], preRelease: preRelease)
    }

    /// The first whitespace-separated token of `text` that parses as a version.
    ///
    /// This is how a CLI's `--version` output is read: the banner shape varies
    /// (`codex-cli 0.141.0`, `opencode 1.18.4`) and may be preceded by warning
    /// lines, so scan for the first token that *is* a version rather than
    /// assuming a position. Combined with `parse(token:)`'s whole-token rule,
    /// a path or an error code in a preamble can't be misread as the version.
    public static func firstToken(in text: String) -> AgentSemVer? {
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            if let version = parse(token: String(token)) { return version }
        }
        return nil
    }

    /// `MAJOR.MINOR.PATCH[-PRERELEASE]`, for logs and diagnostics.
    public var displayString: String {
        let base = "\(major).\(minor).\(patch)"
        return preRelease.map { "\(base)-\($0)" } ?? base
    }
}
