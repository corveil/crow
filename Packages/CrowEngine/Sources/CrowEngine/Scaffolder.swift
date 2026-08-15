import CrowClaude
import CrowCore
import Foundation

/// Outcome of a single `Scaffolder.scaffold(...)` run. `warning` is non-nil only
/// for non-fatal post-scaffold issues (today: a configured `corveil` binary
/// that's missing/non-executable or whose `skill install` returned non-zero).
/// Callers surface it via `AppState.corveilSkillInstallWarning`; never fatal.
public struct ScaffoldResult {
    public var warning: String?
}

/// Creates the devRoot directory structure and copies bundled resources.
public struct Scaffolder {
    let devRoot: String
    public init(devRoot: String) { self.devRoot = devRoot }

    /// Create the full workspace scaffold.
    ///
    /// `managerAgentKind` drives `{{CROW_AGENT_DISPLAY_NAME}}` substitution in the
    /// dev-root skill bodies (issue #447). The Manager session is the consumer of
    /// these files, so its agent kind is the right one to bake in.
    ///
    /// `corveilBinaryPath`, when set and executable, triggers a post-scaffold
    /// install of *every* embedded corveil skill into
    /// `{devRoot}/.claude/commands/` (CROW-1039, generalizing CROW-482), so each
    /// `/slash-command` the binary ships stays in sync with the user's
    /// locally-built corveil. Failures here are non-fatal: they are returned as
    /// `ScaffoldResult.warning` and never throw — the rest of the scaffold has
    /// already succeeded by that point.
    ///
    /// `binaryOverrides` is the full `defaults.binaries` map. Every entry
    /// whose target is executable becomes a symlink at
    /// `{devRoot}/.claude/bin/<name>` (CROW-487). Combined with the shell
    /// wrapper's PATH prepend, that dir wins precedence for bare invocations
    /// of `corveil` / `codex` / `cursor` inside spawned agent terminals, so
    /// embedded skills (e.g. `/query-corveil`) resolve to the user-configured
    /// binary instead of whatever happens to be on PATH.
    ///
    /// `appCrowBinaryPath` overrides the running app's crow CLI location when
    /// materializing `{devRoot}/.claude/bin/crow` (CROW-552). Tests inject a
    /// stand-in executable; production passes `nil` and uses
    /// `ClaudeHookConfigWriter.appCrowBinary()`.
    @discardableResult
    public func scaffold(workspaceNames: [String],
                  managerAgentKind: AgentKind = .claudeCode,
                  corveilBinaryPath: String? = nil,
                  binaryOverrides: [String: String] = [:],
                  appCrowBinaryPath: String? = nil) throws -> ScaffoldResult {
        let fm = FileManager.default

        // Create devRoot
        try fm.createDirectory(atPath: devRoot, withIntermediateDirectories: true)

        // Create workspace subdirectories
        for name in workspaceNames {
            let wsPath = (devRoot as NSString).appendingPathComponent(name)
            try fm.createDirectory(atPath: wsPath, withIntermediateDirectories: true)
        }

        // Create .claude directory structure
        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")
        let skillsDir = (claudeDir as NSString).appendingPathComponent("skills/crow-workspace")
        try fm.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)

        let reviewSkillsDir = (claudeDir as NSString).appendingPathComponent("skills/crow-review-pr")
        try fm.createDirectory(atPath: reviewSkillsDir, withIntermediateDirectories: true)

        let batchSkillsDir = (claudeDir as NSString).appendingPathComponent("skills/crow-batch-workspace")
        try fm.createDirectory(atPath: batchSkillsDir, withIntermediateDirectories: true)

        let createTicketSkillsDir = (claudeDir as NSString).appendingPathComponent("skills/crow-create-ticket")
        try fm.createDirectory(atPath: createTicketSkillsDir, withIntermediateDirectories: true)

        let attributionSkillsDir = (claudeDir as NSString).appendingPathComponent("skills/crow-attribution")
        try fm.createDirectory(atPath: attributionSkillsDir, withIntermediateDirectories: true)

        let showImageSkillsDir = (claudeDir as NSString).appendingPathComponent("skills/crow-show-image")
        try fm.createDirectory(atPath: showImageSkillsDir, withIntermediateDirectories: true)

        // Create crow-reviews directory for PR review clones
        let reviewsDir = DevRootLayout.reviewsDir(devRoot: devRoot)
        try fm.createDirectory(atPath: reviewsDir, withIntermediateDirectories: true)

        // Always update CLAUDE.md — but preserve the "Known Issues / Corrections" section
        let claudeMDPath = (claudeDir as NSString).appendingPathComponent("CLAUDE.md")
        let template = Self.bundledCLAUDEMD()
        if fm.fileExists(atPath: claudeMDPath),
           let existing = try? String(contentsOfFile: claudeMDPath, encoding: .utf8),
           let range = existing.range(of: "## Known Issues / Corrections") {
            // Preserve user corrections, replace everything above
            var userCorrections = String(existing[range.lowerBound...])
            // Sanitize stale references from pre-rename installations (case-insensitive)
            userCorrections = userCorrections
                .replacingOccurrences(of: "ride ", with: "crow ", options: .caseInsensitive)
                .replacingOccurrences(of: "`ride`", with: "`crow`", options: .caseInsensitive)
                .replacingOccurrences(of: "ride.sock", with: "crow.sock", options: .caseInsensitive)
                .replacingOccurrences(of: "/ride-workspace", with: "/crow-workspace", options: .caseInsensitive)
                .replacingOccurrences(of: "rm-ai-ide", with: "Crow", options: .caseInsensitive)
            let templateBase: String
            if let templateRange = template.range(of: "## Known Issues / Corrections") {
                templateBase = String(template[..<templateRange.lowerBound])
            } else {
                templateBase = template + "\n\n"
            }
            try (templateBase + userCorrections).write(toFile: claudeMDPath, atomically: true, encoding: .utf8)
        } else {
            try template.write(toFile: claudeMDPath, atomically: true, encoding: .utf8)
        }

        // Always overwrite the skill with the latest version from the app
        let skillPath = (skillsDir as NSString).appendingPathComponent("SKILL.md")
        let skillTemplate = Self.bundledSkill()
        try CrowAttribution.expandSkillBody(skillTemplate, agentKind: managerAgentKind)
            .write(toFile: skillPath, atomically: true, encoding: .utf8)

        // Always overwrite setup.sh with the latest version and make executable
        let setupScriptPath = (skillsDir as NSString).appendingPathComponent("setup.sh")
        let setupScript = Self.bundledSetupScript()
        try setupScript.write(toFile: setupScriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setupScriptPath)

        // Always overwrite the review-pr skill with the latest version
        let reviewSkillPath = (reviewSkillsDir as NSString).appendingPathComponent("SKILL.md")
        let reviewSkillTemplate = Self.bundledReviewSkill()
        try CrowAttribution.expandSkillBody(reviewSkillTemplate, agentKind: managerAgentKind)
            .write(toFile: reviewSkillPath, atomically: true, encoding: .utf8)

        // Always overwrite the batch-workspace skill with the latest version
        let batchSkillPath = (batchSkillsDir as NSString).appendingPathComponent("SKILL.md")
        let batchSkillTemplate = Self.bundledBatchSkill()
        try CrowAttribution.expandSkillBody(batchSkillTemplate, agentKind: managerAgentKind)
            .write(toFile: batchSkillPath, atomically: true, encoding: .utf8)

        // Always overwrite the create-ticket skill with the latest version
        let createTicketSkillPath = (createTicketSkillsDir as NSString).appendingPathComponent("SKILL.md")
        let createTicketSkillTemplate = Self.bundledCreateTicketSkill()
        try CrowAttribution.expandSkillBody(createTicketSkillTemplate, agentKind: managerAgentKind)
            .write(toFile: createTicketSkillPath, atomically: true, encoding: .utf8)

        // Always overwrite the show-image skill (surfaces generated images in
        // Crow's Images panel). No attribution expansion — it has no agent
        // placeholders (CROW-593).
        let showImageSkillPath = (showImageSkillsDir as NSString).appendingPathComponent("SKILL.md")
        try Self.bundledShowImageSkill()
            .write(toFile: showImageSkillPath, atomically: true, encoding: .utf8)

        // The `/crow-image` slash command — a user-facing front door to the same
        // Images panel, complementing the crow-show-image skill (CROW-593).
        let commandsDir = (claudeDir as NSString).appendingPathComponent("commands")
        try fm.createDirectory(atPath: commandsDir, withIntermediateDirectories: true)
        let imageCommandPath = (commandsDir as NSString).appendingPathComponent("crow-image.md")
        try Self.bundledImageCommand()
            .write(toFile: imageCommandPath, atomically: true, encoding: .utf8)

        // Shared attribution footer rules (issue #443)
        let attributionFooterPath = (attributionSkillsDir as NSString).appendingPathComponent("FOOTER.md")
        let attributionFooter = Self.bundledAttributionFooter()
        try CrowAttribution.expandSkillBody(attributionFooter, agentKind: managerAgentKind)
            .write(toFile: attributionFooterPath, atomically: true, encoding: .utf8)

        // Write Crow's required permissions to settings.local.json, not
        // settings.json. settings.json is the user's own file —
        // Crow never writes it and never has to reconcile with whatever the
        // user puts there. settings.local.json is Claude Code's local-
        // override layer: its `permissions.allow` entries are merged with
        // settings.json's at load time, so crow/gh/git commands still run
        // without a prompt. `mergeSettings` still guards this file too — a
        // full overwrite on every launch would just move the "nukes my
        // customizations" bug from one filename to another. It fills in
        // only what's missing and reports `.upToDate` when there's nothing
        // to add, so a steady-state launch skips the write entirely — the
        // on-disk file (bytes, inode, mtime, mode) is left completely alone.
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")
        let settingsTemplate = Self.bundledSettings()
        if case let .write(mergedSettings) = Self.mergeSettings(existingPath: settingsPath, template: settingsTemplate) {
            try mergedSettings.write(toFile: settingsPath, atomically: true, encoding: .utf8)
            // `atomically: true` renames a fresh temp file over the target,
            // which resets its mode to the umask default (~0o644). This same
            // file's `env` block can carry a resolved gateway bearer token —
            // ClaudeHookConfigWriter.writeGatewayEnv deliberately restricts
            // it to owner-only — so re-apply 0o600 here to match that sibling
            // writer. Without it the Settings → "Re-scaffold" action (which
            // runs scaffold with no following writeGatewayEnv) would leave a
            // token-bearing file group/world-readable until the next launch.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsPath)
        }

        // Create prompts directory for crow-workspace prompt files
        let promptsDir = (claudeDir as NSString).appendingPathComponent("prompts")
        try fm.createDirectory(atPath: promptsDir, withIntermediateDirectories: true)

        // Per-devroot bin dir is the precedence anchor for bare-command
        // invocations inside spawned agent terminals (CROW-487). Every
        // configured `defaults.binaries.<name>` becomes a symlink here, and
        // the tmux shell wrapper prepends this dir to PATH after sourcing
        // user rc — so `corveil`, `codex`, `cursor` resolve to the
        // user-configured binary regardless of what's on PATH.
        installBinarySymlinks(binaryOverrides, claudeDir: claudeDir)
        // Always re-point `{devRoot}/.claude/bin/crow` at the running app's own
        // CLI (CROW-552). Independent of `defaults.binaries` so every agent kind
        // discovers `crow` via the tmux shell wrapper's PATH prepend, and run
        // AFTER `installBinarySymlinks` so a user-set `defaults.binaries["crow"]`
        // is overwritten here by design — the app binary always wins.
        //
        // Lives in `ClaudeHookConfigWriter` because that is also where hook
        // commands resolve their crow path, and the two must agree: the link is
        // what makes a written hook command survive the worktree its build came
        // from being deleted (#897).
        ClaudeHookConfigWriter.ensureCrowCLISymlink(
            devRoot: devRoot, appCrowPath: appCrowBinaryPath)

        // Re-install every embedded corveil slash command from the
        // user-configured corveil binary on every launch (CROW-1039). Failure
        // here is intentionally non-fatal — the rest of the scaffold is done.
        let warning = installCorveilSkill(corveilBinaryPath)
        return ScaffoldResult(warning: warning)
    }

    /// Materialize `{devRoot}/.claude/bin/<name>` symlinks for every
    /// `defaults.binaries.<name>` whose target is an executable file
    /// (CROW-487). Idempotent — re-run on every Scaffolder pass:
    ///
    /// - Reaps symlinks whose key was removed from config, so a stale entry
    ///   never shadows a working PATH install. Only removes entries that are
    ///   actually symlinks (we never own non-link files in this dir).
    /// - Skips non-executable / empty targets, dropping any prior link for
    ///   that key. Prevents a misconfigured path from hiding `corveil` on
    ///   the user's PATH.
    /// - Recreates good links with `removeItem` + `createSymbolicLink`,
    ///   matching `ln -sf` semantics.
    ///
    /// Symlinks managed outside `defaults.binaries` — never reaped by
    /// `installBinarySymlinks`, refreshed by their own installer.
    private static let managedBinarySymlinks: Set<String> = ["crow"]

    /// All errors are logged + swallowed; this step is best-effort and must
    /// never fail an otherwise-successful scaffold pass.
    private func installBinarySymlinks(_ overrides: [String: String], claudeDir: String) {
        let fm = FileManager.default
        let binDir = (claudeDir as NSString).appendingPathComponent("bin")
        do {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        } catch {
            CrowLog.info("[Scaffolder] could not create bin dir \(binDir): \(error.localizedDescription)")
            return
        }

        // Reap stale symlinks whose key is no longer in config. Skip
        // anything that isn't a symlink — we never want to nuke a real
        // file that someone dropped here by hand.
        let existing = (try? fm.contentsOfDirectory(atPath: binDir)) ?? []
        for name in existing where overrides[name] == nil && !Self.managedBinarySymlinks.contains(name) {
            let link = (binDir as NSString).appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: link),
               (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                try? fm.removeItem(atPath: link)
            }
        }

        for (name, target) in overrides {
            let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
            let link = (binDir as NSString).appendingPathComponent(name)
            guard !trimmed.isEmpty, fm.isExecutableFile(atPath: trimmed) else {
                // Misconfigured: drop any stale link for this key so a
                // broken pointer doesn't shadow a working PATH install.
                try? fm.removeItem(atPath: link)
                if !trimmed.isEmpty {
                    CrowLog.info("[Scaffolder] defaults.binaries.\(name) not executable at \(trimmed) — skipping symlink")
                }
                continue
            }
            try? fm.removeItem(atPath: link)
            do {
                try fm.createSymbolicLink(atPath: link, withDestinationPath: trimmed)
            } catch {
                CrowLog.info("[Scaffolder] failed to symlink \(link) -> \(trimmed): \(error.localizedDescription)")
            }
        }
    }

    /// Installs **every** embedded corveil skill as a `/slash-command` under
    /// `{devRoot}/.claude/commands/` when `corveilBinaryPath` is set and points
    /// at an executable (CROW-1039). Returns a short user-facing warning string
    /// summarizing any per-skill failures; `nil` on success or when the feature
    /// is unconfigured (empty/nil path).
    ///
    /// The set is *enumerated* from the binary (`corveil skill list`), not
    /// hardcoded, so a corveil that ships a new embedded skill gets it installed
    /// without a Crow change. Each skill is installed independently
    /// (`corveil skill install --skill <name> --path .../<name>.md`); one skill
    /// failing does not abort the rest — failures are aggregated into the single
    /// returned warning (→ `AppState.corveilSkillInstallWarning`). If the binary
    /// can't enumerate (older build, no `list` subcommand, empty output) the
    /// install falls back to the historical single default, ``defaultCorveilSkill``,
    /// so a launch never regresses to installing *fewer* skills than before.
    ///
    /// `Scaffolder.scaffold(...)` runs synchronously on the daemon's launch
    /// path (`CrowDaemon.run` → `LaunchScaffold.run`, before the Manager
    /// session is ensured), so a hung corveil binary would stall startup before
    /// the Manager comes up. Two guards bound the worst case: each subprocess is
    /// SIGTERM'd after ``corveilInstallTimeout`` seconds, and the whole
    /// enumerate-then-install sequence shares one ``corveilInstallBudget``
    /// wall-clock deadline — once it is spent, no further subprocess is launched.
    /// A binary that hangs on `list` (the common wedged case) still costs only a
    /// single ``corveilInstallTimeout``, exactly as the one-skill install did.
    ///
    /// Public, not private — it is also the "reinstall without restarting Crow"
    /// entry point for a corveil binary the user just picked (CROW-490) or
    /// clicked Reinstall on (CROW-491). Callers on that path must dispatch off
    /// the main thread (`Task.detached`) so the worst case doesn't freeze the
    /// settings UI.
    public func installCorveilSkill(_ corveilBinaryPath: String?) -> String? {
        guard let path = corveilBinaryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: path) else {
            CrowLog.info("[Scaffolder] corveil binary not executable: \(path)")
            return "Corveil skill install skipped — binary at \(path) is missing or not executable. Check Settings → General → Corveil CLI."
        }

        // Via `CorveilCLI`, not a second literal: the Settings "Reinstall skill"
        // button names this directory to the user, and a target that drifts from
        // the name shown would make the button's own report wrong (CROW-1011).
        // Every skill lands in this one dir, so it is created once up front.
        let commandsDir = CorveilCLI.commandsDir(devRoot: devRoot)
        do {
            try fm.createDirectory(atPath: commandsDir, withIntermediateDirectories: true)
        } catch {
            CrowLog.info("[Scaffolder] could not create commands dir: \(error.localizedDescription)")
            return "Corveil skill install failed — could not create .claude/commands directory."
        }

        // One wall-clock deadline shared by enumeration + every install, so N
        // skills can't stall startup for N × the per-process timeout.
        let deadline = Date().addingTimeInterval(Self.corveilInstallBudget)

        // 1. Enumerate the embedded skills from the binary itself. A hung `list`
        //    is the common wedged case — bail with the timeout warning rather
        //    than spending the rest of the budget on installs that will also
        //    hang. Any other `list` failure (older binary, no `list`
        //    subcommand, empty output) falls back to the historical single
        //    default so we never install *fewer* skills than before CROW-1039.
        var didFallBack = false
        let skills: [String]
        switch runCorveil(binary: path, args: ["skill", "list", "--format", "json"], deadline: deadline) {
        case .timedOut:
            CrowLog.info("[Scaffolder] corveil skill list timed out")
            return Self.timeoutWarning
        case .launchFailed(let message):
            CrowLog.info("[Scaffolder] corveil skill list launch failed: \(message)")
            return "Corveil skill install failed — \(message). Check path in Settings."
        case .failed(let stderr, let code):
            CrowLog.info("[Scaffolder] corveil skill list exit=\(code) stderr=\(stderr) — falling back to \(Self.defaultCorveilSkill)")
            skills = [Self.defaultCorveilSkill]
            didFallBack = true
        case .succeeded(let stdout, _):
            let parsed = Self.parseSkillNames(from: stdout)
            if parsed.isEmpty {
                CrowLog.info("[Scaffolder] corveil skill list returned no skills — falling back to \(Self.defaultCorveilSkill)")
                skills = [Self.defaultCorveilSkill]
                didFallBack = true
            } else {
                skills = parsed
            }
        }

        // 2. Install each skill independently. Best-effort: collect per-skill
        //    failures and keep going, so one broken skill doesn't cost the
        //    others. A timeout means the binary is now hung, so stop.
        var failures: [(skill: String, reason: String)] = []
        installLoop: for skill in skills {
            guard deadline.timeIntervalSinceNow > 0 else {
                CrowLog.info("[Scaffolder] corveil install budget spent before \(skill)")
                failures.append((skill, "timed out"))
                break
            }
            let target = CorveilCLI.skillPath(devRoot: devRoot, skill: skill)
            // Fallback installs the historical default with no `--skill`, exactly
            // matching corveil's own default — so an old binary that predates the
            // `--skill` flag still installs query-corveil.
            let args = didFallBack
                ? ["skill", "install", "--path", target]
                : ["skill", "install", "--skill", skill, "--path", target]
            switch runCorveil(binary: path, args: args, deadline: deadline) {
            case .succeeded:
                CrowLog.info("[Scaffolder] corveil skill '\(skill)' installed at \(target)")
            case .timedOut:
                CrowLog.info("[Scaffolder] corveil skill '\(skill)' install timed out")
                failures.append((skill, "timed out"))
                break installLoop  // hung binary — don't burn the rest of the budget
            case .launchFailed(let message):
                CrowLog.info("[Scaffolder] corveil skill '\(skill)' launch failed: \(message)")
                failures.append((skill, message))
            case .failed(let stderr, let code):
                let detail = stderr.isEmpty ? "exit code \(code)" : stderr
                CrowLog.info("[Scaffolder] corveil skill '\(skill)' install exit=\(code) stderr=\(stderr)")
                failures.append((skill, detail))
            }
        }

        guard !failures.isEmpty else { return nil }
        let detail = failures.map { "\($0.skill) (\($0.reason))" }.joined(separator: ", ")
        let noun = failures.count == 1 ? "skill" : "skills"
        return "Corveil skill install failed for \(failures.count) \(noun): \(detail). Check path in Settings."
    }

    /// Outcome of one bounded corveil subprocess run by ``runCorveil(binary:args:deadline:)``.
    private enum CorveilRun {
        case succeeded(stdout: String, stderr: String)
        case failed(stderr: String, code: Int32)
        case timedOut
        case launchFailed(String)
    }

    /// Run `<binary> <args>` bounded by both the per-process
    /// ``corveilInstallTimeout`` and the caller's shared `deadline`, capturing
    /// stdout/stderr. Reads the pipes after `waitUntilExit` (the same proven
    /// pattern as ``CorveilCLI/verify(path:)``): corveil's `list`/`install`
    /// output is a few short lines, well under the pipe buffer, so a post-exit
    /// read is deadlock-free and picks up EOF immediately once both writers
    /// (child + Foundation) have closed.
    private func runCorveil(binary: String, args: [String], deadline: Date) -> CorveilRun {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return .timedOut }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return .launchFailed(error.localizedDescription)
        }

        // Cap this process at whichever comes first: the per-process ceiling or
        // whatever remains of the shared budget.
        let watchdog = ScaffolderTimeoutWatchdog(
            deadline: min(Self.corveilInstallTimeout, remaining), proc: proc)
        watchdog.start()
        proc.waitUntilExit()
        let timedOut = watchdog.cancel()

        let stdout = Self.readTrimmed(outPipe)
        let stderr = Self.readTrimmed(errPipe)
        if timedOut { return .timedOut }
        if proc.terminationStatus != 0 { return .failed(stderr: stderr, code: proc.terminationStatus) }
        return .succeeded(stdout: stdout, stderr: stderr)
    }

    /// Read a pipe to EOF after the child has exited, trimmed. Returns at once
    /// because `waitUntilExit` has already closed both writer FDs.
    private static func readTrimmed(_ pipe: Pipe) -> String {
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Parse `corveil skill list` output into embedded-skill names. Current
    /// corveil builds print one name per line even under `--format json`; a
    /// future build may emit a JSON array (of strings, or of `{name}` objects).
    /// Accept all three, and keep only well-formed slugs so a stray banner or
    /// log line can't become a bogus install target or `<name>.md` filename.
    static func parseSkillNames(from output: String) -> [String] {
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            if let names = json as? [String] {
                return names.compactMap(sanitizedSkillName)
            }
            if let objects = json as? [[String: Any]] {
                return objects.compactMap { ($0["name"] as? String).flatMap(sanitizedSkillName) }
            }
        }
        return output.split(whereSeparator: { $0.isNewline })
            .compactMap { sanitizedSkillName(String($0)) }
    }

    /// A skill name is a lowercase kebab/underscore slug. Anything else — a
    /// banner line, a path, a blank line — is rejected, which both filters
    /// non-skill output and blocks path traversal via the `<name>.md` target
    /// (a name with `/` or `.` never survives).
    private static func sanitizedSkillName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.allSatisfy({
                  ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
              })
        else { return nil }
        return name
    }

    /// The single skill corveil installs by default, and the historical Crow
    /// behaviour before CROW-1039. The fallback when the binary can't enumerate
    /// its embedded skills, so a launch never regresses to installing nothing.
    static let defaultCorveilSkill = "query-corveil"

    /// Wall-clock budget for a *single* `corveil skill list`/`install`
    /// subprocess. Tight because `Scaffolder.scaffold(...)` runs synchronously on
    /// the daemon launch path (`CrowDaemon.run` → `LaunchScaffold.run`) before
    /// the Manager session is ensured — a hung corveil binary delays the
    /// Manager's spawn by this many seconds. 5s is generous for a local
    /// subprocess that only writes one ~10KB file.
    static let corveilInstallTimeout: TimeInterval = 5.0

    /// Overall wall-clock budget across enumeration + *all* installs on the
    /// launch path (CROW-1039). Bounds the worst case when several installs are
    /// each slow-but-not-hung: once it is spent, no further subprocess starts. A
    /// single hung subprocess is bounded tighter, by ``corveilInstallTimeout``.
    static let corveilInstallBudget: TimeInterval = 10.0

    /// Shared warning text for a corveil binary that hangs during install —
    /// reused by the `list` bail-out and any per-skill timeout.
    static let timeoutWarning =
        "Corveil skill install timed out after \(Int(corveilInstallTimeout))s — binary may be hung. Check path in Settings."

    // MARK: - Bundled Templates

    /// The CLAUDE.md template bundled with the app.
    static func bundledCLAUDEMD() -> String {
        // Try loading from the repo's CLAUDE.md (for development builds)
        if let content = loadFromRepo("CLAUDE.md") {
            return content
        }
        // Try Bundle.main (for .app bundles)
        if let url = Bundle.main.url(forResource: "CLAUDE", withExtension: "md"),
           let content = try? String(contentsOf: url) {
            return content
        }
        // Minimal fallback
        return """
        # Crow — Manager Context

        See crow --help for CLI reference.
        All crow, gh, glab, and git worktree commands require dangerouslyDisableSandbox: true.
        Write temp files to $TMPDIR, not /tmp.

        ## Known Issues / Corrections
        """
    }

    /// The crow-workspace SKILL.md template bundled with the app.
    static func bundledSkill() -> String {
        if let content = loadFromRepo("skills/crow-workspace/SKILL.md") {
            return content
        }
        if let url = Bundle.main.url(forResource: "crow-workspace-SKILL.md", withExtension: "template"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return """
        # Crow Workspace Setup Skill

        ## Activation
        This skill activates when user invokes `/crow-workspace` command.

        ## Important
        All `crow` CLI and `git worktree` commands require `dangerouslyDisableSandbox: true`.
        See the CLAUDE.md in this directory for the full crow CLI reference.
        """
    }

    /// The crow-workspace setup.sh script bundled with the app.
    static func bundledSetupScript() -> String {
        if let content = loadFromRepo("skills/crow-workspace/setup.sh") {
            return content
        }
        if let url = Bundle.main.url(forResource: "crow-workspace-setup.sh", withExtension: "template"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return """
        #!/bin/bash
        echo '{"status":"error","message":"setup.sh not bundled"}'
        exit 1
        """
    }

    /// The crow-review-pr SKILL.md template bundled with the app.
    public static func bundledReviewSkill() -> String {
        if let content = loadFromRepo("skills/crow-review-pr/SKILL.md") {
            return content
        }
        if let url = Bundle.main.url(forResource: "crow-review-pr-SKILL.md", withExtension: "template"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return """
        # Crow Review PR Skill

        ## Activation
        This skill activates when user invokes `/crow-review-pr` command or in a review session.

        ## Important
        All `gh` commands require `dangerouslyDisableSandbox: true`.
        """
    }

    /// The crow-show-image SKILL.md — surfaces generated images in Crow's Images
    /// panel via the per-session `$CROW_ARTIFACTS_DIR` (CROW-593). The inline
    /// fallback is the complete skill, so scaffolding always writes a working
    /// copy even without the repo file or bundled template.
    public static func bundledShowImageSkill() -> String {
        if let content = loadFromRepo("skills/crow-show-image/SKILL.md") {
            return content
        }
        if let url = Bundle.main.url(forResource: "crow-show-image-SKILL.md", withExtension: "template"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return Self.showImageSkillBody
    }

    /// Canonical crow-show-image body — kept in code so the inline fallback and
    /// the repo/template sources stay identical.
    static let showImageSkillBody = """
    ---
    name: crow-show-image
    description: >-
      Surface an image you've generated (a diagram, chart, screenshot, or
      rendered figure) in Crow's Images panel so the user can see it inline.
      Use whenever you produce a visual artifact worth showing.
    ---

    # Crow: Show Image

    Make an image you've generated visible in Crow's Images panel (in the session
    detail), so the user sees it inline instead of just a file path.

    ## When to use

    Use this when you've produced an image the user should see — a diagram you
    drew, a chart, a screenshot, a rendered figure. Skip it for throwaway or
    intermediate images the user didn't ask about.

    Only works inside a Crow session, where `CROW_ARTIFACTS_DIR` is set.

    ## How

    1. Confirm you're in a Crow session — `CROW_ARTIFACTS_DIR` must be non-empty.
       If it's unset, there's no Crow panel to show it in; skip this.
    2. Copy the image into that directory (create it if needed), with a clear
       name:

       ```bash
       mkdir -p "$CROW_ARTIFACTS_DIR" && cp <image> "$CROW_ARTIFACTS_DIR/<name>.png"
       ```

    3. Tell the user it's viewable in Crow's Images panel.

    Supported: PNG, JPG, GIF, WEBP, SVG. The directory is ephemeral (cleared on
    restart) and lives outside the git worktree, so it never pollutes commits.
    """

    /// The `/crow-image` slash command body (user-facing front door to the
    /// Images panel). Inline fallback keeps it working without repo/template
    /// (CROW-593).
    public static func bundledImageCommand() -> String {
        if let content = loadFromRepo("commands/crow-image.md") {
            return content
        }
        if let url = Bundle.main.url(forResource: "crow-image-command.md", withExtension: "template"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return """
        ---
        description: Show an image in Crow's Images panel — pass the file path as the argument
        ---

        Make the image at `$ARGUMENTS` visible in Crow's Images panel:

        1. If `CROW_ARTIFACTS_DIR` is empty, this isn't a Crow session — tell the user and stop.
        2. Otherwise copy `$ARGUMENTS` into `$CROW_ARTIFACTS_DIR` (create it if needed), with a clear filename.
        3. Confirm the filename and that it now shows in Crow's Images panel.
        """
    }

    /// The crow-batch-workspace SKILL.md template bundled with the app.
    static func bundledBatchSkill() -> String {
        if let content = loadFromRepo("skills/crow-batch-workspace/SKILL.md") {
            return content
        }
        if let url = Bundle.main.url(forResource: "crow-batch-workspace-SKILL.md", withExtension: "template"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return """
        # Crow Batch Workspace Setup Skill

        ## Activation
        This skill activates when user invokes `/crow-batch-workspace` command.

        ## Important
        All `crow` CLI and `git worktree` commands require `dangerouslyDisableSandbox: true`.
        See the CLAUDE.md in this directory for the full crow CLI reference.
        """
    }

    /// The crow-create-ticket SKILL.md template bundled with the app.
    static func bundledCreateTicketSkill() -> String {
        if let content = loadFromRepo("skills/crow-create-ticket/SKILL.md") {
            return content
        }
        if let url = Bundle.main.url(forResource: "crow-create-ticket-SKILL.md", withExtension: "template"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return """
        # Crow Create Ticket

        ## Activation
        This skill activates when user invokes `/crow-create-ticket` command.

        ## Important
        Creates a GitHub issue (`gh`) or GitLab issue (`glab`) assigned to the current
        user and labeled `crow:auto`. All `gh`, `glab`, and `git` commands require
        `dangerouslyDisableSandbox: true`.
        """
    }

    /// Shared attribution footer instructions (issue #443).
    static func bundledAttributionFooter() -> String {
        if let content = loadFromRepo("skills/crow-attribution/FOOTER.md") {
            return content
        }
        if let url = Bundle.main.url(forResource: "crow-attribution-FOOTER.md", withExtension: "template"),
           let content = try? String(contentsOf: url) {
            return content
        }
        return CrowAttribution.sharedFooterInstructions
    }

    /// The pre-approved-permissions template, sourced from the repo's own
    /// `settings.json` (used as a bundled resource name, not a hint about
    /// the runtime destination — see `scaffold(...)`, which writes this
    /// content to `{devRoot}/.claude/settings.local.json`).
    public static func bundledSettings() -> String {
        if let content = loadFromRepo("settings.json") {
            return content
        }
        // Fallback
        return """
        {
          "permissions": {
            "allow": [
              "Bash(crow *)",
              "Bash(bash .claude/skills/crow-workspace/setup.sh *)",
              "Bash(.claude/skills/crow-workspace/setup.sh *)",
              "Bash(gh issue view:*)",
              "Bash(gh issue create:*)",
              "Bash(gh issue edit:*)",
              "Bash(gh api graphql:*)",
              "Bash(gh api repos:*)",
              "Bash(gh api user:*)",
              "Bash(gh label create:*)",
              "Bash(gh label list:*)",
              "Bash(gh pr view:*)",
              "Bash(gh pr create:*)",
              "Bash(gh workflow list:*)",
              "Bash(gh workflow view:*)",
              "Bash(gh workflow run:*)",
              "Bash(GITLAB_HOST=* glab issue view:*)",
              "Bash(GITLAB_HOST=* glab issue create:*)",
              "Bash(GITLAB_HOST=* glab mr view:*)",
              "Bash(GITLAB_HOST=* glab mr list:*)",
              "Bash(GITLAB_HOST=* glab api:*)",
              "Bash(GITLAB_HOST=* glab label create:*)",
              "Bash(acli jira workitem view:*)",
              "Bash(acli jira workitem search:*)",
              "Bash(acli jira workitem transition:*)",
              "Bash(acli jira workitem assign:*)",
              "Bash(acli jira workitem comment:*)",
              "Bash(acli jira workitem edit:*)",
              "Bash(acli jira workitem create:*)",
              "Bash(acli jira auth status:*)",
              "mcp__jira",
              "mcp__jira__*",
              "Bash(git -C:*)",
              "Write(.claude/prompts/**)",
              "Bash(git fetch:*)",
              "Bash(git worktree:*)",
              "Bash(git ls-remote:*)",
              "Bash(git branch:*)",
              "Bash(mkdir -p:*)",
              "Bash(cat >:*)",
              "Bash(ls:*)",
              "Bash(which:*)",
              "Bash(sleep:*)"
            ]
          }
        }
        """
    }

    /// Outcome of merging the bundled permissions template into an existing
    /// `settings.local.json`.
    ///
    /// - `.upToDate`: the on-disk file already has everything the template
    ///   would contribute. The caller skips the write entirely, so the file
    ///   is left completely alone — bytes, inode, mtime, and its owner-only
    ///   0o600 mode (which `ClaudeHookConfigWriter.writeGatewayEnv` applies
    ///   to the token-bearing `env` block) all survive untouched. This is
    ///   the steady state on every launch after the first.
    /// - `.write`: the payload must be persisted (a fresh file, or the merge
    ///   added something). The caller writes it, then re-asserts 0o600.
    enum SettingsMergeOutcome: Equatable {
        case upToDate
        case write(String)
    }

    /// Merges `template` into whatever's already on disk at `existingPath`,
    /// instead of overwriting it. Guarantees:
    ///
    /// - `permissions.allow`: the union of the template's and the existing
    ///   file's entries — any bundled entry the user's file is missing gets
    ///   appended, but nothing already there is ever removed.
    /// - Every other top-level key (`outputStyle`, `statusLine`, `hooks`,
    ///   `env`, a hand-edited `sandbox` block, …): filled in from the
    ///   template only if the user's file doesn't already have that key.
    ///   An existing value always wins, even if it differs from the
    ///   template.
    ///
    /// Returns `.upToDate` when there's nothing to add, so the caller skips
    /// the write and a user's formatting (and the file's mode) isn't churned
    /// on every launch. Returns `.write(template)` verbatim when there's no
    /// existing file yet, or it isn't valid JSON.
    static func mergeSettings(existingPath: String, template: String) -> SettingsMergeOutcome {
        guard let existingData = FileManager.default.contents(atPath: existingPath),
              String(data: existingData, encoding: .utf8) != nil,
              let existingObj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
              let templateData = template.data(using: .utf8),
              let templateObj = try? JSONSerialization.jsonObject(with: templateData) as? [String: Any]
        else {
            return .write(template)
        }

        var merged = existingObj
        var changed = false

        for (key, templateValue) in templateObj {
            if key == "permissions", let templatePerms = templateValue as? [String: Any] {
                var mergedPerms = merged["permissions"] as? [String: Any] ?? [:]
                let templateAllow = templatePerms["allow"] as? [String] ?? []
                let existingAllow = mergedPerms["allow"] as? [String] ?? []
                let existingSet = Set(existingAllow)
                let missing = templateAllow.filter { !existingSet.contains($0) }
                if !missing.isEmpty {
                    mergedPerms["allow"] = existingAllow + missing
                    merged["permissions"] = mergedPerms
                    changed = true
                }
            } else if merged[key] == nil {
                merged[key] = templateValue
                changed = true
            }
        }

        // Nothing to add — leave the on-disk file untouched (skip the write).
        guard changed else { return .upToDate }

        // Serialization can't realistically fail on a dict we just built from
        // valid JSON, but if it did there's no better content to write than
        // what's already there — so skip rather than churn/relax the file.
        guard let mergedData = try? JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys]
        ), let mergedString = String(data: mergedData, encoding: .utf8) else {
            return .upToDate
        }
        return .write(mergedString)
    }

    /// Try to load a file from the repo root (for development builds).
    private static func loadFromRepo(_ relativePath: String) -> String? {
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        var dir = execURL.deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let filePath = dir.appendingPathComponent(relativePath)
                if let content = try? String(contentsOf: filePath) {
                    return content
                }
                CrowLog.info("[Scaffolder] File not found at repo path: \(filePath.path)")
                return nil
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

/// SIGTERM a `Process` after `deadline` seconds if it's still running. Used
/// to bound `waitUntilExit` without a polling loop (a polling loop on
/// `proc.isRunning` consumes the exit observation Foundation needs to run
/// its pipe-write-FD cleanup, so post-exit `readToEnd()` reads return empty).
/// `internal`, not `fileprivate`: `CorveilCLI.verify` bounds its `--version`
/// subprocess the same way, and it is the same watchdog rather than a copy. (It
/// used to duplicate `SettingsView`'s `TimeoutWatchdog` — that target is gone
/// with the macOS app, so the duplication went with it.)
final class ScaffolderTimeoutWatchdog: @unchecked Sendable {
    private let proc: Process
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var didFire = false

    init(deadline: TimeInterval, proc: Process) {
        self.proc = proc
        self.timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        self.timer.schedule(deadline: .now() + deadline)
    }

    func start() {
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.didFire = true
            self.lock.unlock()
            if self.proc.isRunning {
                self.proc.terminate()
            }
        }
        timer.resume()
    }

    /// Cancel the watchdog. Returns true if it had already fired (timeout).
    func cancel() -> Bool {
        timer.cancel()
        lock.lock(); defer { lock.unlock() }
        return didFire
    }
}
