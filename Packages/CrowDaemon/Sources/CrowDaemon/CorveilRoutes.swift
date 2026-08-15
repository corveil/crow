import CrowCore
import CrowEngine
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Settings → Corveil CLI's **Verify** and **Reinstall skill** buttons
/// (CROW-1011), for the browser.
///
/// The retired macOS app had both; the web Settings tab replaced them with a
/// line telling people to use a desktop app that no longer exists (ADR 0010).
/// This is the browser's half of putting them back — the CLI's half is the
/// `corveil-*` JSON-RPC pair behind `crow corveil`, and the behaviour both reach
/// lives in ``CorveilCLI`` so the two doors cannot drift.
///
/// Same shape and gating as ``AutostartRoutes``: a dedicated HTTP POST rather
/// than a JSON-RPC method, because the handler needs the peer address +
/// `X-Forwarded-For` to tell a local browser from a logged-in remote one, and
/// running `defaults.binaries["corveil"]` executes an arbitrary path on the
/// *host machine*. A remote session must not be able to do that, which is the
/// same reason writing that field is local-only.
///
/// Read-only counterpart: there isn't one. Neither action has a "status" a
/// remote peer could usefully poll — Verify's answer is only true at the instant
/// the subprocess ran.
enum CorveilRoutes {
    static func mount(
        on router: Router<CrowHTTPContext>,
        boundHost: String,
        devRoot: String,
        appState: AppState
    ) {
        router.post("/config/corveil") { request, context -> Response in
            guard SecretRoutes.gateOK(request, context, boundHost: boundHost) else {
                return json(["error": "local-only"], status: .forbidden)
            }
            struct Body: Decodable {
                let action: String?
                let path: String?
            }
            guard let body = await decode(Body.self, request) else {
                return json(
                    ["error": "expected {\"action\": \"verify\"|\"reinstall-skill\"}"],
                    status: .badRequest)
            }

            // The path in the request wins over config: the button acts on what
            // is typed in the field, which may not be saved yet. That is the
            // whole point of a Verify button — you check a path *before*
            // committing it.
            let configured = ConfigStore.loadConfig(devRoot: devRoot)?.defaults.binaries["corveil"]
            guard let path = CorveilCLI.resolvePath(explicit: body.path, configured: configured)
            else {
                return json(
                    ["error": "Set a path to the corveil binary first."],
                    status: .badRequest)
            }

            // Both actions block for up to `CorveilCLI.timeout` seconds waiting
            // on a subprocess. Detached so that wait doesn't hold a cooperative
            // thread the daemon serves other requests from.
            switch body.action {
            case "verify":
                let outcome = await Task.detached(priority: .userInitiated) {
                    CorveilCLI.verify(path: path)
                }.value
                return json(outcomeJSON(outcome))

            case "reinstall-skill":
                let outcome = await Task.detached(priority: .userInitiated) {
                    CorveilCLI.reinstallSkill(path: path, devRoot: devRoot)
                }.value
                // Keep the launch-time diagnostic honest: a manual reinstall that
                // succeeds clears the startup warning, one that fails replaces
                // it. Same as the `corveil-reinstall-skill` RPC, and as the
                // retired desktop app before both.
                await MainActor.run {
                    appState.corveilSkillInstallWarning = outcome.ok ? nil : outcome.message
                }
                var payload = outcomeJSON(outcome)
                payload["skill_path"] = CorveilCLI.commandsDir(devRoot: devRoot)
                return json(payload)

            default:
                return json(
                    ["error": "action must be \"verify\" or \"reinstall-skill\""],
                    status: .badRequest)
            }
        }
    }

    /// 200 either way. A corveil that is missing or broken is a *successful
    /// report* of a broken binary, not a failed request — the browser renders
    /// `ok` and would otherwise have to dig the diagnostic out of an error path.
    private static func outcomeJSON(_ outcome: CorveilCLI.Outcome) -> [String: Any] {
        ["ok": outcome.ok, "message": outcome.message, "path": outcome.path]
    }

    // MARK: - HTTP helpers

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
