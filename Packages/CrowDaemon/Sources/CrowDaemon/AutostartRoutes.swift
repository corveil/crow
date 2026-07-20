import CrowAutostart
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Local-only "start Crow at login" control for Settings → General (CROW-769).
///
/// Same shape and gating as ``SecretRoutes``: dedicated HTTP endpoints rather
/// than JSON-RPC methods, because the handler needs the peer address +
/// `X-Forwarded-For` to tell a local browser from a logged-in remote one, and
/// registering a login item mutates the *host machine*. A remote session must
/// not be able to install (or silently remove) a launch agent on someone else's
/// Mac, so writes require a local-direct, same-origin request.
///
/// The `crowd` written into the login item is **this** daemon's own executable
/// with **this** daemon's flags — no path guessing, and the login-launched
/// daemon comes up configured exactly like the one you're talking to. The
/// `crow autostart` CLI covers the case this can't: the daemon being down.
enum AutostartRoutes {
    static func mount(
        on router: Router<CrowHTTPContext>,
        boundHost: String,
        options: DaemonOptions,
        service: AutostartService = Autostart.service()
    ) {
        // Read-only: safe from any authenticated session, so a remote user can
        // at least see whether the host is set up to come back after a reboot.
        router.get("/autostart") { _, _ -> Response in
            json(encode(try service.status(expected: currentSpec(options))))
        }

        // Enable / disable. Local-only (see type doc).
        router.post("/autostart") { request, context -> Response in
            guard SecretRoutes.gateOK(request, context, boundHost: boundHost) else {
                return json(["error": "local-only"], status: .forbidden)
            }
            struct Body: Decodable { let enabled: Bool }
            guard let body = await decode(Body.self, request) else {
                return json(["error": "expected {\"enabled\": true|false}"], status: .badRequest)
            }
            do {
                let status = body.enabled
                    ? try service.install(try currentSpec(options))
                    : try service.uninstall()
                logLine("autostart \(body.enabled ? "enabled" : "disabled"): \(status.message)")
                return json(encode(status))
            } catch {
                let message = (error as? AutostartError)?.errorDescription ?? error.localizedDescription
                logLine("autostart \(body.enabled ? "install" : "uninstall") failed: \(message)")
                return json(["error": message], status: .internalServerError)
            }
        }
    }

    /// What this daemon would register: its own binary plus its live flags.
    ///
    /// `Bundle.main.executableURL` is the running `crowd` itself, so there is no
    /// resolution step and no way to register the wrong binary — and reinstalling
    /// after an upgrade re-points the plist at wherever the new `crowd` lives.
    static func currentSpec(_ options: DaemonOptions) throws -> AutostartSpec {
        guard let executable = Bundle.main.executableURL?.path else {
            throw AutostartError.binaryNotFound("Could not determine this crowd's own path.")
        }
        return AutostartSpec(
            binaryPath: executable,
            host: options.host,
            httpPort: options.httpPort,
            devRoot: options.devRoot,
            socketPath: options.socketPath)
    }

    // MARK: - HTTP helpers

    /// Same `[crowd]`-prefixed stderr line the daemon's own logging uses, so an
    /// install/uninstall (and any failure) shows up in the daemon log.
    private static func logLine(_ message: String) {
        FileHandle.standardError.write(Data("[crowd] \(message)\n".utf8))
    }

    /// `AutostartStatus` → a JSON object, so the web UI reads the same field
    /// names as `crow autostart status --json`.
    private static func encode(_ status: AutostartStatus) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(status),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ request: Request) async -> T? {
        guard let buffer = try? await request.body.collect(upTo: 64 * 1024) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(buffer.readableBytesView))
    }

    private static func json(_ dict: [String: Any], status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
