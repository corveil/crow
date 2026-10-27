import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// Scratch items carry an agent + workspace, and Explore / Ticket launch a
/// Manager tagged with them (CROW-1387).
@Suite("Todo agent + workspace (CROW-1387)")
struct TodoManagerTargetTests {
    private let corveil = WorkspaceInfo(name: "Corveil", alwaysInclude: ["corveil/crow"])
    private let acme = WorkspaceInfo(name: "Acme")

    private func config(defaultWorkspace: String? = nil) -> AppConfig {
        var config = AppConfig()
        config.workspaces = [corveil, acme]
        config.defaults.managerWorkspace = defaultWorkspace
        config.defaultAgentKind = .claudeCode
        config.agentsByKind = ["manager": .codex]
        return config
    }

    private let anyAgent: (AgentKind) -> Bool = { _ in true }

    private func taggedManager(_ workspace: WorkspaceInfo?, agent: AgentKind = .cursor) -> Session {
        Session(name: "Manager 2", kind: .manager, agentKind: agent, workspaceID: workspace?.id)
    }

    // MARK: - Capture

    @Test func explicitFlagsWin() throws {
        let target = try TodoRPC.captureTarget(
            params: ["workspace": .string("acme"), "agent_kind": .string("cursor")],
            creator: taggedManager(corveil, agent: .grok),
            config: config(defaultWorkspace: "Corveil"), isRegistered: anyAgent)
        #expect(target == .init(workspace: "Acme", agentKind: .cursor))
    }

    @Test func taggedCreatorManagerBeatsDefaults() throws {
        let target = try TodoRPC.captureTarget(
            params: [:], creator: taggedManager(acme, agent: .grok),
            config: config(defaultWorkspace: "Corveil"), isRegistered: anyAgent)
        #expect(target == .init(workspace: "Acme", agentKind: .grok))
    }

    @Test func eachValueResolvesOnItsOwn() throws {
        // Explicit workspace, agent still inherited from the tagged creator.
        let target = try TodoRPC.captureTarget(
            params: ["workspace": .string("Corveil")], creator: taggedManager(acme, agent: .grok),
            config: config(), isRegistered: anyAgent)
        #expect(target == .init(workspace: "Corveil", agentKind: .grok))
    }

    @Test func untaggedOrNonManagerCreatorFallsToDefaults() throws {
        let untagged = taggedManager(nil, agent: .grok)
        let primary = Session(
            id: AppState.managerSessionID, name: "Manager", kind: .manager,
            agentKind: .grok, workspaceID: acme.id)
        let work = Session(name: "w", kind: .work, agentKind: .grok, workspaceID: acme.id)
        for creator in [untagged, primary, work, nil] as [Session?] {
            let target = try TodoRPC.captureTarget(
                params: [:], creator: creator, config: config(defaultWorkspace: "corveil"),
                isRegistered: anyAgent)
            // Defaults: the canonical workspace name, `agentsByKind.manager`.
            #expect(target == .init(workspace: "Corveil", agentKind: .codex))
        }
    }

    @Test func creatorTaggedWithARemovedWorkspaceIsIgnored() throws {
        let gone = WorkspaceInfo(name: "Gone")
        let target = try TodoRPC.captureTarget(
            params: [:], creator: taggedManager(gone, agent: .grok),
            config: config(defaultWorkspace: "Acme"), isRegistered: anyAgent)
        #expect(target == .init(workspace: "Acme", agentKind: .codex))
    }

    @Test func noWorkspaceAnywhereErrors() {
        #expect(throws: RPCError.self) {
            _ = try TodoRPC.captureTarget(params: [:], creator: nil, config: config(), isRegistered: anyAgent)
        }
    }

    @Test func staleDefaultErrorsInsteadOfGuessing() {
        #expect(throws: RPCError.self) {
            _ = try TodoRPC.captureTarget(
                params: [:], creator: nil, config: config(defaultWorkspace: "Renamed"),
                isRegistered: anyAgent)
        }
    }

    @Test func unknownExplicitValuesError() {
        #expect(throws: RPCError.self) {
            _ = try TodoRPC.captureTarget(
                params: ["workspace": .string("Nope")], creator: nil,
                config: config(defaultWorkspace: "Acme"), isRegistered: anyAgent)
        }
        #expect(throws: RPCError.self) {
            _ = try TodoRPC.captureTarget(
                params: ["agent_kind": .string("not-an-agent")], creator: nil,
                config: config(defaultWorkspace: "Acme"), isRegistered: { _ in false })
        }
    }

    // MARK: - Edit + JSON

    @Test func editSetsAndClearsAgent() throws {
        let item = TodoItem(text: "a", agentKind: .codex)
        let set = try TodoRPC.applyingEdit(
            item, params: ["agent_kind": .string("cursor")], isRegistered: anyAgent)
        #expect(set.agentKind == .cursor)
        let kept = try TodoRPC.applyingEdit(set, params: ["note": .string("n")], isRegistered: anyAgent)
        #expect(kept.agentKind == .cursor)
        let cleared = try TodoRPC.applyingEdit(set, params: ["agent_kind": .string("")], isRegistered: anyAgent)
        #expect(cleared.agentKind == nil)
        #expect(throws: RPCError.self) {
            _ = try TodoRPC.applyingEdit(item, params: ["agent_kind": .string("x")], isRegistered: { _ in false })
        }
    }

    @Test func todoJSONCarriesAgentKind() {
        let json = TodoRPC.todoJSON(TodoItem(text: "a", agentKind: .cursor))
        #expect(json.objectValue?["agent_kind"]?.stringValue == "cursor")
    }

    @Test func agentKindRoundTripsAndOldItemsDecodeNil() throws {
        let item = TodoItem(text: "a", workspace: "Corveil", agentKind: .cursor)
        let back = try JSONDecoder().decode(TodoItem.self, from: JSONEncoder().encode(item))
        #expect(back.agentKind == .cursor)
        let old = #"{"id":"\#(UUID().uuidString)","text":"old"}"#
        #expect(try JSONDecoder().decode(TodoItem.self, from: Data(old.utf8)).agentKind == nil)
    }

    // MARK: - Launch

    @Test func launchUsesTheItemsAgentAndWorkspace() throws {
        let item = TodoItem(text: "a", workspace: "acme", agentKind: .cursor)
        let launch = try TodoRPC.launchTarget(for: item, params: [:], config: config(), isRegistered: anyAgent)
        #expect(launch.workspace?.id == acme.id)
        #expect(launch.agentKind == .cursor)
    }

    @Test func launchParamsOverrideForThisLaunchOnly() throws {
        let item = TodoItem(text: "a", workspace: "Acme", agentKind: .cursor)
        let launch = try TodoRPC.launchTarget(
            for: item, params: ["agent_kind": .string("codex"), "workspace": .string("corveil")],
            config: config(), isRegistered: anyAgent)
        #expect(launch.workspace?.id == corveil.id)
        #expect(launch.agentKind == .codex)
    }

    @Test func legacyItemTakesTheDefaultWorkspace() throws {
        // CROW-1386: every new Manager has a workspace; an item with none
        // falls to `defaults.managerWorkspace`.
        let launch = try TodoRPC.launchTarget(
            for: TodoItem(text: "old"), params: [:], config: config(defaultWorkspace: "Acme"),
            isRegistered: anyAgent)
        #expect(launch == .init(workspace: acme, agentKind: nil))
    }

    @Test func removedItemWorkspaceFallsToTheDefault() throws {
        let launch = try TodoRPC.launchTarget(
            for: TodoItem(text: "a", workspace: "Gone"), params: [:],
            config: config(defaultWorkspace: "Corveil"), isRegistered: anyAgent)
        #expect(launch.workspace?.id == corveil.id)
    }

    @Test func newManagerWithNoWorkspaceIsRefused() {
        #expect(throws: RPCError.self) {
            _ = try TodoRPC.launchTarget(
                for: TodoItem(text: "old"), params: [:], config: config(), isRegistered: anyAgent)
        }
    }

    @Test func reseedingALiveManagerNeedsNoWorkspace() throws {
        let launch = try TodoRPC.launchTarget(
            for: TodoItem(text: "old"), params: [:], config: config(), newManager: false,
            isRegistered: anyAgent)
        #expect(launch.workspace == nil)
        #expect(throws: RPCError.self) {
            _ = try TodoRPC.launchTarget(
                for: TodoItem(text: "old"), params: ["workspace": .string("Nope")],
                config: config(), newManager: false, isRegistered: anyAgent)
        }
    }

    @Test func existingManagerWarnsOnlyOnMismatch() {
        let config = config()
        #expect(TodoRPC.existingManagerWarning(managerTag: acme.id, launch: acme, config: config) == nil)
        #expect(TodoRPC.existingManagerWarning(managerTag: acme.id, launch: nil, config: config) == nil)
        let other = TodoRPC.existingManagerWarning(managerTag: acme.id, launch: corveil, config: config)
        #expect(other?.contains("'Acme'") == true)
        #expect(other?.contains("'Corveil'") == true)
        #expect(other?.contains("never re-tagged") == true)
        let untagged = TodoRPC.existingManagerWarning(managerTag: nil, launch: corveil, config: config)
        #expect(untagged?.contains("not tagged") == true)
    }

    // MARK: - Ticket brief

    @Test func ticketBriefFilesIntoTheWorkspacesProviderAndRepos() {
        let brief = TodoRPC.ticketBrief(for: TodoItem(text: "x"), workspace: corveil)
        #expect(brief.contains("gh issue create"))
        #expect(brief.contains("**Corveil**"))
        #expect(brief.contains("`corveil/crow`"))
        #expect(!brief.contains("Choose that repo yourself"))
        #expect(brief.contains("crow todo link"))
    }

    @Test func ticketBriefNamesTheJiraProject() {
        let jira = WorkspaceInfo(
            name: "Ops", taskProvider: "jira", jiraProjectKey: "OPS", jiraSite: "acme.atlassian.net")
        let brief = TodoRPC.ticketBrief(for: TodoItem(text: "x"), workspace: jira)
        #expect(brief.contains("Jira, project OPS on acme.atlassian.net"))
        #expect(!brief.contains("gh issue create"))
    }

    @Test func ticketBriefWithoutAWorkspaceIsUnchanged() {
        let item = TodoItem(text: "x")
        #expect(TodoRPC.ticketBrief(for: item, workspace: nil) == TodoRPC.ticketBrief(for: item))
        #expect(TodoRPC.ticketBrief(for: item).contains("Choose that repo yourself"))
    }
}
