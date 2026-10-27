import Foundation
import Testing
@testable import CrowCore

/// CROW-1386: `defaults.managerWorkspace` is stored by name, so a workspace
/// rename must carry it and a removal must clear it — on every path that
/// writes `workspaces`, which all share this one rule.
@Suite("Manager workspace default reconcile")
struct ManagerWorkspaceDefaultTests {

    private func config(default name: String?) -> AppConfig {
        var config = AppConfig()
        config.workspaces = [WorkspaceInfo(name: "Corveil"), WorkspaceInfo(name: "Radius")]
        config.defaults.managerWorkspace = name
        return config
    }

    @Test func removingTheDefaultWorkspaceClearsIt() {
        var config = config(default: "corveil")
        let previous = config.workspaces
        config.workspaces.removeFirst()
        #expect(config.reconcileManagerWorkspaceDefault(previousWorkspaces: previous) == .cleared(was: "corveil"))
        #expect(config.defaults.managerWorkspace == nil)
    }

    @Test func renamingTheDefaultWorkspaceRewritesIt() {
        var config = config(default: "Corveil")
        let previous = config.workspaces
        config.workspaces[0].name = "Corveil Inc"
        #expect(config.reconcileManagerWorkspaceDefault(previousWorkspaces: previous)
            == .renamed(from: "Corveil", to: "Corveil Inc"))
        #expect(config.defaults.managerWorkspace == "Corveil Inc")
    }

    @Test func otherWorkspaceChangesLeaveTheDefaultAlone() {
        var config = config(default: "Corveil")
        let previous = config.workspaces
        config.workspaces.removeLast()
        config.workspaces.append(WorkspaceInfo(name: "New"))
        #expect(config.reconcileManagerWorkspaceDefault(previousWorkspaces: previous) == nil)
        #expect(config.defaults.managerWorkspace == "Corveil")
    }

    /// A case-only rename is not a change worth reporting.
    @Test func caseOnlyMatchIsNotARename() {
        var config = config(default: "corveil")
        #expect(config.reconcileManagerWorkspaceDefault(previousWorkspaces: config.workspaces) == nil)
        #expect(config.defaults.managerWorkspace == "corveil")
    }

    /// Already stale or unset: nothing here can tell what it meant.
    @Test func unsetOrStaleDefaultIsUntouched() {
        var unset = config(default: nil)
        #expect(unset.reconcileManagerWorkspaceDefault(previousWorkspaces: []) == nil)
        var stale = config(default: "Gone")
        let previous = stale.workspaces
        stale.workspaces.removeAll()
        #expect(stale.reconcileManagerWorkspaceDefault(previousWorkspaces: previous) == nil)
        #expect(stale.defaults.managerWorkspace == "Gone")
    }
}
