import CrowTerminal
import Foundation
import Hummingbird
import NIOCore

/// Serves the browser terminal page (`/`) and the xterm.js 6.0.0 assets
/// (`/xterm/*`). The assets are streamed straight out of `CrowTerminal`'s
/// resource bundle, so the web UI reuses the exact same xterm build as the
/// macOS app instead of duplicating it (CROW-581).
enum StaticAssets {
    static func mount(on router: Router<BasicRequestContext>, indexHTML: ByteBuffer) {
        router.get("/") { _, _ -> Response in
            Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: indexHTML))
        }
        router.get("/xterm/:file") { _, context -> Response in
            // Basename-only guard against path traversal.
            guard let file = context.parameters.get("file"), isSafeAssetName(file) else {
                return Response(status: .badRequest)
            }
            guard let dir = BundledResources.xtermDirectoryURL else {
                return Response(status: .notFound)
            }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else {
                return Response(status: .notFound)
            }
            return Response(
                status: .ok,
                headers: [.contentType: contentType(for: file)],
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
    }

    /// Whether `name` is a safe single path component for `/xterm/*`: non-empty,
    /// no separators, no `..`. The router decodes percent-escapes before this
    /// runs, so `%2e%2e`/`%2f` are caught here (CROW-581 review).
    static func isSafeAssetName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..")
    }

    private static func contentType(for file: String) -> String {
        if file.hasSuffix(".js") { return "text/javascript; charset=utf-8" }
        if file.hasSuffix(".css") { return "text/css; charset=utf-8" }
        if file.hasSuffix(".html") { return "text/html; charset=utf-8" }
        return "application/octet-stream"
    }
}
