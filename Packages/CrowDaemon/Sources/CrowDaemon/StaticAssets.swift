import CrowTerminal
import Crypto
import Foundation
import Hummingbird
import NIOCore

/// Serves the web UI (`/`, `/app.css`, `/app.js`) from the daemon's own
/// resource bundle and the xterm.js 6.0.0 assets (`/xterm/*`) straight out of
/// `CrowTerminal`'s bundle — so the browser reuses the exact same xterm build
/// as the macOS app instead of duplicating it (CROW-581).
///
/// When `webDir` is set (`--web-dir` / `CROW_WEB_DIR`), the UI files are read
/// live from that source directory instead of the compiled bundle — edit +
/// refresh, no rebuild.
enum StaticAssets {
    static func mount(on router: Router<CrowHTTPContext>, webDir: String? = nil) {
        router.get("/") { req, _ in webResponse("index.html", webDir: webDir, request: req) }
        router.get("/index.html") { req, _ in webResponse("index.html", webDir: webDir, request: req) }
        // Login page (CROW-593) — reachable without auth; the auth middleware
        // also serves it as the fallback for unauthenticated navigational GETs.
        router.get("/login") { req, _ in webResponse("login.html", webDir: webDir, request: req) }
        router.get("/app.css") { req, _ in webResponse("app.css", webDir: webDir, request: req) }
        router.get("/app.js") { req, _ in webResponse("app.js", webDir: webDir, request: req) }
        // Web Settings modal assets (CROW-581) — split out of app.css/app.js.
        router.get("/settings.css") { req, _ in webResponse("settings.css", webDir: webDir, request: req) }
        router.get("/settings.js") { req, _ in webResponse("settings.js", webDir: webDir, request: req) }
        router.get("/brand.svg") { req, _ in webResponse("brand.svg", webDir: webDir, request: req) }
        // Build info for the Settings → About tab, written by
        // scripts/generate-build-info.sh. 404s gracefully when absent (the daemon
        // stays buildable without it — CROW-581).
        router.get("/version.json") { req, _ in webResponse("version.json", webDir: webDir, request: req) }
        // Session-validity probe, gated by WebAuthMiddleware: 204 when the session
        // cookie is valid (or loopback), 401 when it isn't. The web UI polls this on
        // disconnect to tell "session expired" from "crowd is down" (CROW-593).
        router.get("/auth/check") { _, _ in Response(status: .noContent) }
        // The standalone single-terminal page from M1, kept for debugging.
        router.get("/terminal.html") { req, _ in webResponse("terminal.html", webDir: webDir, request: req) }

        router.get("/xterm/:file") { _, context -> Response in
            // Basename-only guard against path traversal.
            guard let file = context.parameters.get("file"), isSafeAssetName(file) else {
                return Response(status: .badRequest)
            }
            guard let dir = BundledResources.xtermDirectoryURL,
                  let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else {
                return Response(status: .notFound)
            }
            return fileResponse(data, name: file)
        }
    }

    /// Whether `name` is a safe single path component for `/xterm/*`: non-empty,
    /// no separators, no `..`. The router decodes percent-escapes before this
    /// runs, so `%2e%2e`/`%2f` are caught here (CROW-581 review).
    static func isSafeAssetName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..")
    }

    /// The login page as a 200 response — used by the auth middleware as the
    /// fallback for unauthenticated navigational GETs (CROW-593). The `request`,
    /// when the caller has one, lets the response answer a conditional GET.
    static func loginPage(webDir: String?, request: Request? = nil) -> Response {
        webResponse("login.html", webDir: webDir, request: request)
    }

    /// Load a web UI file — from `webDir` on disk when set (live/hot-reload),
    /// otherwise from the daemon bundle's `web/` resource directory.
    private static func webResponse(_ name: String, webDir: String?, request: Request? = nil) -> Response {
        if let webDir {
            let url = URL(fileURLWithPath: webDir).appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                return fileResponse(data, name: name, request: request, revalidate: true)
            }
        }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "web"),
              let data = try? Data(contentsOf: url) else {
            return Response(status: .notFound)
        }
        return fileResponse(data, name: name, request: request, revalidate: true)
    }

    private static func fileResponse(_ data: Data, name: String,
                                     request: Request? = nil,
                                     revalidate: Bool = false) -> Response {
        var headers: HTTPFields = [
            .contentType: contentType(for: name),
            .xContentTypeOptions: "nosniff",
        ]
        // Content-Security-Policy on the main app page. It renders provider-sourced
        // strings (ticket/PR titles, branches, authors), so a future innerHTML slip
        // must not be able to pull external script or exfiltrate. Scoped to
        // index.html — login.html carries an inline script and terminal.html is a
        // debug-only page. `style-src 'unsafe-inline'` covers xterm's injected
        // renderer styles; blob:/data: cover its canvas/image atlases; `connect-src
        // 'self'` covers the same-origin /rpc + /terminal WebSockets (CROW-593 review).
        if appliesCSP(to: name) {
            headers[.contentSecurityPolicy] = contentSecurityPolicy
        }
        // The app's own HTML/JS/CSS must always be revalidated so a fresh build lands
        // on a normal reload instead of the browser running a stale heuristically
        // cached `app.js` (CROW-1024). `no-cache` = "may cache, but revalidate before
        // reuse"; the strong ETag lets that revalidation return an empty 304 when the
        // bytes are unchanged, so it stays cheap. The `/xterm/*` vendor bundle keeps
        // its long-lived heuristic cache (revalidate == false).
        if revalidate {
            let tag = strongETag(for: data)
            headers[.cacheControl] = "no-cache"
            headers[.eTag] = tag
            if let request, ifNoneMatch(request, matches: tag) {
                return Response(status: .notModified, headers: headers)
            }
        }
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// A strong ETag for `data`: the hex SHA-256 of the bytes, quoted. Content-based
    /// (not mtime/path), so identical bytes validate identically across installs and
    /// between the `webDir` and bundle sources (CROW-1024).
    private static func strongETag(for data: Data) -> String {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\"\(hex)\""
    }

    /// Whether the request's `If-None-Match` matches `etag` (or is `*`). Handles a
    /// comma-separated list and an optional `W/` weak-validator prefix on each
    /// candidate, per RFC 9110 §13.1.2.
    static func ifNoneMatch(_ request: Request, matches etag: String) -> Bool {
        guard let header = request.headers[.ifNoneMatch] else { return false }
        if header.trimmingCharacters(in: .whitespaces) == "*" { return true }
        for raw in header.split(separator: ",") {
            var candidate = raw.trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix("W/") { candidate = String(candidate.dropFirst(2)) }
            if candidate == etag { return true }
        }
        return false
    }

    /// Whether the Content-Security-Policy is attached to `name`. Scoped to the
    /// main app page: `login.html` carries an inline script and `terminal.html`
    /// is a debug-only page, so neither gets it (CROW-593 review).
    static func appliesCSP(to name: String) -> Bool { name == "index.html" }

    static let contentSecurityPolicy = [
        "default-src 'self'",
        // `wasm-unsafe-eval` lets xterm's image addon compile its Sixel-decoder
        // WebAssembly without enabling arbitrary `eval` (CROW-593 review).
        "script-src 'self' 'wasm-unsafe-eval'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "font-src 'self'",
        "connect-src 'self'",
        "worker-src 'self' blob:",
        "object-src 'none'",
        "base-uri 'none'",
        "frame-ancestors 'none'",
    ].joined(separator: "; ")

    private static func contentType(for file: String) -> String {
        if file.hasSuffix(".js") { return "text/javascript; charset=utf-8" }
        if file.hasSuffix(".css") { return "text/css; charset=utf-8" }
        if file.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if file.hasSuffix(".svg") { return "image/svg+xml" }
        if file.hasSuffix(".json") { return "application/json; charset=utf-8" }
        return "application/octet-stream"
    }
}
