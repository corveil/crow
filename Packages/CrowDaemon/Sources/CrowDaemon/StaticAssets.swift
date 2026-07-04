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
    static func mount(on router: Router<BasicRequestContext>, webDir: String? = nil) {
        router.get("/") { _, _ in webResponse("index.html", webDir: webDir) }
        router.get("/index.html") { _, _ in webResponse("index.html", webDir: webDir) }
        router.get("/app.css") { _, _ in webResponse("app.css", webDir: webDir) }
        router.get("/app.js") { _, _ in webResponse("app.js", webDir: webDir) }
        router.get("/brand.svg") { _, _ in webResponse("brand.svg", webDir: webDir) }
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
        Response(
            status: .ok,
            headers: [.contentType: contentType(for: name)],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private static func contentType(for file: String) -> String {
        if file.hasSuffix(".js") { return "text/javascript; charset=utf-8" }
        if file.hasSuffix(".css") { return "text/css; charset=utf-8" }
        if file.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if file.hasSuffix(".svg") { return "image/svg+xml" }
        return "application/octet-stream"
    }
}
