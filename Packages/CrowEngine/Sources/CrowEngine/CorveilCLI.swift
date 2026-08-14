import CrowCore
import Foundation

/// The two on-demand actions Settings → Corveil CLI offers for the configured
/// `corveil` binary: **Verify** and **Reinstall skill** (CROW-1011).
///
/// Both existed in the retired macOS app (CROW-482/490/491) and were lost with it
/// — the web Settings tab has been telling people to use a desktop app that no
/// longer exists (ADR 0010). This type is where they came back, and it is
/// deliberately *not* in the UI layer: there are two doors to these actions —
/// `POST /config/corveil` for the browser and the `corveil-*` RPCs for `crow
/// corveil` — and a decision made in either door is a decision the other one
/// drifts from. Same shape as `MCPTokenRPC` (CROW-1004).
///
/// Neither action touches config. **Verify** runs `<path> --version`;
/// **Reinstall** re-runs the per-launch `corveil skill install` through
/// ``Scaffolder/installCorveilSkill(_:)``, which is the point of the button —
/// "I just rebuilt corveil locally, pick up its new embedded skill" without
/// restarting `crowd`.
///
/// Every entry point here blocks on `Process.waitUntilExit` for up to
/// ``timeout`` seconds. Callers on an async path must hop off the cooperative
/// pool (`Task.detached`) rather than await this inline.
public enum CorveilCLI {
    /// The result of one action, in the shape both doors serialize.
    ///
    /// `message` carries no `✓`/`✗` glyph: the JSON one is read by scripts and
    /// by `jq`, so the decoration belongs to whichever surface is rendering.
    /// `ok` is the thing to branch on.
    public struct Outcome: Sendable, Equatable {
        public let ok: Bool
        public let message: String
        /// The binary this ran against — echoed back because the path may have
        /// come from config rather than from the caller.
        public let path: String

        public init(ok: Bool, message: String, path: String) {
            self.ok = ok
            self.message = message
            self.path = path
        }
    }

    /// Wall-clock budget for a Verify subprocess.
    ///
    /// Matches ``Scaffolder/corveilInstallTimeout`` on purpose: a corveil that
    /// hangs on `--version` should be bounded by the same window as one that
    /// hangs on `skill install`, so a wedged binary reports the same way from
    /// either button.
    public static let timeout: TimeInterval = 5.0

    /// Which binary an action should run: the caller's explicit path when they
    /// gave one, otherwise whatever Settings has stored, otherwise `nil`.
    ///
    /// Shared rather than reimplemented per door so `crow corveil verify` with no
    /// `--path` and the browser's button resolve identically. Blank strings count
    /// as absent — an empty `--path ""` must fall through to config, not run "".
    public static func resolvePath(explicit: String?, configured: String?) -> String? {
        for candidate in [explicit, configured] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Run `<path> --version` and summarize it in one line.
    ///
    /// Ported from the retired `SettingsView.runCorveilVersion`, including its
    /// reason for `waitUntilExit` over a polling loop: `waitUntilExit` is the only
    /// thing that triggers Foundation's pipe-write-FD cleanup, and without it the
    /// post-exit `readToEnd()` either hangs or comes back empty. Once it returns,
    /// both writers (child + Foundation) have closed and the reads finish
    /// immediately.
    public static func verify(path: String) -> Outcome {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Outcome(ok: false, message: "Not executable: \(path)", path: path)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return Outcome(
                ok: false, message: "Could not launch: \(error.localizedDescription)", path: path)
        }

        let watchdog = ScaffolderTimeoutWatchdog(deadline: timeout, proc: proc)
        watchdog.start()
        proc.waitUntilExit()
        let timedOut = watchdog.cancel()

        if timedOut {
            CrowLog.info("[CorveilCLI] verify timed out after \(Int(timeout))s: \(path)")
            return Outcome(
                ok: false,
                message: "Timed out after \(Int(timeout))s — binary may be hung.",
                path: path)
        }

        // Both streams, because a `--version` that writes to stderr is still a
        // working binary and the diagnostic is the useful part when it isn't.
        let combined = [readAll(outPipe), readAll(errPipe)]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        let snippet = combined.split(separator: "\n").first.map(String.init) ?? combined

        if proc.terminationStatus == 0 {
            return Outcome(ok: true, message: snippet.isEmpty ? "Verified" : snippet, path: path)
        }
        let detail = snippet.isEmpty ? "exit code \(proc.terminationStatus)" : snippet
        CrowLog.info("[CorveilCLI] verify failed (\(detail)): \(path)")
        return Outcome(ok: false, message: detail, path: path)
    }

    /// Re-run `corveil skill install --path {devRoot}/.claude/commands/query-corveil.md`
    /// on demand — the same flow the daemon runs at launch, without a restart.
    ///
    /// Thin over ``Scaffolder/installCorveilSkill(_:)`` rather than a second
    /// implementation: the button must install exactly what launch installs, or
    /// "reinstall and see if that fixes it" stops being a diagnosis. The
    /// `String?` warning it returns is the daemon's `corveilSkillInstallWarning`
    /// text, so a failure here reads the same as a failure at startup.
    public static func reinstallSkill(path: String, devRoot: String) -> Outcome {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let warning = Scaffolder(devRoot: devRoot).installCorveilSkill(path) else {
            return Outcome(ok: true, message: "Skill reinstalled", path: path)
        }
        return Outcome(ok: false, message: warning, path: path)
    }

    /// Where ``reinstallSkill(path:devRoot:)`` writes, for surfaces that want to
    /// name the file. Kept next to the install so the two cannot disagree.
    public static func skillPath(devRoot: String) -> String {
        (devRoot as NSString).appendingPathComponent(".claude/commands/query-corveil.md")
    }

    /// Read a pipe to EOF after the child has exited, so this returns at once.
    private static func readAll(_ pipe: Pipe) -> String {
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
