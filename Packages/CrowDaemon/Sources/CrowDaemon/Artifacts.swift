import Foundation
import CrowCore
import HTTPTypes
import Hummingbird
import NIOCore

/// Serves per-session generated images ("artifacts") from an ephemeral scratch
/// dir outside any git worktree — `$TMPDIR/crow/artifacts/<sessionID>/` — so a
/// client can view a diagram/screenshot an agent dropped there (CROW-593).
///
/// Read-only and hard-sandboxed: the session segment must be a real UUID and
/// the file must be a bare image name (no separators, no `..`, allowed
/// extension only). Combined with the daemon's loopback-only bind, nothing
/// outside this scratch tree is reachable.
enum Artifacts {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg"]

    /// Extensions accepted for *dropped* images (drag-and-drop into the composer,
    /// #644). Deliberately a subset of `imageExtensions`: SVG is script-bearing
    /// and not a raster the agents consume, so it's kept out of the input path.
    static let uploadableImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// Cap for a single dropped image (10 MB). Screenshots blow past the 1 MB
    /// WebSocket frame limit, which is why uploads take this dedicated HTTP route
    /// rather than the `/rpc` or `/terminal` sockets.
    static let maxUploadBytes = 10 * 1024 * 1024

    /// A session's dir, or nil if `sessionID` isn't a valid UUID (traversal guard).
    /// Shares `CrowCore.ArtifactPaths` with the terminal-env injection so the
    /// serve path and the write path can't drift.
    static func dir(sessionID: String) -> URL? {
        guard let uuid = UUID(uuidString: sessionID) else { return nil }
        return ArtifactPaths.dir(sessionID: uuid)
    }

    /// Image files in a session's dir, newest first.
    static func list(sessionID: String) -> [(name: String, size: Int, mtime: Date)] {
        guard let dir = dir(sessionID: sessionID) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url -> (String, Int, Date)? in
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url.lastPathComponent, v?.fileSize ?? 0,
                    v?.contentModificationDate ?? Date(timeIntervalSince1970: 0))
        }.sorted { $0.2 > $1.2 }
    }

    /// Mount `GET /artifacts/:session/:file` (view) and `POST /artifacts/:session`
    /// (drop an image into the composer, #644). Both sit behind `WebAuthMiddleware`;
    /// the write side additionally requires a same-origin request (anti-CSRF).
    static func mount(on router: Router<CrowHTTPContext>, boundHost: String) {
        router.get("/artifacts/:session/:file") { _, context -> Response in
            guard let session = context.parameters.get("session"),
                  let dir = dir(sessionID: session),
                  let file = context.parameters.get("file"),
                  isSafeImageName(file) else {
                return Response(status: .badRequest)
            }
            // Resolve symlinks and require the final path stay inside `dir` —
            // otherwise a planted `shot.png` → `~/.claude/config.json` symlink
            // would leak secrets that strippedForTransport keeps off every other
            // transport (review Yellow / CROW-593).
            let candidate = dir.appendingPathComponent(file)
            guard let resolved = resolvedPathInside(dir: dir, file: candidate) else {
                return Response(status: .notFound)
            }
            guard let data = try? Data(contentsOf: resolved) else {
                return Response(status: .notFound)
            }
            var headers: HTTPFields = [.contentType: contentType(for: file), .cacheControl: "no-store"]
            // SVG can carry inline <script>; served same-origin it would run in
            // the daemon origin on direct navigation and could drive /rpc. Force a
            // download so it can never render as a top-level document (review).
            if (file as NSString).pathExtension.lowercased() == "svg" {
                headers[.contentDisposition] = "attachment"
            }
            return Response(
                status: .ok,
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }

        // Write side of the same scratch dir: a dropped image is stored here so
        // the agent (running on the host) can read it at an absolute path, and it
        // shows up in the client's Artifacts panel too (#644). The middleware
        // already requires a valid session; the Origin check blocks a cross-site
        // page from driving an upload+inject via the ambient cookie.
        router.post("/artifacts/:session") { request, context -> Response in
            guard WebSocketOriginGuard.isAllowedOrigin(
                request.headers[.origin],
                boundHost: boundHost,
                forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
                peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress)) else {
                return Response(status: .forbidden)
            }
            guard let session = context.parameters.get("session"),
                  let dir = dir(sessionID: session) else {
                return Response(status: .badRequest)
            }
            let filename = request.headers[HTTPField.Name("x-filename")!]
                .flatMap { $0.removingPercentEncoding ?? $0 }
            guard let ext = uploadExtension(
                contentType: request.headers[.contentType], filename: filename) else {
                return Response(status: .init(code: 415)) // Unsupported Media Type
            }
            // `collect(upTo:)` throws when the body exceeds the cap → 413.
            guard let buffer = try? await request.body.collect(upTo: maxUploadBytes) else {
                return Response(status: .init(code: 413)) // Content Too Large
            }
            let data = Data(buffer.readableBytesView)
            guard !data.isEmpty else { return Response(status: .badRequest) }
            let name = sanitizedUploadName(filename: filename, ext: ext)
            guard isSafeImageName(name) else { return Response(status: .badRequest) }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            } catch {
                return Response(status: .internalServerError)
            }
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            return json([
                "name": name,
                "path": dir.appendingPathComponent(name).path,
                "url": "/artifacts/\(session)/\(encoded)",
            ])
        }
    }

    /// A bare image filename: non-empty, no separators, no `..`, allowed ext.
    /// The router percent-decodes before this runs, so `%2e%2e`/`%2f` are caught.
    static func isSafeImageName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..")
            && imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Resolve `file` (following symlinks) and return it only when the final
    /// path is still under `dir`. Rejects dangling / escaping symlinks.
    static func resolvedPathInside(dir: URL, file: URL) -> URL? {
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
        // Exact match (file is the dir itself — shouldn't happen) or a child.
        guard resolved == root || resolved.hasPrefix(root + "/") else { return nil }
        // The resolved path must still exist as a regular file (not a dir).
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: resolved)
    }

    private static func contentType(for file: String) -> String {
        switch (file as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Upload helpers (#644)

    /// Resolve a safe, uploadable image extension for a dropped file: the
    /// filename's own extension when it's a raster we accept, else derived from
    /// the `Content-Type` media type. `nil` (→ 415) for anything else (incl. SVG,
    /// PDFs, text). Filename wins so an `image/*` body with a real `.gif` name
    /// keeps `gif` rather than a content-type guess.
    static func uploadExtension(contentType: String?, filename: String?) -> String? {
        if let filename {
            let ext = (filename as NSString).pathExtension.lowercased()
            if uploadableImageExtensions.contains(ext) { return ext }
        }
        // Media type only — strip any `; charset=…`/params.
        guard let media = contentType?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        switch media {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return nil
        }
    }

    /// A collision-free, traversal-proof name for a dropped image:
    /// `drop-<8hex>-<sanitized-stem>.<ext>`. The stem keeps only
    /// `[A-Za-z0-9_-]` from the original filename (spaces/slashes/dots/`..`
    /// dropped), so the result always satisfies ``isSafeImageName``. The random
    /// token keeps repeated drops of the same name from overwriting each other.
    static func sanitizedUploadName(filename: String?, ext: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let stem = filename.map { ($0 as NSString).lastPathComponent } ?? ""
        let base = (stem as NSString).deletingPathExtension
        let cleaned = String(String.UnicodeScalarView(base.unicodeScalars.filter { allowed.contains($0) }))
        let safeStem = cleaned.isEmpty ? "image" : String(cleaned.prefix(48))
        let token = UUID().uuidString.prefix(8).lowercased()
        return "drop-\(token)-\(safeStem).\(ext)"
    }

    private static func json(_ dict: [String: Any], status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
