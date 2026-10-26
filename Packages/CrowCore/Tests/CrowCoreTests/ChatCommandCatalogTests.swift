import Foundation
import Testing
@testable import CrowCore

/// The Chat view's `/` menu source. Every root is a temp directory — never the
/// operator's real `~/.claude` (ADR 0012).
@Suite struct ChatCommandCatalogTests {
    private func tree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-commands-\(UUID().uuidString)", isDirectory: true)
        for (path, body) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
        return root
    }

    @Test func discoversSkillsCommandsAndBuiltinsWithProjectPrecedence() throws {
        let root = try tree([
            "proj/.claude/skills/review-pr/SKILL.md": "---\nname: review-pr\ndescription: Project review\n---\nbody",
            "proj/.claude/skills/hidden/SKILL.md": "---\ndescription: internal\nuser-invocable: no\n---\n",
            "proj/.claude/skills/notaskill/README.md": "nothing",
            "proj/.claude/commands/ship.md": "# Ship the branch\nDo it.",
            "home/skills/review-pr/SKILL.md": "---\ndescription: User review\n---\n",
            "home/skills/folded/SKILL.md": "---\ndescription: >\n  Folded block\n  scalar text\nname: x\n---\n",
            "home/commands/compact.md": "---\ndescription: \"user compact\"\n---\n",
            "home/commands/notes.txt": "ignored",
            "home/skills/wordy/SKILL.md": "---\ndescription: " + String(repeating: "w", count: 5_000) + "\n---\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let cmds = ChatCommandCatalog.discover(.init(
            projectDir: root.appendingPathComponent("proj").path,
            userClaudeDir: root.appendingPathComponent("home").path))
        let byName = Dictionary(uniqueKeysWithValues: cmds.map { ($0.name, $0) })

        #expect(byName["review-pr"]?.description == "Project review")
        #expect(byName["review-pr"]?.scope == .project)
        #expect(byName["hidden"] == nil)
        #expect(byName["notaskill"] == nil)
        #expect(byName["ship"] == ChatCommand(name: "ship", description: "Ship the branch", kind: .command, scope: .project))
        #expect(byName["folded"]?.description == "Folded block scalar text")
        // A user command named like a built-in wins over the built-in.
        #expect(byName["compact"]?.kind == .command && byName["compact"]?.description == "user compact")
        #expect(byName["context"]?.kind == .builtin)
        #expect(byName["clear"]?.kind == .builtin)
        #expect(cmds.map(\.name) == cmds.map(\.name).sorted())
        #expect(byName["wordy"]?.description.count == ChatCommandCatalog.maxDescriptionChars)
    }

    @Test func enabledPluginSkillsArePrefixed() throws {
        let root = try tree([
            "home/plugins/cache/tools/.claude-plugin/plugin.json": #"{"name":"toolkit"}"#,
            "home/plugins/cache/tools/skills/lint/SKILL.md": "---\ndescription: Lint it\n---\n",
            "home/plugins/cache/off/skills/nope/SKILL.md": "---\ndescription: disabled\n---\n",
            "home/settings.json": #"{"enabledPlugins":{"tools@market":true,"off@market":false}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let installed: [String: Any] = ["plugins": [
            "tools@market": [["scope": "user", "installPath": home.appendingPathComponent("plugins/cache/tools").path]],
            "off@market": [["scope": "user", "installPath": home.appendingPathComponent("plugins/cache/off").path]],
        ]]
        try JSONSerialization.data(withJSONObject: installed)
            .write(to: home.appendingPathComponent("plugins/installed_plugins.json"))

        let cmds = ChatCommandCatalog.discover(.init(projectDir: nil, userClaudeDir: home.path))
        #expect(cmds.contains(ChatCommand(name: "toolkit:lint", description: "Lint it", kind: .skill, scope: .plugin)))
        #expect(!cmds.contains { $0.name.contains("nope") })
    }

    @Test func parentFoldersAreSearchedUpToTheGitRoot() throws {
        // devroot/.claude/skills/crow-workspace   ← Crow's bundled skills
        // devroot/repo-wt (a git worktree: `.git` is a file)
        // devroot/.crow/managers/m1 (no git)
        let root = try tree([
            "devroot/.claude/skills/crow-workspace/SKILL.md": "---\ndescription: devroot skill\n---\n",
            "devroot/.claude/commands/crow-runner.md": "Run things",
            "devroot/repo-wt/.git": "gitdir: /elsewhere/.git/worktrees/repo-wt",
            "devroot/repo-wt/.claude/skills/repo-skill/SKILL.md": "---\ndescription: repo\n---\n",
            "devroot/repo-wt/sub/.claude/commands/nested.md": "Nested command",
            "devroot/.crow/managers/m1/README.md": "manager",
            "devroot/.crow/managers/m1/.claude/commands/crow-runner.md": "Manager override",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        func names(_ dir: String) -> Set<String> {
            Set(ChatCommandCatalog.discover(.init(
                projectDir: root.appendingPathComponent(dir).path, userClaudeDir: home)).map(\.name))
        }

        // Inside a git worktree: the walk stops at the worktree root.
        let wt = names("devroot/repo-wt/sub")
        #expect(wt.contains("nested") && wt.contains("repo-skill"))
        #expect(!wt.contains("crow-workspace") && !wt.contains("crow-runner"))

        // A Manager folder (no git) reaches devroot's skills; the nearer copy wins.
        let mgr = ChatCommandCatalog.discover(.init(
            projectDir: root.appendingPathComponent("devroot/.crow/managers/m1").path, userClaudeDir: home))
        #expect(mgr.contains { $0.name == "crow-workspace" && $0.scope == .project })
        #expect(mgr.first { $0.name == "crow-runner" }?.description == "Manager override")

        // The folder holding the user config dir is not treated as a project.
        let dirs = ChatCommandCatalog.projectSearchDirs(
            from: root.appendingPathComponent("devroot/.crow/managers/m1").path,
            userClaudeDir: root.appendingPathComponent(".claude").path)
        #expect(dirs.first == root.appendingPathComponent("devroot/.crow/managers/m1").standardizedFileURL.path)
        #expect(!dirs.contains(root.standardizedFileURL.path))
    }

    @Test func projectFilesMustBeRegularAndInsideTheProject() throws {
        let root = try tree([
            "secret/key.md": "---\ndescription: TOP-SECRET\n---\n",
            "secret/dir/stolen.md": "---\ndescription: ALSO-SECRET\n---\n",
            "proj/.git": "gitdir: x",
            "proj/.claude/commands/ok.md": "---\ndescription: fine\n---\n",
            "home/skills/dot/SKILL.md": "---\ndescription: user symlink target\n---\n",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let proj = root.appendingPathComponent("proj")
        // A committed symlink to an operator file, a symlinked commands subdir,
        // a symlinked skill folder, and a FIFO with no writer.
        try fm.createSymbolicLink(atPath: proj.appendingPathComponent(".claude/commands/leak.md").path,
                                  withDestinationPath: root.appendingPathComponent("secret/key.md").path)
        try fm.createDirectory(at: proj.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: proj.appendingPathComponent(".claude/skills/stolen").path,
                                  withDestinationPath: root.appendingPathComponent("secret/dir").path)
        try Data("---\ndescription: VIA-DIR\n---\n".utf8)
            .write(to: root.appendingPathComponent("secret/dir/SKILL.md"))
        #expect(mkfifo(proj.appendingPathComponent(".claude/commands/fifo.md").path, 0o600) == 0)
        // The operator's own symlinked user skill stays allowed.
        let userSkill = root.appendingPathComponent("home/skills/linked")
        try fm.createSymbolicLink(atPath: userSkill.path,
                                  withDestinationPath: root.appendingPathComponent("home/skills/dot").path)

        let started = Date()
        let cmds = ChatCommandCatalog.discover(.init(
            projectDir: proj.path, userClaudeDir: root.appendingPathComponent("home").path))
        #expect(Date().timeIntervalSince(started) < 2, "a FIFO must not block discovery")
        let byName = Dictionary(uniqueKeysWithValues: cmds.map { ($0.name, $0) })
        #expect(byName["ok"]?.description == "fine")
        #expect(byName["leak"] == nil)
        #expect(byName["fifo"] == nil)
        #expect(byName["stolen"] == nil)
        #expect(!cmds.contains { $0.description.contains("SECRET") || $0.description.contains("VIA-DIR") })
        #expect(byName["linked"]?.description == "user symlink target")
    }

    @Test func pluginPrefixMustBeOneToken() {
        #expect(ChatCommandCatalog.commandName("lint", prefix: "toolkit") == "toolkit:lint")
        #expect(ChatCommandCatalog.commandName("lint", prefix: "bad name") == nil)
        #expect(ChatCommandCatalog.commandName("lint", prefix: "a:b") == nil)
        #expect(ChatCommandCatalog.commandName("lint", prefix: "") == nil)
    }

    @Test func missingRootsYieldOnlyBuiltins() {
        let cmds = ChatCommandCatalog.discover(.init(projectDir: "/nonexistent/p", userClaudeDir: "/nonexistent/h"))
        #expect(cmds.map(\.name) == ["clear", "compact", "context"])
    }

    @Test func frontmatterParsing() {
        let f = ChatCommandCatalog.frontmatter("---\nname: 'quoted'\ndescription: has: colon\n  nested: ignored\n---\nbody")
        #expect(f["name"] == "quoted")
        #expect(f["description"] == "has: colon")
        #expect(f["nested"] == nil)
        #expect(ChatCommandCatalog.frontmatter("no frontmatter").isEmpty)
        #expect(ChatCommandCatalog.parseBool("Off") == false)
        #expect(ChatCommandCatalog.commandName("bad name", prefix: nil) == nil)
    }
}
