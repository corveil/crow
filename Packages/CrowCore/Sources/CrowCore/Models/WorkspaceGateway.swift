import Foundation

/// Per-workspace (or per-Manager) AI gateway configuration. When present, the
/// `claude` launches it applies to inherit `ANTHROPIC_BASE_URL` (from `baseURL`)
/// and `ANTHROPIC_CUSTOM_HEADERS` (from `customHeaders`, serialized to
/// newline-separated `Name: Value` lines). When absent, those env vars are
/// explicitly unset before launch so a global `~/.zshrc` export — or a sibling
/// workspace's gateway — doesn't bleed in (CROW-402).
///
/// A header value may be a plaintext string or a secret reference. `op://…`
/// references are resolved at launch via the 1Password CLI (`op read`) so the
/// secret never lands at rest in `config.json`; any other value is treated
/// literally (plaintext — stored in `config.json`, so warn in the UI).
public struct WorkspaceGateway: Codable, Sendable, Equatable {
    public var baseURL: String
    public var customHeaders: [String: String]

    public init(baseURL: String, customHeaders: [String: String]) {
        self.baseURL = baseURL
        self.customHeaders = customHeaders
    }

    /// Whether this gateway has anything to apply. A gateway whose `baseURL` is
    /// blank and whose `customHeaders` is empty is treated as "no gateway".
    public var isEmpty: Bool {
        baseURL.trimmingCharacters(in: .whitespaces).isEmpty && customHeaders.isEmpty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBaseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        let decodedHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]

        // Reject a half-filled block at parse time (CROW-402): a baseURL with no
        // headers can't authenticate against the gateway, and headers with no
        // baseURL have nothing to attach to. Both-empty is allowed (it just means
        // "no gateway"); both-present is the valid case.
        let hasBaseURL = !decodedBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        let hasHeaders = !decodedHeaders.isEmpty
        if hasBaseURL != hasHeaders {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "gateway must set both baseURL and customHeaders, or neither (got baseURL: \(hasBaseURL ? "present" : "empty"), customHeaders: \(hasHeaders ? "present" : "empty"))"
                )
            )
        }

        baseURL = decodedBaseURL
        customHeaders = decodedHeaders
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL, customHeaders
    }
}

extension WorkspaceGateway {
    /// Parse a multiline `Name: Value` editor string into a header map. Blank
    /// lines are ignored; each line's first `:` splits name from value. Used by
    /// the Settings UI so a free-text editor maps to the `customHeaders` dict.
    public static func parseHeaderLines(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result[name] = value
        }
        return result
    }

    /// Render a header map as a multiline `Name: Value` editor string (sorted by
    /// name for stable display).
    public static func headerLines(from headers: [String: String]) -> String {
        headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    /// Whether a header *value* was stored with literal surrounding quote
    /// characters — a shell-quoting slip (`--header 'X-Api-Key: "Bearer sk-…"'`)
    /// that nothing downstream notices (CROW-969). ``GatewayResolver/serializeHeaders(_:)``
    /// interpolates the value verbatim and `ClaudeLaunchArgs.gatewayEnvPrefix`
    /// shell-quotes the whole header line, so the stray quotes reach the gateway
    /// inside `ANTHROPIC_CUSTOM_HEADERS` and it rejects the request — surfacing to
    /// the user as a bare "API error" that names nothing actionable.
    ///
    /// Trimmed first, because the web path stores whatever the browser sent
    /// (`SecretRoutes.buildGateway` filters on trimmed *keys* only, never values).
    ///
    /// A blank or whitespace-only value is **not** wrapped. Blank is the "keep the
    /// secret already stored" signal that `SecretRoutes.mergingPreservedHeaders`
    /// resolves, so treating it as malformed would break every base-URL-only edit.
    ///
    /// Two characters are required so a lone `"` is not read as matching itself,
    /// and both ends must carry the *same* delimiter so `"abc'` — no recognizable
    /// shell slip — passes rather than inventing a rule we can't defend.
    ///
    /// Deliberately **not** enforced in ``init(from:)``: a config already on disk
    /// carrying this mistake must still decode. A decode failure makes
    /// `ConfigStore.loadConfig` return nil, and the next write then replaces every
    /// workspace, job and credential with defaults (the review-Red on #623, noted
    /// at `SecretRoutes.mergingPreservedHeaders`). Writes are guarded instead, and
    /// values already stored are warned about at launch by `GatewayResolver`.
    public static func isQuoteWrapped(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last
        else { return false }
        return (first == "\"" || first == "'") && first == last
    }

    /// Whether a header *name* carries a quote character a shell left behind.
    ///
    /// Catches the slip ``isQuoteWrapped(_:)`` structurally cannot see: quoting the
    /// whole pair (`--header '"X-Api-Key: sk-…"'`) puts one quote on the name and
    /// the other on the value, so neither half is individually wrapped.
    ///
    /// `"` is rejected anywhere in the name — RFC 9110's `field-name` is a `token`
    /// and `tchar` excludes `"` entirely, so a name containing one can never be a
    /// valid HTTP header whatever the author intended. `'` **is** a legal `tchar`,
    /// so it is rejected only in leading position, where no real header name has
    /// ever put one.
    ///
    /// Deliberately not caught: a *trailing* `'` (legal, and not a recognizable
    /// quoting artifact), and full RFC 9110 token validation — spaces, control
    /// characters and the like. Validation guards new writes only and a stored
    /// config is never re-validated, so broadening the grammar would reject
    /// someone re-saving an untouched, working header for a reason unrelated to
    /// the quoting slip this rule exists for.
    public static func headerNameHasStrayQuote(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("\"") { return true }
        return trimmed.first == "'"
    }
}

extension WorkspaceGateway {
    /// A copy of this gateway with any header carrying `oldSecret` rewritten to
    /// `newSecret`, or `self` unchanged when it carries no such value
    /// (corveil/crow#1124).
    ///
    /// A gateway derived from a Corveil org embeds the org's `sk-citadel-…` key
    /// *inline* as its ``CorveilConnection/gatewayAPIKeyHeader`` value — there is no
    /// live link back to the org — so when that key is rotated the stored gateway
    /// keeps authenticating with the revoked value until it is rewritten here. The
    /// same header is what `LogSyncCollector` reads for the upload credential, so one
    /// rewrite propagates the rotation to both the AI-gateway header and the
    /// log-upload credential.
    ///
    /// Matching is by header **value**, not name: the secret is high-entropy and
    /// unique to the key, so this also catches a manual gateway that stored the same
    /// key under a differently-named header (mirroring
    /// ``LogSyncCollector``'s multi-name credential lookup). A blank `oldSecret`, or
    /// one equal to `newSecret`, is a no-op — nothing to propagate, and matching an
    /// empty value would rewrite unrelated blank headers.
    public func rewritingGatewayKey(from oldSecret: String, to newSecret: String) -> WorkspaceGateway {
        guard !oldSecret.isEmpty, oldSecret != newSecret,
              customHeaders.values.contains(oldSecret)
        else { return self }
        var headers = customHeaders
        for (name, value) in headers where value == oldSecret { headers[name] = newSecret }
        return WorkspaceGateway(baseURL: baseURL, customHeaders: headers)
    }
}
