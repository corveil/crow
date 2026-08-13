import Crypto
import CrowCore
import CrowIPC
import Foundation

/// Minting and verification of MCP bearer tokens (CROW-1004).
///
/// Sits beside ``PasswordHash`` because this is where swift-crypto is a dependency,
/// and deliberately does *not* reuse it.
///
/// ### Why SHA-256 here and PBKDF2 there
///
/// `PasswordHash` protects a **human-chosen password**: low entropy, so the defence
/// is to make each guess expensive — 210 000 PBKDF2 iterations. That cost is paid
/// once per login.
///
/// An MCP token is 32 bytes straight from a CSPRNG that we generate. Guessing it is
/// 2²⁵⁶ work no matter how the hash is computed, so iterations buy nothing — while
/// costing plenty, because a token is verified on **every MCP request** rather than
/// once per session. Running a deliberately slow KDF per request would be a
/// self-inflicted denial of service. This is the same reasoning behind GitHub
/// personal access tokens, which are also fast-hashed.
///
/// No salt, for the same reason: salting defeats precomputation against low-entropy
/// inputs, and there is nothing to precompute against a 256-bit random secret.
///
/// Comparison is still constant-time — the entropy argument is about the *cost of
/// guessing*, not about leaking the answer through timing.
enum MCPTokenStore {

    /// Human-visible prefix. Makes a leaked token greppable in logs and CI output,
    /// and lets secret scanners recognize it.
    static let tokenPrefix = "crow_mcp_"

    /// Bytes of entropy in the token body.
    static let tokenBytes = 32

    /// How many characters of the body are stored in the clear for display. 8
    /// base64url characters is 48 bits — enough to tell two tokens apart in a
    /// listing, nowhere near enough to reconstruct the remaining 208.
    static let displayPrefixLength = 8

    /// A freshly minted token: the record to persist and the plaintext to hand back
    /// exactly once.
    struct Minted {
        let record: MCPTokenRecord
        /// The only time this value exists. Never persisted, never logged.
        let plaintext: String
    }

    /// Mint a token granting `scopes`, expiring at `expiresAt` (nil = never).
    static func mint(
        name: String,
        scopes: [MCPScope],
        expiresAt: Date?,
        now: Date = Date()
    ) -> Minted {
        let body = base64URL(PasswordHash.randomBytes(tokenBytes))
        let plaintext = tokenPrefix + body
        return Minted(
            record: MCPTokenRecord(
                name: name.trimmingCharacters(in: .whitespaces),
                prefix: String(body.prefix(displayPrefixLength)),
                hashB64: hash(plaintext),
                scopes: scopes.sorted(),
                createdAt: now,
                expiresAt: expiresAt),
            plaintext: plaintext)
    }

    /// Base64 SHA-256 of the whole token string, prefix included.
    static func hash(_ token: String) -> String {
        Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString()
    }

    /// The scopes `token` confers, or an empty set when it matches nothing, is
    /// expired, or is malformed.
    ///
    /// **Every** candidate is compared even after a match, so the work done is a
    /// function of how many tokens exist rather than of which one matched — a loop
    /// that returned early would let a caller learn a token's position in the list
    /// from response timing. That is a weak signal, but the fix costs nothing.
    static func scopes(
        for token: String,
        in records: [MCPTokenRecord],
        now: Date = Date()
    ) -> Set<MCPScope> {
        guard !token.isEmpty else { return [] }
        let candidate = hash(token)
        var granted: Set<MCPScope> = []
        for record in records {
            let matches = PasswordHash.constantTimeEqual(
                Array(candidate.utf8), Array(record.hashB64.utf8))
            if matches {
                granted = record.grantedScopes(now: now)
            }
        }
        return granted
    }

    /// Extract the credential from an `Authorization` header.
    ///
    /// Only the `Bearer` scheme, matched case-insensitively as RFC 9110 requires.
    static func bearerToken(fromAuthorization header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let scheme = "bearer "
        guard trimmed.count > scheme.count,
              trimmed.prefix(scheme.count).lowercased() == scheme
        else { return nil }
        let value = String(trimmed.dropFirst(scheme.count)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// URL-safe base64 with the padding removed, so the token is one word in a shell,
    /// a URL, and an environment variable.
    private static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
