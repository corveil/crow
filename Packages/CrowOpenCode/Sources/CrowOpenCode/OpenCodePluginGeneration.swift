import Foundation
import CrowCore

/// Which plugin API the installed `opencode` speaks (CROW-1332).
///
/// OpenCode 2 replaces the `opencode` binary in place — `opencode upgrade
/// --major` installs it at the same path, under the same command — and "V1
/// plugin implementations do not run in V2" (upstream `migrate-v1` guide). A V1
/// plugin on a V2 binary is not an error anyone sees: it simply never fires, so
/// the session card never leaves its last state and a job never reaches `.done`.
/// So the generation is decided by **probing** the binary, never assumed.
///
/// The two plugin bodies share one filename (`crow-hooks.js`) and directory
/// (`.opencode/plugins/`, which both generations discover), so teardown,
/// `.gitignore` and the global plugin's self-suppression check are unchanged.
public enum OpenCodePluginGeneration: String, Sendable, Equatable {
    /// `export const CrowHooks = async ({ $, … }) => ({ event, … })` — the V1
    /// function plugin. Done is `session.status {idle}` (CROW-1000).
    case v1
    /// `export default { id, setup(ctx) }` — the V2 object plugin. Done is
    /// `session.execution.succeeded|failed|interrupted`, the lifecycle V2 core
    /// actually publishes (see `OpenCodeHookConfigWriter.pluginSourceV2`).
    case v2

    /// The first `opencode` whose plugin host is V2. Verified against the
    /// `v2.0.32` source (`packages/core/src/plugin/module.ts` decodes the
    /// default export's `{ id, setup }`); the v1 line ends at `1.19.x`.
    static let v2Floor = AgentSemVer(2, 0, 0)

    /// Pick the generation for a parsed `opencode --version`.
    ///
    /// An unparseable or missing version keeps `.v1` — today's behavior, and the
    /// only body every pre-2 build loads. That is not a blind spot on v2: every
    /// v2 build prints a plain `MAJOR.MINOR.PATCH`, so a `nil` here means the
    /// probe itself failed (binary missing, hung past the timeout), and the
    /// writer logs it.
    static func forVersion(_ version: AgentSemVer?) -> OpenCodePluginGeneration {
        guard let version else { return .v1 }
        return version >= v2Floor ? .v2 : .v1
    }

    /// Probe `binary` (cached per binary fingerprint, so an in-place upgrade
    /// re-probes — see `OpenCodeLaunchArgs.cacheKey`).
    static func detect(binary: String?) -> (generation: OpenCodePluginGeneration, version: AgentSemVer?) {
        guard let binary else { return (.v1, nil) }
        let version = OpenCodeLaunchArgs.installedVersion(binary: binary)
        return (forVersion(version), version)
    }
}
