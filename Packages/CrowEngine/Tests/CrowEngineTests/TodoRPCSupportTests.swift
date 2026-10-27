import Foundation
import Testing
import CrowCore
import CrowClaude
import CrowIPC
import CrowPersistence
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

    // MARK: - Workspace (CROW-1383)

    private func workspaceConfig() -> AppConfig {
        var config = AppConfig()
        config.workspaces = [WorkspaceInfo(name: "Corveil"), WorkspaceInfo(name: "Acme")]
        return config
    }

    @Test func decodeWorkspaceResolvesToCanonicalName() throws {
        let config = workspaceConfig()
        #expect(try TodoRPC.decodeWorkspace(.string(" corveil "), config: config) == "Corveil")
        let acmeID = config.workspaces[1].id.uuidString
        #expect(try TodoRPC.decodeWorkspace(.string(acmeID), config: config) == "Acme")
    }

    @Test func decodeWorkspaceBlankOrAbsentIsNil() throws {
        let config = workspaceConfig()
        #expect(try TodoRPC.decodeWorkspace(nil, config: config) == nil)
        #expect(try TodoRPC.decodeWorkspace(.null, config: config) == nil)
        #expect(try TodoRPC.decodeWorkspace(.string("  "), config: config) == nil)
    }

    @Test func decodeWorkspaceRejectsUnknownAndNonString() {
        let config = workspaceConfig()
        #expect(throws: RPCError.self) {
            _ = try TodoRPC.decodeWorkspace(.string("Nope"), config: config)
        }
        #expect(throws: RPCError.self) {
            _ = try TodoRPC.decodeWorkspace(.int(1), config: config)
        }
    }

    @Test func applyingEditSetsAndClearsWorkspace() throws {
        let config = workspaceConfig()
        let item = TodoItem(text: "a")
        let set = try TodoRPC.applyingEdit(
            item, params: ["workspace": .string("acme")], config: config)
        #expect(set.workspace == "Acme")
        let untouched = try TodoRPC.applyingEdit(set, params: ["note": .string("n")], config: config)
        #expect(untouched.workspace == "Acme")
        let cleared = try TodoRPC.applyingEdit(set, params: ["workspace": .string("")], config: config)
        #expect(cleared.workspace == nil)
    }

    @Test func todoJSONCarriesWorkspace() {
        let json = TodoRPC.todoJSON(TodoItem(text: "a", workspace: "Corveil"))
        #expect(json.objectValue?["workspace"]?.stringValue == "Corveil")
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
        #expect(TodoRPC.seedsExplorePromptWithEndOfOptions(.claudeCode))
        // Codex, OpenCode, Antigravity, and Muse manager prefixes do not
        // leave a variadic flag open, and `--` is unverified for them.
        #expect(!TodoRPC.seedsExplorePromptWithEndOfOptions(.codex))
        #expect(!TodoRPC.seedsExplorePromptWithEndOfOptions(.openCode))
        #expect(!TodoRPC.seedsExplorePromptWithEndOfOptions(.antigravity))
        #expect(!TodoRPC.seedsExplorePromptWithEndOfOptions(.muse))
        let claude = TodoRPC.seedLaunchCommand(
            baseCommand: "claude --permission-mode auto",
            promptPath: path, agentKind: .claudeCode)
        #expect(claude.contains("_CROW_P=$(< '/tmp/crow-explore.md')"))
        #expect(claude.contains("-- $(printf"))
    }

    /// Extra Claude Managers append variadic `--add-dir`. The seeded brief
    /// must sit after `--`, and the flag must be the single-value `=` form,
    /// so the brief is not a second directory (CROW-1329).
    @Test @MainActor func claudeExtraManagerSeedKeepsBriefOutOfAddDir() throws {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-seed-add-dir-\(UUID().uuidString)")
        let svc = SessionService(store: JSONStore(directory: tmp), appState: AppState())
        let session = Session(name: "Manager 2", kind: .manager, agentKind: .claudeCode)
        let root = "/Users/x/My Dev"
        let cwd = ManagerIdentity.directory(devRoot: root, sessionID: session.id)
        let base = svc.manager.managerCommand(for: session, cwd: cwd, devRoot: root)
        let flag = "--add-dir=\(ClaudeLaunchArgs.shellQuote(root))"
        #expect(base.contains(flag))
        #expect(!base.contains("--add-dir \(ClaudeLaunchArgs.shellQuote(root))"))

        let brief = "Start now.\n"
        let cmd = try #require(ManagerSessionController.exploreSeedLaunchCommand(
            session: session, baseCommand: base, prompt: brief))
        defer { try? FileManager.default.removeItem(atPath: TodoRPC.explorePromptPath(sessionID: session.id)) }

        let flagRange = try #require(cmd.range(of: flag))
        let sep = try #require(cmd.range(of: " -- "))
        let prompt = try #require(cmd.range(of: "$(printf"))
        #expect(flagRange.upperBound <= sep.lowerBound)
        #expect(sep.upperBound <= prompt.lowerBound)
        let value = cmd[flagRange.upperBound..<sep.lowerBound]
        #expect(!value.contains("$_CROW_P"))
        #expect(!value.contains("$(printf"))
        #expect(cmd.contains(TodoRPC.explorePromptPath(sessionID: session.id)))
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

    @Test func ticketBriefTellsTheAgentToFileAndLink() {
        let item = TodoItem(text: "cursor jumps", note: "only on iPad", tags: ["web"], priority: "p2")
        let brief = TodoRPC.ticketBrief(for: item)
        #expect(brief.hasSuffix("\n"))
        #expect(brief.contains(item.id.uuidString))
        #expect(brief.contains("crow todo link"))
        #expect(brief.contains("--type ticket"))
        #expect(brief.contains("Choose that repo yourself"))
        #expect(brief.contains("Do not run `crow todo ticket`"))
        #expect(!brief.contains("Do not file a ticket"))
        #expect(brief.contains("## Scratch item"))
        #expect(brief.contains("cursor jumps"))
        #expect(brief.contains("## Notes"))
        #expect(brief.contains("only on iPad"))
        #expect(brief.contains("Tags: web"))
        #expect(brief.contains("Priority: p2"))
    }

    @Test func ticketBriefOmitsEmptyNote() {
        let brief = TodoRPC.ticketBrief(for: TodoItem(text: "try this"))
        #expect(!brief.contains("## Notes"))
    }

    @Test func ticketDispatchPendingWithinTTLAndClearsOnceLinked() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var item = TodoItem(text: "x", ticketRequestedAt: now)
        #expect(TodoRPC.isTicketDispatchPending(item, now: now))
        #expect(TodoRPC.isTicketDispatchPending(
            item, now: now.addingTimeInterval(TodoRPC.ticketDispatchTTL - 1)))
        #expect(!TodoRPC.isTicketDispatchPending(
            item, now: now.addingTimeInterval(TodoRPC.ticketDispatchTTL)))
        #expect(!TodoRPC.isTicketDispatchPending(TodoItem(text: "fresh"), now: now))
        item.links = [TodoLink(
            type: .ticket, url: "https://github.com/corveil/crow/issues/1", label: "#1")]
        #expect(!TodoRPC.isTicketDispatchPending(item, now: now))
    }

    @Test func todoJSONIncludesTicketRequestedAt() throws {
        let at = Date(timeIntervalSince1970: 1_750_000_000)
        let item = TodoItem(text: "x", ticketRequestedAt: at)
        let object = try #require(TodoRPC.todoJSON(item).objectValue)
        #expect(object["ticket_requested_at"] == .string(ISO8601DateFormatter().string(from: at)))
    }

    @Test func ticketLinkAdvancesPreTicketStatesOnly() {
        #expect(TodoRPC.stateAfterTicketLink(.captured) == .ticketed)
        #expect(TodoRPC.stateAfterTicketLink(.exploring) == .ticketed)
        #expect(TodoRPC.stateAfterTicketLink(.parked) == .ticketed)
        #expect(TodoRPC.stateAfterTicketLink(.dropped) == .ticketed)
        #expect(TodoRPC.stateAfterTicketLink(.ticketed) == .ticketed)
        #expect(TodoRPC.stateAfterTicketLink(.working) == .working)
        #expect(TodoRPC.stateAfterTicketLink(.done) == .done)
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


    // MARK: - Brief file is the single source of truth (CROW-1327)

    /// A fresh Manager is seeded by the launch command alone; nothing is
    /// pasted afterwards, so no second copy can land offset.
    @Test func freshManagerSeedsViaArgvWithNoFollowUpPaste() throws {
        for kind in [AgentKind.claudeCode, .cursor, .codex, .grok, .openCode] {
            let item = TodoItem(text: "file this bug")
            let brief = TodoRPC.ticketBrief(for: item)
            let session = Session(name: "Scratch", kind: .manager, agentKind: kind)
            let path = TodoRPC.explorePromptPath(sessionID: session.id)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let cmd = try #require(ManagerSessionController.exploreSeedLaunchCommand(
                session: session, baseCommand: "agent", prompt: brief))
            #expect(cmd.contains(path))
            // The file holds the complete brief, first line intact.
            let body = try String(contentsOfFile: path, encoding: .utf8)
            #expect(body == brief)
            #expect(body.hasPrefix("You are filing a ticket"))
            #expect(TodoRPC.briefDelivery(
                managerAlive: false, briefWritten: true, path: path) == .launchArgv)
        }
    }

    /// A live Manager is typed one short line pointing at the file — never
    /// the multi-line brief.
    @Test func aliveManagerGetsOnlyThePointerLine() throws {
        let path = TodoRPC.explorePromptPath(sessionID: UUID())
        defer { try? FileManager.default.removeItem(atPath: path) }
        let brief = TodoRPC.exploreBrief(for: TodoItem(text: "why is this slow"))
        #expect(TodoRPC.writeBriefFile(brief, to: path))
        let delivery = TodoRPC.briefDelivery(managerAlive: true, briefWritten: true, path: path)
        guard case .pointer(let line) = delivery else {
            Issue.record("expected a pointer, got \(delivery)")
            return
        }
        #expect(line == "Read and follow the instructions in \(path)\n")
        #expect(line.filter(\.isNewline).count == 1)
        #expect(!line.contains("Scratch item"))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == brief)
    }

    @Test func unwrittenBriefDeliversNothing() {
        #expect(TodoRPC.briefDelivery(managerAlive: false, briefWritten: false, path: "/x") == .none)
        #expect(TodoRPC.briefDelivery(managerAlive: true, briefWritten: false, path: "/x") == .none)
        #expect(!TodoRPC.writeBriefFile("   \n", to: NSTemporaryDirectory() + "crow-empty-\(UUID()).md"))
        #expect(!TodoRPC.writeBriefFile("x", to: "/nonexistent-dir-\(UUID())/brief.md"))
    }
}
