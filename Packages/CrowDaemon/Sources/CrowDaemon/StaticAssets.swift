import CrowTerminal
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
        router.get("/") { _, _ in webResponse("index.html", webDir: webDir) }
        router.get("/index.html") { _, _ in webResponse("index.html", webDir: webDir) }
        // Login page (CROW-593) — reachable without auth; the auth middleware
        // also serves it as the fallback for unauthenticated navigational GETs.
        router.get("/login") { _, _ in webResponse("login.html", webDir: webDir) }
        router.get("/app.css") { _, _ in webResponse("app.css", webDir: webDir) }
        router.get("/app.js") { _, _ in webResponse("app.js", webDir: webDir) }
        // Web Settings modal assets (CROW-581) — split out of app.css/app.js.
        router.get("/settings.css") { _, _ in webResponse("settings.css", webDir: webDir) }
        router.get("/settings.js") { _, _ in webResponse("settings.js", webDir: webDir) }
        router.get("/brand.svg") { _, _ in webResponse("brand.svg", webDir: webDir) }
        // Build info for the Settings → About tab, written by
        // scripts/generate-build-info.sh. 404s gracefully when absent (the daemon
        // stays buildable without it — CROW-581).
        router.get("/version.json") { _, _ in webResponse("version.json", webDir: webDir) }
        // Session-validity probe, gated by WebAuthMiddleware: 204 when the session
        // cookie is valid (or loopback), 401 when it isn't. The web UI polls this on
        // disconnect to tell "session expired" from "crowd is down" (CROW-593).
        router.get("/auth/check") { _, _ in Response(status: .noContent) }
        // The standalone single-terminal page from M1, kept for debugging.
        router.get("/terminal.html") { _, _ in webResponse("terminal.html", webDir: webDir) }

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
    /// fallback for unauthenticated navigational GETs (CROW-593).
    static func loginPage(webDir: String?) -> Response {
        webResponse("login.html", webDir: webDir)
    }

    /// Load a web UI file — from `webDir` on disk when set (live/hot-reload),
    /// otherwise from the daemon bundle's `web/` resource directory.
    private static func webResponse(_ name: String, webDir: String?) -> Response {
        if let webDir {
            let url = URL(fileURLWithPath: webDir).appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                return fileResponse(data, name: name)
            }
        }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "web"),
              let data = try? Data(contentsOf: url) else {
            return Response(status: .notFound)
        }
        return fileResponse(data, name: name)
    }

    private static func fileResponse(_ data: Data, name: String) -> Response {
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
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
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
