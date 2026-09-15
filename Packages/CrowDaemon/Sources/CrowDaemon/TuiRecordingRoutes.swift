import CrowCore
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Streamed GET `/tui-recordings/:id/{pty,observations,report,manifest}` (CROW-1255).
///
/// WebAuth middleware plus Origin-guard. Any web-auth peer can download any
/// recording for `retentionDays` (explicit ACL — broader than live `/terminal`).
/// Stream with FileHandle; never slurp a 64 MiB ndjson into a Data blob.
enum TuiRecordingRoutes {
    static let allowedFiles: Set<String> = ["pty", "observations", "report", "manifest"]

    static func mount(
        on router: Router<CrowHTTPContext>,
        boundHost: String,
        recorder: TuiRecorder
    ) {
        router.get("/tui-recordings/:id/:file") { request, context -> Response in
            guard WebSocketOriginGuard.isAllowedOrigin(
                request.headers[.origin],
                boundHost: boundHost,
                forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
                peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress)) else {
                return Response(status: .forbidden)
            }
            guard let rawID = context.parameters.get("id"),
                  let id = UUID(uuidString: rawID),
                  let file = context.parameters.get("file"),
                  allowedFiles.contains(file) else {
                return Response(status: .badRequest)
            }
            let dir = recorder.dir(for: id)
            let name: String
            let contentType: String
            switch file {
            case "pty":
                name = "pty.ndjson"
                contentType = "application/x-ndjson"
            case "observations":
                name = "observations.ndjson"
                contentType = "application/x-ndjson"
            case "report":
                name = "report.json"
                contentType = "application/json"
            default:
                name = "manifest.json"
                contentType = "application/json"
            }
            let candidate = dir.appendingPathComponent(name)
            guard let resolved = Artifacts.resolvedPathInside(dir: dir, file: candidate) else {
                return Response(status: .notFound)
            }
            let peer = context.remoteAddress.map { "\($0)" } ?? "unknown"
            CrowLog.info("[CrowTui record_get id=\(id.uuidString) peer=\(peer)]")
            let headers: HTTPFields = [
                .contentType: contentType,
                .contentDisposition: "attachment; filename=\"\(name)\"",
                .cacheControl: "no-store",
                HTTPField.Name("x-content-type-options")!: "nosniff",
            ]
            return Response(
                status: .ok,
                headers: headers,
                body: streamedFile(resolved))
        }
    }

    /// Stream `url` in 64 KiB chunks. Never loads the whole file into daemon memory.
    static func streamedFile(_ url: URL) -> ResponseBody {
        ResponseBody { writer in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try await writer.write(ByteBuffer(bytes: chunk))
            }
        }
    }
}
