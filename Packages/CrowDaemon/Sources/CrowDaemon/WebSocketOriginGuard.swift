import Foundation

/// Cross-site WebSocket hijacking defense (CROW-581 review).
///
/// Browsers do **not** apply the same-origin policy to *outbound* WebSocket
/// connections, so binding `crowd` to loopback does not stop a malicious page
/// the user happens to be visiting from opening `ws://127.0.0.1:<port>/terminal`
/// and receiving an interactive shell (or driving `/rpc`, which shells out to
/// git). We therefore reject the upgrade unless the request's `Origin` is:
///   - absent/empty — a native, non-browser client (the `crow` CLI, `websocat`,
///     a test harness); browsers always send `Origin` on a WS handshake; or
///   - a loopback host — the only origins that can legitimately have served the
///     bundled web UI in a default deployment.
///
/// Remote, authenticated browser access (the eventual goal of the epic) needs a
/// real token and is an explicit follow-up; until then the web UI is a
/// loopback-only tool.
enum WebSocketOriginGuard {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// Whether a WebSocket upgrade carrying `origin` should be allowed, given
    /// the daemon's own `boundHost` (`--host`).
    ///
    /// Allowed origins: absent/empty (native clients), a loopback host, or a
    /// host equal to `boundHost` — the latter lets a specific non-loopback bind
    /// (e.g. a Tailscale/LAN IP) serve its own web UI while still rejecting
    /// genuinely cross-site origins. A wildcard bind (`0.0.0.0`/`::`) matches no
    /// single concrete host, so it stays loopback-only.
    static func isAllowedOrigin(_ origin: String?, boundHost: String = "127.0.0.1") -> Bool {
        guard let origin, !origin.isEmpty else { return true }  // native (non-browser) client
        guard let host = originHost(origin) else { return false }
        if loopbackHosts.contains(host) { return true }
        let bound = boundHost.lowercased()
        return bound != "0.0.0.0" && bound != "::" && host == bound
    }

    /// Host component of an `Origin` value (`scheme://host[:port]`), lowercased
    /// with IPv6 brackets stripped. Returns nil for unparseable origins —
    /// including the opaque `"null"` origin sandboxed frames send — which are
    /// then rejected.
    static func originHost(_ origin: String) -> String? {
        guard let host = URL(string: origin)?.host, !host.isEmpty else { return nil }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }

    /// Whether `host` (a daemon `--host` bind value) is a loopback address.
    /// `0.0.0.0` is **not** loopback, so binding it trips the daemon's warning.
    static func isLoopbackHost(_ host: String) -> Bool {
        loopbackHosts.contains(host.lowercased())
    }
}

/// Bounds concurrent `/terminal` connections so a flood of upgrades can't spawn
/// unbounded PTYs + `tmux attach` clients and exhaust file descriptors
/// (CROW-581 review). A spike-appropriate ceiling; a real deployment would tune
/// or replace this alongside auth.
final class TerminalConnectionLimiter: @unchecked Sendable {
    static let shared = TerminalConnectionLimiter(max: 16)

    private let lock = NSLock()
    private let max: Int
    private var count = 0

    init(max: Int) { self.max = max }

    /// Reserve a slot; returns false when the ceiling is already reached.
    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < max else { return false }
        count += 1
        return true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        if count > 0 { count -= 1 }
    }
}
