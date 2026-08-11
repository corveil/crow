import Foundation

/// Resolves a `WorkspaceGateway` into launch-ready environment-variable values
/// for a `claude` invocation (CROW-402).
///
/// A header value may be a plaintext string or an `op://…` 1Password reference.
/// References are resolved at launch via the `op` CLI so the secret never lands
/// at rest in `config.json`; any other value is used literally. The serialized
/// output matches Claude Code's contract: `ANTHROPIC_BASE_URL` is the gateway
/// endpoint and `ANTHROPIC_CUSTOM_HEADERS` is newline-separated `Name: Value`
/// header lines.
///
/// Resolved secret values are never logged.
public enum GatewayResolver {
    /// Launch-ready env values derived from a gateway.
    public struct Resolved: Equatable, Sendable {
        /// Value for `ANTHROPIC_BASE_URL`.
        public var baseURL: String
        /// Value for `ANTHROPIC_CUSTOM_HEADERS` — newline-separated `Name: Value`.
        public var customHeaders: String

        public init(baseURL: String, customHeaders: String) {
            self.baseURL = baseURL
            self.customHeaders = customHeaders
        }
    }

    /// Serialize a resolved header map into the `ANTHROPIC_CUSTOM_HEADERS` value:
    /// newline-separated `Name: Value`, sorted by name for deterministic output.
    public static func serializeHeaders(_ headers: [String: String]) -> String {
        headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    /// Resolve a gateway's header values (resolving `op://…` references) and
    /// serialize them for launch. Returns `nil` for an empty gateway (caller
    /// should then *unset* the env vars rather than set them).
    ///
    /// - Parameter resolveSecret: Injected for testability; defaults to `op read`.
    ///   When a reference fails to resolve, the header is dropped and a redacted
    ///   warning is logged — the `baseURL` is still applied, so requests reach the
    ///   gateway and fail loudly there (a 401) rather than silently falling back
    ///   to the vanilla Anthropic API with the user's default key.
    public static func resolve(
        _ gateway: WorkspaceGateway,
        resolveSecret: (String) -> String? = Self.opRead
    ) -> Resolved? {
        guard !gateway.isEmpty else { return nil }

        var resolvedHeaders: [String: String] = [:]
        for (name, value) in gateway.customHeaders {
            // CROW-969: a value stored with literal surrounding quotes is a
            // shell-quoting slip that nothing downstream notices — `serializeHeaders`
            // interpolates it verbatim, `ClaudeLaunchArgs.gatewayEnvPrefix` shell-quotes
            // the whole line, and the gateway rejects the request as a bare "API error".
            //
            // Writes are now rejected (`WorkspaceGateway.isQuoteWrapped`), but a config
            // written before that check still has to launch — so warn and pass the value
            // through UNCHANGED. Stripping would mean guessing the quotes aren't part of
            // the secret; a loud rejection at the gateway beats authenticating with a
            // credential the user never verified.
            //
            // Checked on the STORED value, before the `op://` branch below: a quoted
            // reference fails `hasPrefix` and silently falls into the plaintext arm, which
            // is the most confusing case of all. Redacted exactly like the
            // reference-failure warning — the header NAME only, never the value.
            if WorkspaceGateway.isQuoteWrapped(value) {
                CrowLog.info("[GatewayResolver] Header '\(name)' has a value wrapped in quote characters; it is sent verbatim and the gateway will very likely reject it — re-set it without the quotes (`crow gateway set …`)")
            }
            if value.hasPrefix("op://") {
                if let secret = resolveSecret(value) {
                    resolvedHeaders[name] = secret
                } else {
                    CrowLog.info("[GatewayResolver] Failed to resolve secret reference for header '\(name)' (op read failed or op not signed in); dropping this header — the gateway will reject the request")
                }
            } else {
                resolvedHeaders[name] = value
            }
        }

        return Resolved(
            baseURL: gateway.baseURL,
            customHeaders: serializeHeaders(resolvedHeaders)
        )
    }

    /// Resolve a single `op://…` reference via the 1Password CLI (`op read`).
    /// Returns `nil` if `op` is missing, not signed in, or the read fails.
    /// The resolved value is returned to the caller but never logged.
    public static func opRead(_ reference: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["op", "read", reference]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Resolved PATH so a Homebrew-installed `op` is found; inherits HOME so
        // `op`'s session/biometric config is available.
        process.environment = ShellEnvironment.shared.env

        do {
            try process.run()
        } catch {
            CrowLog.info("[GatewayResolver] Failed to launch `op` for secret resolution: \(error.localizedDescription)")
            return nil
        }

        // Bound the wait so a stuck `op` (e.g. waiting on biometric prompt) can't
        // hang a session launch indefinitely.
        let deadline = DispatchTime.now() + .seconds(15)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            CrowLog.info("[GatewayResolver] `op read` timed out resolving a secret reference")
            return nil
        }

        guard process.terminationStatus == 0 else {
            CrowLog.info("[GatewayResolver] `op read` exited with status \(process.terminationStatus)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
