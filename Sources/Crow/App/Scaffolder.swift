import CrowClaude
import CrowCore
import Foundation

/// Outcome of a single `Scaffolder.scaffold(...)` run. `warning` is non-nil only
/// for non-fatal post-scaffold issues (today: a configured `corveil` binary
/// that's missing/non-executable or whose `skill install` returned non-zero).
/// Callers surface it via `AppState.corveilSkillInstallWarning`; never fatal.
struct ScaffoldResult {
    var warning: String?
}

/// Creates the devRoot directory structure and copies bundled resources.
struct Scaffolder {
    let devRoot: String

    /// Create the full workspace scaffold.
    ///
    /// `managerAgentKind` drives `{{CROW_AGENT_DISPLAY_NAME}}` substitution in the
    /// dev-root skill bodies (issue #447). The Manager session is the consumer of
    /// these files, so its agent kind is the right one to bake in.
    ///
    /// `corveilBinaryPath`, when set and executable, triggers a post-scaffold
    /// `corveil skill install --path {devRoot}/.claude/commands/query-corveil.md`
    /// so the embedded `/query-corveil` slash command stays in sync with the
    /// user's locally-built corveil binary (CROW-482). Failures here are
    /// non-fatal: they are returned as `ScaffoldResult.warning` and never
    /// throw — the rest of the scaffold has already succeeded by that point.
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
    func scaffold(workspaceNames: [String],
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

        // Create crow-reviews directory for PR review clones
        let reviewsDir = (devRoot as NSString).appendingPathComponent("crow-reviews")
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
        // only what's missing and leaves the file untouched when there's
        // nothing to add.
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")
        let settingsTemplate = Self.bundledSettings()
        let mergedSettings = Self.mergeSettings(existingPath: settingsPath, template: settingsTemplate)
        try mergedSettings.write(toFile: settingsPath, atomically: true, encoding: .utf8)

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
        installCrowCLISymlink(claudeDir: claudeDir, appCrowPath: appCrowBinaryPath)

        // Re-install the embedded /query-corveil slash command from the
        // user-configured corveil binary on every launch (CROW-482). Failure
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
            NSLog("[Scaffolder] could not create bin dir %@: %@", binDir, error.localizedDescription)
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
                    NSLog("[Scaffolder] defaults.binaries.%@ not executable at %@ — skipping symlink",
                          name, trimmed)
                }
                continue
            }
            try? fm.removeItem(atPath: link)
            do {
                try fm.createSymbolicLink(atPath: link, withDestinationPath: trimmed)
            } catch {
                NSLog("[Scaffolder] failed to symlink %@ -> %@: %@",
                      link, trimmed, error.localizedDescription)
            }
        }
    }

    /// Always materialize `{devRoot}/.claude/bin/crow` pointing at the running
    /// app's own CLI (CROW-552). Independent of `defaults.binaries` so every
    /// agent kind discovers `crow` via the tmux shell wrapper's PATH prepend.
    /// Runs after `installBinarySymlinks`, so a user-set
    /// `defaults.binaries["crow"]` is overwritten here by design — the app
    /// binary always wins for PATH discovery.
    /// Idempotent — re-run on every scaffold pass; only ever owns symlinks.
    private func installCrowCLISymlink(claudeDir: String, appCrowPath: String?) {
        let fm = FileManager.default
        let binDir = (claudeDir as NSString).appendingPathComponent("bin")
        let link = (binDir as NSString).appendingPathComponent("crow")
        let resolved = appCrowPath ?? ClaudeHookConfigWriter.appCrowBinary()

        guard let target = resolved, fm.isExecutableFile(atPath: target) else {
            if let attrs = try? fm.attributesOfItem(atPath: link),
               (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                try? fm.removeItem(atPath: link)
            }
            if let resolved {
                NSLog("[Scaffolder] app crow binary not executable at %@ — skipping symlink", resolved)
            }
            return
        }

        // Drive off attributesOfItem, not fileExists — the latter follows
        // symlinks, so a dangling `crow` link (target moved/deleted) looks
        // absent and we'd skip removal, then createSymbolicLink hits EEXIST.
        if let attrs = try? fm.attributesOfItem(atPath: link) {
            guard (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else {
                NSLog("[Scaffolder] crow exists at %@ but is not a symlink — leaving alone", link)
                return
            }
            try? fm.removeItem(atPath: link)
        }

        do {
            try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        } catch {
            NSLog("[Scaffolder] failed to symlink %@ -> %@: %@",
                  link, target, error.localizedDescription)
        }
    }

    /// Runs `<corveilBinaryPath> skill install --path {devRoot}/.claude/commands/query-corveil.md`
    /// when the path is set and points at an executable. Returns a short
    /// user-facing warning string on failure; `nil` on success or when the
    /// feature is unconfigured (empty/nil path).
    ///
    /// `Scaffolder.scaffold(...)` runs on the main thread during
    /// `applicationDidFinishLaunching`, so a hung corveil binary (wrong
    /// executable, stdin prompt, etc.) would freeze app startup with no
    /// window drawn yet. The hard wall-clock timeout bounds the worst case:
    /// after `corveilInstallTimeout` seconds the process is sent SIGTERM and
    /// the install reports a warning rather than blocking forever.
    ///
    /// Internal, not private — Settings calls this directly via callbacks
    /// wired in `AppDelegate.launchMainApp`: when the user picks a new
    /// corveil binary (CROW-490) and when the user clicks "Reinstall skill"
    /// (CROW-491). Both avoid the "must restart Crow" gap of the per-launch
    /// path. SettingsView itself lives in CrowUI and cannot import the app
    /// target, so closure injection through `AppState` is the only path.
    /// Settings-side callers dispatch off the main thread (`Task.detached`)
    /// so the 5s worst-case doesn't freeze the Settings window.
    func installCorveilSkill(_ corveilBinaryPath: String?) -> String? {
        guard let path = corveilBinaryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: path) else {
            NSLog("[Scaffolder] corveil binary not executable: %@", path)
            return "Corveil skill install skipped — binary at \(path) is missing or not executable. Check Settings → General → Corveil CLI."
        }

        let commandsDir = (devRoot as NSString).appendingPathComponent(".claude/commands")
        do {
            try fm.createDirectory(atPath: commandsDir, withIntermediateDirectories: true)
        } catch {
            NSLog("[Scaffolder] could not create commands dir: %@", error.localizedDescription)
            return "Corveil skill install failed — could not create .claude/commands directory."
        }
        let target = (commandsDir as NSString).appendingPathComponent("query-corveil.md")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["skill", "install", "--path", target]
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        // Discard stdout explicitly. We don't surface corveil's diagnostic
        // line, and routing to /dev/null is deadlock-proof — an undrained
        // `Pipe()` would block the child if it ever wrote >64KB before exit.
        proc.standardOutput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            NSLog("[Scaffolder] corveil launch failed: %@", error.localizedDescription)
            return "Corveil skill install failed — \(error.localizedDescription). Check path in Settings."
        }

        // Watchdog: SIGTERM after `corveilInstallTimeout` so a hung binary
        // unblocks `waitUntilExit`. The watchdog records the timeout so we
        // can distinguish exit-N from wall-clock kill below. `waitUntilExit`
        // (not a polling loop) is what triggers Foundation's pipe-write-FD
        // cleanup, which is the only way the post-exit `readToEnd()` below
        // reliably sees EOF.
        let watchdog = ScaffolderTimeoutWatchdog(deadline: Self.corveilInstallTimeout, proc: proc)
        watchdog.start()
        proc.waitUntilExit()
        let timedOut = watchdog.cancel()

        if timedOut {
            NSLog("[Scaffolder] corveil skill install timed out after %.1fs", Self.corveilInstallTimeout)
            return "Corveil skill install timed out after \(Int(Self.corveilInstallTimeout))s — binary may be hung. Check path in Settings."
        }
        if proc.terminationStatus != 0 {
            let stderr = (try? stderrPipe.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("[Scaffolder] corveil skill install exit=%d stderr=%@",
                  proc.terminationStatus, stderr)
            let detail = stderr.isEmpty ? "exit code \(proc.terminationStatus)" : stderr
            return "Corveil skill install failed — \(detail). Check path in Settings."
        }
        NSLog("[Scaffolder] corveil skill installed at %@", target)
        return nil
    }

    /// Wall-clock budget for the per-launch `corveil skill install` run. Tight
    /// because `Scaffolder.scaffold(...)` runs on the main thread before the
    /// app window is shown — a hung corveil binary delays first paint by this
    /// many seconds. 5s is generous for a local subprocess that only writes
    /// one ~10KB file.
    static let corveilInstallTimeout: TimeInterval = 5.0

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
    static func bundledReviewSkill() -> String {
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
    static func bundledSettings() -> String {
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
    /// Returns the existing file's contents byte-for-byte, untouched, when
    /// there's nothing to add — so a user's formatting isn't churned on
    /// every launch. Falls back to `template` verbatim when there's no
    /// existing file yet, or it isn't valid JSON.
    static func mergeSettings(existingPath: String, template: String) -> String {
        guard let existingData = FileManager.default.contents(atPath: existingPath),
              let existingString = String(data: existingData, encoding: .utf8),
              let existingObj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
              let templateData = template.data(using: .utf8),
              let templateObj = try? JSONSerialization.jsonObject(with: templateData) as? [String: Any]
        else {
            return template
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

        guard changed else { return existingString }

        guard let mergedData = try? JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys]
        ), let mergedString = String(data: mergedData, encoding: .utf8) else {
            return existingString
        }
        return mergedString
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
                NSLog("[Scaffolder] File not found at repo path: %@", filePath.path)
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
/// Mirrors `SettingsView`'s `TimeoutWatchdog`; duplicated here because
/// Scaffolder and SettingsView live in different targets with no shared
/// private utility module today, and the helper is small enough that two
/// copies beat introducing a CrowCore type for two callers.
fileprivate final class ScaffolderTimeoutWatchdog: @unchecked Sendable {
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
