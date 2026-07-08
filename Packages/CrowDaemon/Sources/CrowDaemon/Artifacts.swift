import Foundation
import CrowCore
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

    /// Mount `GET /artifacts/:session/:file`.
    static func mount(on router: Router<CrowHTTPContext>) {
        router.get("/artifacts/:session/:file") { _, context -> Response in
            guard let session = context.parameters.get("session"),
                  let dir = dir(sessionID: session),
                  let file = context.parameters.get("file"),
                  isSafeImageName(file) else {
                return Response(status: .badRequest)
            }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else {
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
    }

    /// A bare image filename: non-empty, no separators, no `..`, allowed ext.
    /// The router percent-decodes before this runs, so `%2e%2e`/`%2f` are caught.
    static func isSafeImageName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..")
            && imageExtensions.contains((name as NSString).pathExtension.lowercased())
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
}
