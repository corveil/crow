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
