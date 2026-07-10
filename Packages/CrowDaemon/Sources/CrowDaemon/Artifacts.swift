import Foundation
import CrowCore
import HTTPTypes
import Hummingbird
import NIOCore

/// Serves per-session generated images ("artifacts") from an ephemeral scratch
/// dir outside any git worktree — `$TMPDIR/crow/artifacts/<sessionID>/` — so a
/// client can view a diagram/screenshot an agent dropped there (CROW-593), and
/// hosts the write side of a drag-and-drop into the composer (#644 images, #652
/// any file).
///
/// Read-only *serve* side and hard-sandboxed: the session segment must be a real
/// UUID and the served file must be a bare image name (no separators, no `..`,
/// image extension only). The *upload* side accepts any file type (#652) but
/// stores it under a sanitized, traversal-proof name and never serves a
/// non-image back over HTTP. Combined with the daemon's loopback-only bind,
/// nothing outside this scratch tree is reachable.
enum Artifacts {
    /// Extensions the *serve* route (`GET`) and the Artifacts *panel* recognize
    /// as images. The upload route accepts far more than this (#652); these are
    /// only the types rendered back to the client.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg"]

    /// Raster image types served *inline*. Anything else the serve route hands
    /// back with `Content-Disposition: attachment` (SVG is script-bearing; the
    /// rest are generic downloads), so a served file can never render as a
    /// top-level document in the daemon origin.
    static let inlineImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    /// Cap for a single dropped file (10 MB). Screenshots blow past the 1 MB
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
            var headers: HTTPFields = [
                .contentType: contentType(for: file),
                .cacheControl: "no-store",
                // Never let the browser MIME-sniff a served artifact into a
                // script/HTML context (defense in depth alongside the disposition
                // below).
                HTTPField.Name("x-content-type-options")!: "nosniff",
            ]
            // Only raster images render inline (the Artifacts panel). Everything
            // else — SVG (can carry inline <script>) and any non-raster that
            // reached the serve gate — is forced to download so it can never run
            // as a top-level document in the daemon origin (review / CROW-593).
            if !inlineImageExtensions.contains((file as NSString).pathExtension.lowercased()) {
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
            // Any file type is accepted (#652); the extension is only for a
            // readable stored name. `collect(upTo:)` throws when the body exceeds
            // the cap → 413.
            let ext = uploadExtension(contentType: request.headers[.contentType], filename: filename)
            guard let buffer = try? await request.body.collect(upTo: maxUploadBytes) else {
                return Response(status: .init(code: 413)) // Content Too Large
            }
            let data = Data(buffer.readableBytesView)
            guard !data.isEmpty else { return Response(status: .badRequest) }
            let name = sanitizedUploadName(filename: filename, ext: ext)
            guard isSafeUploadName(name) else { return Response(status: .badRequest) }
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

    /// A bare image filename: non-empty, no separators, no `..`, image ext.
    /// Gate for the *serve* route (`GET`) — only image-extension files are ever
    /// handed back over HTTP. The router percent-decodes before this runs, so
    /// `%2e%2e`/`%2f` are caught.
    static func isSafeImageName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..")
            && imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A bare stored filename safe to *write* into the scratch dir: non-empty, no
    /// separators, no `..`. Unlike ``isSafeImageName`` this does not require an
    /// image extension — ordinary dropped files (source, docs, archives) are
    /// stored here too (#652). Names always come from ``sanitizedUploadName``,
    /// which strips everything but `[A-Za-z0-9_-]` from the stem and a validated
    /// extension, so this is belt-and-suspenders.
    static func isSafeUploadName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..")
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

    // MARK: - Upload helpers (#644 images, #652 any file)

    /// Resolve a safe storage extension for a dropped file of *any* type (#652).
    /// The filename's own extension wins when it looks like a real extension
    /// (`[a-z0-9]`, ≤ 16 chars) — so `shot.png` → `png`, `notes.txt` → `txt`,
    /// `data.tar.gz` → `gz`. Otherwise fall back to the `Content-Type` image map,
    /// which recovers the type of a pasted screenshot that arrives with an
    /// `image/*` body and no filename. Returns `""` (no extension) for
    /// extensionless files like `Makefile` — the stored name stays safe and the
    /// pasted host path still resolves. Never returns nil: #652 lifted the
    /// raster-only 415 gate, so ordinary files are accepted.
    static func uploadExtension(contentType: String?, filename: String?) -> String {
        if let filename {
            let ext = (filename as NSString).pathExtension.lowercased()
            if isSafeExtension(ext) { return ext }
        }
        // Media type only — strip any `; charset=…`/params.
        if let media = contentType?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() {
            switch media {
            case "image/png": return "png"
            case "image/jpeg", "image/jpg": return "jpg"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            default: break
            }
        }
        return ""
    }

    /// A plausible, safe file extension: 1–16 chars of lowercase `[a-z0-9]` only.
    /// Rejecting `.`, separators, and metacharacters keeps ``sanitizedUploadName``
    /// from ever producing a name with a separator or `..` via the extension.
    static func isSafeExtension(_ ext: String) -> Bool {
        !ext.isEmpty && ext.count <= 16
            && ext.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// A collision-free, traversal-proof name for a dropped file:
    /// `drop-<8hex>-<sanitized-stem>[.<ext>]`. The stem keeps only `[A-Za-z0-9_-]`
    /// from the original filename (spaces/slashes/dots/`..` dropped) and the
    /// extension is re-validated, so the result always satisfies
    /// ``isSafeUploadName``. A missing/unsafe extension is simply omitted
    /// (`Makefile` → `drop-<hex>-Makefile`). The random token keeps repeated drops
    /// of the same name from overwriting each other.
    static func sanitizedUploadName(filename: String?, ext: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let stem = filename.map { ($0 as NSString).lastPathComponent } ?? ""
        let base = (stem as NSString).deletingPathExtension
        let cleaned = String(String.UnicodeScalarView(base.unicodeScalars.filter { allowed.contains($0) }))
        let safeStem = cleaned.isEmpty ? "file" : String(cleaned.prefix(48))
        let token = UUID().uuidString.prefix(8).lowercased()
        let safeExt = isSafeExtension(ext) ? ext : ""
        return safeExt.isEmpty ? "drop-\(token)-\(safeStem)" : "drop-\(token)-\(safeStem).\(safeExt)"
    }

    private static func json(_ dict: [String: Any], status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
