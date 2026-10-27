import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// CROW-1382: tagging an extra Manager with a workspace — which workspace a
/// new one gets, which gateway a tagged one launches with, and the brief it
/// starts from. All three are pure, so they are pinned here without standing
/// up a terminal or touching the live devroot (ADR 0012).
@Suite("Manager workspace tag")
struct ManagerWorkspaceTagTests {

    private static let managerGateway = WorkspaceGateway(
        baseURL: "https://manager.example", customHeaders: ["x-citadel-api-key": "sk-manager"])
    private static let corveilGateway = WorkspaceGateway(
        baseURL: "https://corveil.example", customHeaders: ["x-citadel-api-key": "sk-corveil"])

    private func config(defaultWorkspace: String? = nil) -> AppConfig {
        var config = AppConfig()
        config.workspaces = [
            WorkspaceInfo(name: "Corveil", gateway: Self.corveilGateway),
            WorkspaceInfo(name: "Radius"),
        ]
        config.managerGateway = Self.managerGateway
        config.defaults.managerWorkspace = defaultWorkspace
        return config
    }

    // MARK: - Which workspace a new Manager gets

    @Test func absentWorkspaceFallsBackToConfiguredDefault() throws {
        let config = config(defaultWorkspace: "corveil")
        let decision = try ManagerWorkspaceTag.resolve(requested: nil, config: config)
        #expect(decision.workspaceID == config.workspaces[0].id)
        #expect(decision.workspaceName == "Corveil")
    }

    /// CROW-1386: no explicit choice, no context and no default is a refusal
    /// that names both fixes — Crow never guesses a workspace.
    @Test func absentWorkspaceWithNoDefaultIsRefused() {
        #expect {
            _ = try ManagerWorkspaceTag.resolve(requested: nil, config: config())
        } throws: { error in
            let message = "\(error)"
            return message.contains("--workspace") && message.contains("--manager-workspace")
        }
    }

    /// `none` used to ask for an untagged Manager; it is now refused, even
    /// with a default set, rather than silently tagging with the default.
    @Test func noneIsRefusedEvenWithADefault() {
        for raw in ["none", "NONE"] {
            #expect(throws: RPCError.self, "\(raw)") {
                _ = try ManagerWorkspaceTag.resolve(requested: raw, config: config(defaultWorkspace: "Corveil"))
            }
        }
    }

    /// A workspace actually named "none" is still addressable.
    @Test func workspaceNamedNoneStillResolves() throws {
        var config = config()
        config.workspaces.append(WorkspaceInfo(name: "None"))
        #expect(try ManagerWorkspaceTag.resolve(requested: "none", config: config).workspaceName == "None")
    }

    /// Blank is "not chosen", so it falls through to the default.
    @Test func blankRequestFallsBackToDefault() throws {
        let decision = try ManagerWorkspaceTag.resolve(requested: "  ", config: config(defaultWorkspace: "Radius"))
        #expect(decision.workspaceName == "Radius")
    }

    @Test func explicitWorkspaceByNameOrUUID() throws {
        let config = config(defaultWorkspace: "Corveil")
        #expect(try ManagerWorkspaceTag.resolve(requested: "radius", config: config).workspaceName == "Radius")
        let byID = try ManagerWorkspaceTag.resolve(
            requested: config.workspaces[1].id.uuidString, config: config)
        #expect(byID.workspaceID == config.workspaces[1].id)
    }

    @Test func unknownExplicitWorkspaceIsRejected() {
        #expect(throws: RPCError.self) {
            _ = try ManagerWorkspaceTag.resolve(requested: "Nope", config: config(defaultWorkspace: "Corveil"))
        }
    }

    /// A stale default is treated as unset: refused, and the message says
    /// which name went stale.
    @Test func staleDefaultIsRefused() {
        #expect {
            _ = try ManagerWorkspaceTag.resolve(requested: nil, config: config(defaultWorkspace: "Renamed"))
        } throws: { error in "\(error)".contains("Renamed") }
        #expect(ManagerWorkspaceTag.resolvedDefault(in: config(defaultWorkspace: "Renamed")) == nil)
        #expect(ManagerWorkspaceTag.resolvedDefault(in: config(defaultWorkspace: "radius"))?.name == "Radius")
    }

    /// Context (a Scratch item's workspace, the creating Manager's tag) beats
    /// the default; explicit beats context; a stale context is skipped.
    @Test func contextSitsBetweenExplicitAndDefault() throws {
        let config = config(defaultWorkspace: "Corveil")
        #expect(try ManagerWorkspaceTag.resolve(requested: nil, context: "Radius", config: config)
            .workspaceName == "Radius")
        #expect(try ManagerWorkspaceTag.resolve(
            requested: nil, context: config.workspaces[1].id.uuidString, config: config)
            .workspaceName == "Radius")
        #expect(try ManagerWorkspaceTag.resolve(requested: "Corveil", context: "Radius", config: config)
            .workspaceName == "Corveil")
        #expect(try ManagerWorkspaceTag.resolve(requested: nil, context: "Gone", config: config)
            .workspaceName == "Corveil")
    }

    @Test func noWorkspacesConfiguredIsRefused() {
        #expect {
            _ = try ManagerWorkspaceTag.resolve(requested: nil, config: AppConfig())
        } throws: { error in "\(error)".contains("No workspaces are configured") }
    }

    // MARK: - Which gateway a Manager launches with

    @Test func untaggedManagerUsesManagerGateway() {
        let match = ManagerSessionController.managerGatewayMatch(workspaceTag: nil, config: config())
        #expect(match.source == .manager)
        #expect(match.workspaceID == nil)
        #expect(match.gateway == Self.managerGateway)
    }

    @Test func taggedManagerUsesItsWorkspaceGateway() {
        let config = config()
        let match = ManagerSessionController.managerGatewayMatch(
            workspaceTag: config.workspaces[0].id, config: config)
        #expect(match.source == .workspace)
        #expect(match.workspaceID == config.workspaces[0].id)
        #expect(match.workspaceName == "Corveil")
        #expect(match.gateway == Self.corveilGateway)
        #expect(match.gatewayFromWorkspace)
    }

    /// The fallback the ticket specifies: still reported as the workspace (that
    /// is what `get-session` is asked about), but launching with the Manager
    /// gateway.
    @Test func taggedManagerWithoutWorkspaceGatewayFallsBackToManagerGateway() {
        let config = config()
        let match = ManagerSessionController.managerGatewayMatch(
            workspaceTag: config.workspaces[1].id, config: config)
        #expect(match.source == .workspace)
        #expect(match.workspaceName == "Radius")
        #expect(match.gateway == Self.managerGateway)
        #expect(!match.gatewayFromWorkspace)
    }

    /// An empty gateway block is "none", the same test the launch path applies.
    @Test func emptyWorkspaceGatewayCountsAsNone() {
        var config = config()
        config.workspaces[1].gateway = WorkspaceGateway(baseURL: " ", customHeaders: [:])
        let match = ManagerSessionController.managerGatewayMatch(
            workspaceTag: config.workspaces[1].id, config: config)
        #expect(match.gateway == Self.managerGateway)
    }

    @Test func tagForRemovedWorkspaceFallsBackToUntagged() {
        let match = ManagerSessionController.managerGatewayMatch(workspaceTag: UUID(), config: config())
        #expect(match.source == .manager)
        #expect(match.gateway == Self.managerGateway)
    }

    /// The raw value is API (`get-session`'s `workspace_match`).
    @Test func workspaceMatchSourceRawValue() {
        #expect(SessionService.GatewayMatchSource.workspace.rawValue == "workspace")
    }

    // MARK: - Starting brief

    @Test func briefNamesProviderReposAndInstructions() {
        let workspace = WorkspaceInfo(
            name: "Corveil", alwaysInclude: ["corveil/crow", "corveil/corveil"],
            customInstructions: "Ground in Corveil first.", taskProvider: "jira",
            jiraProjectKey: "CROW", jiraSite: "corveil.atlassian.net")
        let brief = ManagerWorkspaceBrief.prompt(workspace: workspace, devRoot: "/dev", followUp: nil)
        #expect(brief.contains("**Corveil** workspace"))
        #expect(brief.contains("Code provider: github"))
        #expect(brief.contains("Ticket provider: jira, project CROW on corveil.atlassian.net"))
        #expect(brief.contains("`corveil/crow`, `corveil/corveil`"))
        #expect(brief.contains("`/dev/Corveil/`"))
        #expect(brief.contains("/crow-create-ticket"))
        #expect(brief.contains("Ground in Corveil first."))
        #expect(brief.contains("wait for the operator"))
    }

    /// With a prompt of its own (a Scratch Explore brief) the context comes
    /// first and the Manager is not told to sit and wait.
    @Test func briefPrecedesAFollowUpPrompt() {
        let brief = ManagerWorkspaceBrief.prompt(
            workspace: WorkspaceInfo(name: "Radius"), devRoot: nil, followUp: "Explore the idea.")
        #expect(brief.hasSuffix("Explore the idea.\n"))
        #expect(!brief.contains("wait for the operator"))
        #expect(!brief.contains("Workspace instructions"))
    }
}
