import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

@Suite("Todo RPC support (CROW-1231)")
struct TodoRPCSupportTests {
    @Test func decodeTextTrimsAndRejectsBlank() throws {
        #expect(try TodoRPC.decodeText(.string("  idea \n")) == "idea")
        #expect(throws: RPCError.self) { _ = try TodoRPC.decodeText(nil) }
        #expect(throws: RPCError.self) { _ = try TodoRPC.decodeText(.string("   ")) }
    }

    @Test func decodePriorityNormalizes() throws {
        #expect(try TodoRPC.decodePriority(.string("P2")) == "p2")
        #expect(try TodoRPC.decodePriority(nil) == nil)
        #expect(throws: RPCError.self) { _ = try TodoRPC.decodePriority(.string("high")) }
    }

    @Test func decodeStateRejectsUnknown() {
        #expect(throws: RPCError.self) { _ = try TodoRPC.decodeState(.string("maybe")) }
    }

    @Test func decodeTagsRejectsNonStrings() {
        #expect(throws: RPCError.self) {
            _ = try TodoRPC.decodeTags(.array([.string("a"), .int(1)]))
        }
    }

    @Test func filteredByStateAndTag() throws {
        let ios = TodoItem(text: "a", tags: ["ios"], state: .captured)
        let cli = TodoItem(text: "b", tags: ["cli"], state: .exploring)
        let items = [ios, cli]
        let byState = try TodoRPC.filtered(items, params: ["state": .string("captured")])
        #expect(byState.map(\.id) == [ios.id])
        let byTag = try TodoRPC.filtered(items, params: ["tag": .string("CLI")])
        #expect(byTag.map(\.id) == [cli.id])
    }

    @Test func applyingEditPatchesOnlyProvidedFields() throws {
        let item = TodoItem(text: "original", note: "n", tags: ["ios"], priority: "p3")
        let edited = try TodoRPC.applyingEdit(item, params: [
            "text": .string("changed"),
            "add_tags": .array([.string("cli")]),
            "remove_tags": .array([.string("ios")]),
        ])
        #expect(edited.text == "changed")
        #expect(edited.note == "n")
        #expect(edited.tags == ["cli"])
        #expect(edited.priority == "p3")
        #expect(edited.updatedAt >= item.updatedAt)
    }

    @Test func todoJSONUsesSnakeCaseKeysAndISO8601Dates() throws {
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        let sessionID = UUID()
        let item = TodoItem(
            text: "scratch",
            note: "note",
            tags: ["crow"],
            priority: "p1",
            state: .exploring,
            links: [TodoLink(type: .session, sessionID: sessionID, label: "explore")],
            createdAt: created,
            updatedAt: created
        )
        let object = try #require(TodoRPC.todoJSON(item).objectValue)
        #expect(object["id"] == .string(item.id.uuidString))
        #expect(object["text"] == .string("scratch"))
        #expect(object["created_at"] == .string(ISO8601DateFormatter().string(from: created)))
        #expect(object["state"] == .string("exploring"))
        let link = try #require(object["links"]?.arrayValue?.first?.objectValue)
        #expect(link["session_id"] == .string(sessionID.uuidString))
        #expect(link["type"] == .string("session"))
    }

    @Test func managerNameCollapsesWhitespaceAndFallsBack() {
        #expect(TodoRPC.managerName(from: "  native   scratch\nlist ") == "native scratch list")
        #expect(TodoRPC.managerName(from: "   ") == "Scratch")
        #expect(TodoRPC.managerName(from: String(repeating: "x", count: 90)).count == 80)
    }

    @Test func exploreBriefIsNewlineTerminatedAndOmitsEmptyNote() {
        let item = TodoItem(text: "try this", tags: ["ios"], priority: "p2")
        let brief = TodoRPC.exploreBrief(for: item)
        #expect(brief.hasSuffix("\n"))
        #expect(brief.contains("## Scratch item"))
        #expect(!brief.contains("## Idea"))
        #expect(!brief.localizedCaseInsensitiveContains("idea"))
        #expect(brief.contains("try this"))
        #expect(brief.contains("Start now"))
        #expect(brief.contains("inspect related code"))
        #expect(!brief.contains("## Notes"))
        #expect(brief.contains("Tags: ios"))
        #expect(brief.contains("Priority: p2"))
        #expect(brief.contains("Do not file a ticket"))
    }

    @Test func seedLaunchCommandIsJobStyleEvalAndEndOfOptionsForCursor() {
        let path = "/tmp/crow-explore.md"
        let cursor = TodoRPC.seedLaunchCommand(
            baseCommand: "'/opt/homebrew/bin/cursor-agent' --trust",
            promptPath: path, agentKind: .cursor)
        #expect(cursor.contains("_CROW_P=$(< '/tmp/crow-explore.md')"))
        #expect(cursor.contains("-- "))
        #expect(TodoRPC.seedsExplorePromptWithEndOfOptions(.cursor))
        #expect(TodoRPC.seedsExplorePromptWithEndOfOptions(.grok))
        #expect(!TodoRPC.seedsExplorePromptWithEndOfOptions(.claudeCode))
        let claude = TodoRPC.seedLaunchCommand(
            baseCommand: "claude --permission-mode auto",
            promptPath: path, agentKind: .claudeCode)
        #expect(claude.contains("_CROW_P=$(< '/tmp/crow-explore.md')"))
        #expect(!claude.contains("-- $(printf"))
    }

    @Test func paneLooksLikeAgentRejectsShellsAndAcceptsHarnessTokens() {
        #expect(!TodoRPC.paneLooksLikeAgent(""))
        #expect(!TodoRPC.paneLooksLikeAgent("zsh"))
        #expect(!TodoRPC.paneLooksLikeAgent("/bin/bash"))
        #expect(!TodoRPC.paneLooksLikeAgent("crow-shell-wrapper.sh"))
        #expect(!TodoRPC.paneLooksLikeAgent("ssh-agent"))
        #expect(TodoRPC.paneLooksLikeAgent("cursor-agent"))
        #expect(TodoRPC.paneLooksLikeAgent("/Users/x/.local/bin/cursor-agent"))
        #expect(TodoRPC.paneLooksLikeAgent("claude"))
        #expect(TodoRPC.paneLooksLikeAgent("agent"))
        #expect(TodoRPC.paneLooksLikeAgent("codex"))
    }

    @Test func promptWasAcceptedOnSubmitOrWorking() {
        #expect(TodoRPC.promptWasAccepted(
            hookEventNames: ["SessionStart", "UserPromptSubmit"], activity: .idle))
        #expect(TodoRPC.promptWasAccepted(hookEventNames: ["SessionStart"], activity: .working))
        #expect(TodoRPC.promptWasAccepted(hookEventNames: [], activity: .waiting))
        #expect(!TodoRPC.promptWasAccepted(hookEventNames: ["SessionStart"], activity: .idle))
        #expect(!TodoRPC.promptWasAccepted(hookEventNames: [], activity: .done))
    }

    @Test func ticketBodyIncludesNoteAndScratchAttribution() {
        let item = TodoItem(text: "x", note: "details", tags: ["web"])
        let body = TodoRPC.ticketBody(for: item)
        #expect(body.contains("details"))
        #expect(body.contains("Tags: web"))
        #expect(body.contains("Filed from Crow Scratch."))
    }

    @Test func shouldRetryEnterOnlyWhenAnnouncedAndIdle() {
        #expect(TodoRPC.shouldRetryEnter(activity: .idle, agentAnnounced: true))
        #expect(TodoRPC.shouldRetryEnter(activity: .done, agentAnnounced: true))
        #expect(!TodoRPC.shouldRetryEnter(activity: .working, agentAnnounced: true))
        #expect(!TodoRPC.shouldRetryEnter(activity: .waiting, agentAnnounced: true))
        #expect(!TodoRPC.shouldRetryEnter(activity: .idle, agentAnnounced: false))
        #expect(!TodoRPC.shouldRetryEnter(
            activity: .idle, agentAnnounced: true, promptAccepted: true))
        #expect(TodoRPC.agentHasAnnounced(hookEventNames: ["SessionStart"]))
        #expect(TodoRPC.agentHasAnnounced(hookEventNames: ["UserPromptSubmit", "SessionStart"]))
        #expect(!TodoRPC.agentHasAnnounced(hookEventNames: []))
        #expect(!TodoRPC.agentHasAnnounced(hookEventNames: ["UserPromptSubmit"]))
    }

    @Test func exploreSeedLaunchCommandWritesPromptAndWrapsLaunch() throws {
        let session = Session(name: "Scratch item", kind: .manager, agentKind: .cursor)
        let cmd = try #require(ManagerSessionController.exploreSeedLaunchCommand(
            session: session,
            baseCommand: "'/opt/homebrew/bin/cursor-agent' --trust",
            prompt: "Start now.\n"))
        #expect(cmd.contains("_CROW_P=$(<"))
        #expect(cmd.contains("-- "))
        let path = TodoRPC.explorePromptPath(sessionID: session.id)
        let body = try String(contentsOfFile: path, encoding: .utf8)
        #expect(body.contains("Start now."))
        #expect(ManagerSessionController.exploreSeedLaunchCommand(
            session: session, baseCommand: "claude", prompt: nil) == nil)
        #expect(ManagerSessionController.exploreSeedLaunchCommand(
            session: session, baseCommand: "claude", prompt: "   ") == nil)
    }
}
