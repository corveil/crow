import Crypto
import CrowCore
import Foundation
import NIOCore

/// Web-access authentication for the daemon's HTTP/WS surface (CROW-593).
///
/// Model (see ADR/plan): auth is **opt-in** — with no web password configured the
/// prior behavior stands (only `WebSocketOriginGuard` gates). Once a password is
/// set:
///   - **local** (loopback peer, no `X-Forwarded-For`) → allowed, no login;
///   - **proxied** (loopback peer *with* `X-Forwarded-For`, i.e. a co-located TLS
///     proxy like `tailscale serve` / `ngrok`) → requires `X-Forwarded-Proto:
///     https` **and** a valid session cookie;
///   - anything else (a non-loopback direct peer, or proxied-not-https) → denied.
///
/// We trust `X-Forwarded-*` only from a loopback peer, so a direct client can't
/// forge them (it can't forge a loopback TCP peer). NOTE: this requires the proxy
/// to set `X-Forwarded-For` (Tailscale serve and ngrok do); a raw TCP forwarder
/// that omits it would look local — document the proxy requirement.

// MARK: - Password hashing (PBKDF2-HMAC-SHA256, RFC 8018)

enum PasswordHash {
    static let defaultIterations = 210_000   // OWASP 2023 guidance for PBKDF2-HMAC-SHA256
    static let saltBytes = 16
    static let keyBytes = 32
    private static let hLen = 32             // SHA-256 output

    /// Hash `password` with a fresh random salt into a storable `WebAuthConfig`.
    static func make(password: String, iterations: Int = defaultIterations) -> WebAuthConfig {
        let salt = randomBytes(saltBytes)
        let dk = pbkdf2(password: Array(password.utf8), salt: salt, iterations: iterations, keyLen: keyBytes)
        return WebAuthConfig(
            hashB64: Data(dk).base64EncodedString(),
            saltB64: Data(salt).base64EncodedString(),
            iterations: iterations)
    }

    /// Constant-time verify of a candidate password against a stored record.
    static func verify(password: String, record: WebAuthConfig) -> Bool {
        guard !record.hashB64.isEmpty, !record.saltB64.isEmpty, record.iterations > 0,
              let salt = Data(base64Encoded: record.saltB64),
              let expected = Data(base64Encoded: record.hashB64), !expected.isEmpty
        else { return false }
        let dk = pbkdf2(password: Array(password.utf8), salt: Array(salt),
                        iterations: record.iterations, keyLen: expected.count)
        return constantTimeEqual(dk, Array(expected))
    }

    /// PBKDF2-HMAC-SHA256 derived key of `keyLen` bytes.
    static func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int, keyLen: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        let blocks = max(1, (keyLen + hLen - 1) / hLen)
        var derived = [UInt8]()
        derived.reserveCapacity(blocks * hLen)
        for block in 1...blocks {
            var u = salt
            u.append(UInt8((block >> 24) & 0xff)); u.append(UInt8((block >> 16) & 0xff))
            u.append(UInt8((block >> 8) & 0xff)); u.append(UInt8(block & 0xff))
            var t = [UInt8](repeating: 0, count: hLen)
            var prev = u
            for _ in 0..<iterations {
                let mac = Array(HMAC<SHA256>.authenticationCode(for: prev, using: key))
                for i in 0..<hLen { t[i] ^= mac[i] }
                prev = mac
            }
            derived.append(contentsOf: t)
        }
        return Array(derived.prefix(keyLen))
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()   // CSPRNG on all supported platforms
        return (0..<n).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

// MARK: - Session store (in-memory bearer tokens)

/// Thread-safe token → expiry map. Tokens are random 256-bit hex strings, issued
/// on login, valid for `ttl`, cleared on daemon restart (re-login).
final class SessionStore: @unchecked Sendable {
    let ttl: TimeInterval
    private let lock = NSLock()
    private var tokens: [String: Date] = [:]

    init(ttl: TimeInterval = 7 * 24 * 3600) { self.ttl = ttl }

    func issue() -> String {
        let token = PasswordHash.randomBytes(32).map { String(format: "%02x", $0) }.joined()
        lock.lock(); defer { lock.unlock() }
        tokens[token] = Date().addingTimeInterval(ttl)
        return token
    }

    func isValid(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let expiry = tokens[token] else { return false }
        if expiry < Date() { tokens[token] = nil; return false }
        return true
    }

    func revoke(_ token: String?) {
        guard let token else { return }
        lock.lock(); defer { lock.unlock() }
        tokens[token] = nil
    }

    func prune() {
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        tokens = tokens.filter { $0.value >= now }
    }
}

// MARK: - Login rate limiter

/// Coarse global throttle on `/login` to slow brute force: at most `max` attempts
/// per `window`. Not per-IP (behind a proxy every attempt shares the peer); a
/// global ceiling is enough to make online guessing impractical for a strong
/// password.
final class LoginRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let max: Int
    private let window: TimeInterval
    private var hits: [Date] = []

    init(max: Int = 10, window: TimeInterval = 60) { self.max = max; self.window = window }

    /// Record an attempt; returns false when the ceiling for the window is hit.
    func allow(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-window)
        hits = hits.filter { $0 >= cutoff }
        guard hits.count < max else { return false }
        hits.append(now)
        return true
    }
}

// MARK: - Authorization

enum WebAuthGuard {
    static let cookieName = "crow_session"

    struct Decision: Equatable {
        let isAuthorized: Bool
        let reason: String
    }

    /// Authorize a request. `configProvider` is called lazily — only for the
    /// non-local path — so the common local case doesn't touch disk.
    static func authorize(
        remoteAddress: SocketAddress?,
        cookieHeader: String?,
        forwardedFor: String?,
        forwardedProto: String?,
        configProvider: () -> AppConfig?,
        sessions: SessionStore
    ) -> Decision {
        let peerIsLoopback = isLoopbackPeer(remoteAddress)
        let proxied = !(forwardedFor?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)

        // Local direct: loopback peer, no proxy headers → trusted, no config load.
        if peerIsLoopback && !proxied {
            return Decision(isAuthorized: true, reason: "local")
        }

        // Opt-in: with no web password set, the gate is inert (prior behavior —
        // the Origin guard alone applies). Enforced once a password exists.
        guard let webAuth = configProvider()?.webAuth, !webAuth.hashB64.isEmpty else {
            return Decision(isAuthorized: true, reason: "no web password — auth disabled")
        }

        // Password IS set. Only a loopback proxy (adds X-Forwarded-*) may reach
        // in; a direct non-loopback peer must go through the proxy.
        guard peerIsLoopback else {
            return Decision(isAuthorized: false, reason: "non-loopback peer — use an https proxy")
        }
        guard (forwardedProto ?? "").lowercased() == "https" else {
            return Decision(isAuthorized: false, reason: "proxied but not https")
        }
        let token = sessionToken(fromCookie: cookieHeader)
        return sessions.isValid(token)
            ? Decision(isAuthorized: true, reason: "valid session")
            : Decision(isAuthorized: false, reason: "no valid session")
    }

    /// Whether the peer is a loopback address (127.0.0.0/8, ::1, v4-mapped).
    static func isLoopbackPeer(_ address: SocketAddress?) -> Bool {
        guard let ip = address?.ipAddress?.lowercased() else { return false }
        if ip == "::1" || ip == "127.0.0.1" { return true }
        if ip.hasPrefix("127.") { return true }                 // 127.0.0.0/8
        if ip.hasPrefix("::ffff:127.") { return true }          // IPv4-mapped IPv6
        return false
    }

    /// Extract the session token from a `Cookie` header value.
    static func sessionToken(fromCookie header: String?) -> String? {
        guard let header else { return nil }
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            if kv[0].trimmingCharacters(in: .whitespaces) == cookieName {
                return kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func setCookieValue(token: String, ttl: TimeInterval) -> String {
        "\(cookieName)=\(token); HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=\(Int(ttl))"
    }
    static func clearCookieValue() -> String {
        "\(cookieName)=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0"
    }
}
