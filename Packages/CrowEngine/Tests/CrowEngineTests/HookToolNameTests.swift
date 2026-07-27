import Foundation
import Testing
import CrowIPC
@testable import CrowEngine

/// Unit tests for the `hookToolName` payload-shape normalizer used by the
/// `hook-event` router (#862 review). Locks the two shapes: a flat `tool_name`
/// (Claude/Cursor/Codex) and Antigravity's nested `toolCall.name`.
@Suite("hookToolName")
struct HookToolNameTests {
    @Test func readsFlatToolName() {
        let payload: [String: JSONValue] = ["tool_name": .string("Bash")]
        #expect(hookToolName(from: payload) == "Bash")
    }

    @Test func readsNestedToolCallName() {
        // Antigravity's PreToolUse shape: { "toolCall": { "name": "run_command" } }
        let payload: [String: JSONValue] = [
            "toolCall": .object(["name": .string("run_command")]),
        ]
        #expect(hookToolName(from: payload) == "run_command")
    }

    @Test func flatWinsOverNested() {
        let payload: [String: JSONValue] = [
            "tool_name": .string("Bash"),
            "toolCall": .object(["name": .string("run_command")]),
        ]
        #expect(hookToolName(from: payload) == "Bash")
    }

    @Test func nilWhenNeitherPresent() {
        // Antigravity's PostToolUse shape carries no tool name — helper returns nil
        // (the documented Tier-2 gap), never a bogus value.
        let payload: [String: JSONValue] = ["stepIdx": .int(5), "error": .string("")]
        #expect(hookToolName(from: payload) == nil)
    }
}
