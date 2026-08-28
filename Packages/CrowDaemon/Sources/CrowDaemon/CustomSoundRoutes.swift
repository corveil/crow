import Foundation
import CrowCore
import HTTPTypes
import Hummingbird
import NIOCore

/// Serves custom notification sounds from the Application Support `sounds/`
/// library and accepts Settings uploads (CROW-1147).
///
/// `GET /sounds/:file` is the playback path the web client (and the Tauri
/// desktop wrapper) fetches. `POST /sounds` is the Settings "Upload sound"
/// write — binary, so it sits here rather than on `/rpc` (1 MB frame cap).
/// Both sit behind `WebAuthMiddleware`; the write side additionally requires a
/// same-origin request (anti-CSRF), matching `Artifacts`.
enum CustomSoundRoutes {
    /// Mount serve + upload. `library` is injected so tests never touch the
    /// live Application Support directory (ADR 0012).
    static func mount(
        on router: Router<CrowHTTPContext>,
        boundHost: String,
        library: CustomSoundLibrary
    ) {
        router.get("/sounds/:file") { _, context -> Response in
            guard let file = context.parameters.get("file"),
                  CustomSoundLibrary.isSafeFileName(file) else {
                return Response(status: .badRequest)
            }
            guard let resolved = library.resolvedFile(file),
                  let data = try? Data(contentsOf: resolved) else {
                return Response(status: .notFound)
            }
            return Response(
                status: .ok,
                headers: [
                    .contentType: CustomSoundLibrary.contentType(for: file),
                    .cacheControl: "no-store",
                    HTTPField.Name("x-content-type-options")!: "nosniff",
                ],
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }

        router.post("/sounds") { request, context -> Response in
            guard WebSocketOriginGuard.isAllowedOrigin(
                request.headers[.origin],
                boundHost: boundHost,
                forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
                peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress)) else {
                return Response(status: .forbidden)
            }
            let filename = request.headers[HTTPField.Name("x-filename")!]
                .flatMap { $0.removingPercentEncoding ?? $0 }
                ?? "sound.wav"
            guard let buffer = try? await request.body.collect(upTo: CustomSoundLibrary.maxBytes) else {
                return json(
                    ["error": "Sound file is too large. Maximum size is \(CustomSoundLibrary.maxBytes / (1024 * 1024)) MB."],
                    status: .init(code: 413))
            }
            let data = Data(buffer.readableBytesView)
            do {
                let sound = try library.add(data: data, filename: filename)
                return json([
                    "name": sound.name,
                    "file": sound.file,
                    "url": sound.url,
                ])
            } catch let error as CustomSoundError {
                let status: HTTPResponse.Status
                switch error {
                case .tooLarge: status = .init(code: 413)
                case .io: status = .internalServerError
                default: status = .badRequest
                }
                return json(["error": error.localizedDescription], status: status)
            } catch {
                return json(["error": error.localizedDescription], status: .internalServerError)
            }
        }
    }

    private static func json(_ dict: [String: Any], status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
