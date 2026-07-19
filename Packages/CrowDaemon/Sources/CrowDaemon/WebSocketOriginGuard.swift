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
/// Remote browser access over a non-loopback bind is allowed for
/// private-network origins (LAN/tailnet) but remains **unauthenticated** — a
/// loud startup warning covers that, and real token auth is an explicit
/// follow-up. Public cross-site origins are always rejected.
enum WebSocketOriginGuard {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// Whether a WebSocket upgrade carrying `origin` should be allowed, given
    /// the daemon's own `boundHost` (`--host`).
    ///
    /// Allowed origins: absent/empty (native clients), a loopback host, a host
    /// equal to `boundHost` (a specific non-loopback bind serving its own web
    /// UI), or — when bound to a wildcard (`0.0.0.0`/`::`) — any private-network
    /// host (LAN/tailnet), since the browser may reach the daemon via any local
    /// interface. Public cross-site origins (e.g. `evil.com`, public IPs) are
    /// always rejected. Non-loopback access stays unauthenticated (warned at
    /// startup); real token auth is a follow-up.
    static func isAllowedOrigin(
        _ origin: String?,
        boundHost: String = "127.0.0.1",
        forwardedHost: String? = nil,
        peerIsLoopback: Bool = false
    ) -> Bool {
        guard let origin, !origin.isEmpty else { return true }  // native (non-browser) client
        guard let host = originHost(origin) else { return false }
        if loopbackHosts.contains(host) { return true }
        // Behind a trusted local reverse proxy (`tailscale serve` / ngrok): the
        // browser's Origin is the proxy's public hostname — e.g. a MagicDNS
        // `*.ts.net` name — never a private-IP literal, so the IP-literal checks
        // below can't recognize it. The proxy reports the host it served via
        // `X-Forwarded-Host`, and a *same-origin* upgrade has `Origin` host equal
        // to it. We honor that header only from a loopback peer — the same trust
        // assumption `WebAuthGuard` makes — so a direct (non-loopback) client
        // can't forge it, and a cross-site page routed through the proxy carries a
        // different Origin than the forwarded host and is still rejected (CROW-593).
        if peerIsLoopback, let forwarded = forwardedHostName(forwardedHost), host == forwarded {
            return true
        }
        let bound = boundHost.lowercased()
        if bound == "0.0.0.0" || bound == "::" {
            // A wildcard bind can be reached via many local interfaces, each
            // sending a different Origin, so we can't match a single host. Trust
            // private-network origins and still reject public cross-site ones.
            return isPrivateHost(host)
        }
        return host == bound
    }

    /// Whether `host` is a loopback or private-network IPv4 literal
    /// (RFC1918 + CGNAT/Tailscale + link-local). Public hostnames and public IPs
    /// return false — so `evil.com` and `8.8.8.8` are rejected.
    static func isPrivateHost(_ host: String) -> Bool {
        if loopbackHosts.contains(host) { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let octets = try? parts.map({ part -> Int in
            guard let value = Int(part), (0...255).contains(value) else { throw HostParseError.notAnOctet }
            return value
        }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true               // 10.0.0.0/8
        case (192, 168): return true            // 192.168.0.0/16
        case (172, 16...31): return true        // 172.16.0.0/12
        case (169, 254): return true            // 169.254.0.0/16 link-local
        case (100, 64...127): return true       // 100.64.0.0/10 CGNAT (Tailscale)
        default: return false
        }
    }

    private enum HostParseError: Error { case notAnOctet }


    /// Host component of an `Origin` value (`scheme://host[:port]`), lowercased
    /// with IPv6 brackets and any trailing FQDN dot stripped. Returns nil for
    /// unparseable origins — including the opaque `"null"` origin sandboxed frames
    /// send — which are then rejected.
    static func originHost(_ origin: String) -> String? {
        guard let host = URL(string: origin)?.host, !host.isEmpty else { return nil }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized.hasSuffix(".") ? String(normalized.dropLast()) : normalized
    }

    /// Host from an `X-Forwarded-Host` value — the first entry when a proxy chain
    /// sends a comma list — normalized like `originHost` (port/brackets/trailing
    /// dot stripped, lowercased). Returns nil when absent/empty, so a request with
    /// no trusted proxy falls through to the caller's normal origin checks.
    static func forwardedHostName(_ value: String?) -> String? {
        guard let first = value?.split(separator: ",").first
                .map({ $0.trimmingCharacters(in: .whitespaces) }), !first.isEmpty
        else { return nil }
        return originHost("http://\(first)")
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
