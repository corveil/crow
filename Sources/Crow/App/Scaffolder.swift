import CrowCore
import Foundation

/// Creates the devRoot directory structure and copies bundled resources.
struct Scaffolder {
    let devRoot: String

    /// Create the full workspace scaffold.
    func scaffold(workspaceNames: [String]) throws {
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
        try skillTemplate.write(toFile: skillPath, atomically: true, encoding: .utf8)

        // Always overwrite setup.sh with the latest version and make executable
        let setupScriptPath = (skillsDir as NSString).appendingPathComponent("setup.sh")
        let setupScript = Self.bundledSetupScript()
        try setupScript.write(toFile: setupScriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: setupScriptPath)

        // Always overwrite the review-pr skill with the latest version
        let reviewSkillPath = (reviewSkillsDir as NSString).appendingPathComponent("SKILL.md")
        let reviewSkillTemplate = Self.bundledReviewSkill()
        try reviewSkillTemplate.write(toFile: reviewSkillPath, atomically: true, encoding: .utf8)

        // Always overwrite the batch-workspace skill with the latest version
        let batchSkillPath = (batchSkillsDir as NSString).appendingPathComponent("SKILL.md")
        let batchSkillTemplate = Self.bundledBatchSkill()
        try batchSkillTemplate.write(toFile: batchSkillPath, atomically: true, encoding: .utf8)

        // Always overwrite the create-ticket skill with the latest version
        let createTicketSkillPath = (createTicketSkillsDir as NSString).appendingPathComponent("SKILL.md")
        let createTicketSkillTemplate = Self.bundledCreateTicketSkill()
        try createTicketSkillTemplate.write(toFile: createTicketSkillPath, atomically: true, encoding: .utf8)

        // Shared attribution footer rules (issue #443)
        let attributionFooterPath = (attributionSkillsDir as NSString).appendingPathComponent("FOOTER.md")
        try Self.bundledAttributionFooter().write(toFile: attributionFooterPath, atomically: true, encoding: .utf8)

        // Always overwrite settings.json (permissions for crow, gh, git commands)
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.json")
        let settingsTemplate = Self.bundledSettings()
        try settingsTemplate.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        // Create prompts directory for crow-workspace prompt files
        let promptsDir = (claudeDir as NSString).appendingPathComponent("prompts")
        try fm.createDirectory(atPath: promptsDir, withIntermediateDirectories: true)
    }

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

    /// The settings.json template with pre-approved permissions.
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
