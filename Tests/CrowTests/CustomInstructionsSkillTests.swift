import Foundation
import Testing

/// Regression guard for issue #683: new-workspace creation must inject the
/// **matched** workspace's `customInstructions` into the worker prompt.
///
/// Workspace/session creation is driven by the `/crow-workspace` (and
/// `/crow-batch-workspace`) skill — the Manager Claude Code writes the prompt
/// file per those instructions; no Swift code assembles the creation prompt. So
/// the fix surface, and what these tests guard, is the skill instruction itself:
/// each skill (and its bundled `Resources/*.template`, which release builds
/// scaffold from — see [[crow-scaffolded-docs-dual-source]]) must tell the
/// Manager to resolve the matched workspace's `customInstructions` and append a
/// verbatim `## Custom Instructions` section, without falling back to `defaults`
/// or another workspace.
@Suite("Workspace custom-instructions skill guard")
struct CustomInstructionsSkillTests {

    /// Walk up from this test source file until we find Package.swift; return the repo root.
    private static func repoRoot(file: StaticString = #file) -> URL {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path
            ) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Package.swift walking up from \(file)")
        return URL(fileURLWithPath: "/")
    }

    private static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The `/crow-workspace` skill and its bundled template are dual-sourced —
    /// `Scaffolder` copies the template into new dev roots, while the live skill
    /// runs in this repo — so a fix must land in both or scaffolded installs
    /// silently regress.
    private static let workspaceFiles = [
        "skills/crow-workspace/SKILL.md",
        "Resources/crow-workspace-SKILL.md.template",
    ]

    private static let batchFiles = [
        "skills/crow-batch-workspace/SKILL.md",
        "Resources/crow-batch-workspace-SKILL.md.template",
    ]

    @Test func crowWorkspaceResolvesMatchedWorkspaceCustomInstructions() throws {
        for path in Self.workspaceFiles {
            let body = try Self.read(path)

            #expect(body.contains("Resolve custom instructions"),
                "\(path) must contain an explicit 'Resolve custom instructions' step so the Manager resolves the value before writing the prompt (issue #683).")
            #expect(body.contains("workspaces[\"{workspace}\"].customInstructions"),
                "\(path) must point the Manager at the matched workspace's `workspaces[\"{workspace}\"].customInstructions`, not a generic 'the config' lookup.")
            #expect(body.contains("{custom_instructions}"),
                "\(path) must thread the resolved `{custom_instructions}` token into the `## Custom Instructions` template block.")
            #expect(body.contains("## Custom Instructions"),
                "\(path) must keep the `## Custom Instructions` heading in the prompt template.")
            #expect(body.contains("verbatim"),
                "\(path) must require the custom instructions be included verbatim.")
            #expect(body.contains("do not** read `defaults`"),
                "\(path) must explicitly forbid falling back to `defaults` when resolving customInstructions (issue #683 acceptance criteria).")
        }
    }

    @Test func crowBatchWorkspaceResolvesMatchedWorkspaceCustomInstructions() throws {
        for path in Self.batchFiles {
            let body = try Self.read(path)

            #expect(body.contains("workspaces[\"{workspace}\"].customInstructions"),
                "\(path) must resolve the matched workspace's `customInstructions` per session so batch creation doesn't drop the section (issue #683).")
            #expect(body.contains("## Custom Instructions"),
                "\(path) must reference appending the `## Custom Instructions` section.")
            #expect(body.contains("not `defaults`"),
                "\(path) must forbid the `defaults` fallback when resolving per-workspace customInstructions.")
        }
    }
}
