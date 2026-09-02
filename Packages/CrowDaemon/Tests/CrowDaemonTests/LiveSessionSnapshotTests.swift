import Foundation
import Testing
import CrowClaude
import CrowCore
import CrowIPC
@testable import CrowDaemon

/// CROW-1180: `list-sessions-live` copies on MainActor and encodes off it.
/// Wire shape stays the existing suites' job; these pin the split itself —
/// encode is callable without MainActor isolation, and the snapshot copy
/// still skips Manager analytics.
@Suite("list-sessions-live snapshot encode off MainActor (CROW-1180)")
struct LiveSessionSnapshotTests {

    private func num(_ v: JSONValue?) -> Double? {
        v?.doubleValue ?? v?.intValue.map(Double.init)
    }

    /// Compile-and-run proof that encode is not MainActor-isolated: this test
    /// is deliberately *not* `@MainActor`. If `encodeLiveSessions` hops back
    /// onto the actor, this would not be the 4s-poll fix.
    @Test func encodeRunsOffMainActorAndPreservesWireShape() {
        let id = UUID()
        let payload = encodeLiveSessions([
            LiveSessionSnapshot(
                id: id,
                remoteControlActive: true,
                remoteControlAvailable: true,
                canDispatch: true,
                prStatus: PRStatus(
                    checksPass: .passing, reviewStatus: .reviewRequired,
                    mergeable: .mergeable, isOpen: true),
                prLink: .init(label: "PR #7", url: "https://github.com/acme/api/pull/7"),
                autoMerge: AutoMergeState(
                    phase: .blocked, reason: "repo-disallows-auto-merge",
                    message: "Allow auto-merge is off.", permanent: true),
                autoRebase: AutoRebaseState(
                    phase: .stalled, reason: "dirty-worktree",
                    message: "The worktree has uncommitted changes.", permanent: false),
                analytics: SessionAnalyticsDTO(
                    live: SessionAnalytics(totalCost: 1.25, inputTokens: 10, outputTokens: 20),
                    wallClockDuration: 60)
            )
        ])
        let entry = payload["sessions"]?.objectValue?[id.uuidString]?.objectValue
        #expect(entry?["remote_control_active"]?.boolValue == true)
        #expect(entry?["remote_control_available"]?.boolValue == true)
        #expect(entry?["can_dispatch"]?.boolValue == true)
        #expect(entry?["pr"]?.objectValue?["has_pr"]?.boolValue == true)
        #expect(entry?["pr"]?.objectValue?["review"]?.stringValue == "reviewRequired")
        #expect(entry?["pr_link"]?.objectValue?["url"]?.stringValue == "https://github.com/acme/api/pull/7")
        #expect(entry?["auto_merge_state"]?.objectValue?["phase"]?.stringValue == "blocked")
        #expect(entry?["auto_rebase_state"]?.objectValue?["reason"]?.stringValue == "dirty-worktree")
        #expect(entry?["pr"]?.objectValue?["auto_merge_state"] == nil)
        #expect(entry?["pr"]?.objectValue?["auto_rebase_state"] == nil)
        let analytics = entry?["analytics"]?.objectValue
        #expect(analytics?["source"]?.stringValue == "live")
        #expect(num(analytics?["totalCost"]) == 1.25)
        #expect(num(analytics?["totalTokens"]) == 30)
    }

    @Test func encodeOmitsOptionalKeysWhenNothingToReport() {
        let id = UUID()
        let payload = encodeLiveSessions([
            LiveSessionSnapshot(
                id: id,
                remoteControlActive: false,
                remoteControlAvailable: false,
                canDispatch: false,
                prStatus: nil,
                prLink: nil,
                autoMerge: nil,
                autoRebase: nil,
                analytics: nil)
        ])
        let entry = payload["sessions"]?.objectValue?[id.uuidString]?.objectValue
        #expect(entry?["pr"]?.objectValue?["has_pr"]?.boolValue == false)
        #expect(entry?["pr_link"] == nil)
        #expect(entry?["auto_merge_state"] == nil)
        #expect(entry?["auto_rebase_state"] == nil)
        #expect(entry?["analytics"] == nil)
    }

    @Test @MainActor func snapshotCopiesLiveFieldsAndSkipsManagerAnalytics() {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let work = Session(name: "__TEST__LiveSnapshotWork", kind: .work, agentKind: .claudeCode)
        let manager = Session(name: "__TEST__LiveSnapshotManager", kind: .manager, agentKind: .claudeCode)
        let appState = AppState()
        appState.sessions = [work, manager]
        appState.prStatus[work.id] = PRStatus(checksPass: .failing, isOpen: true)
        appState.links[work.id] = [SessionLink(
            sessionID: work.id, label: "PR #9",
            url: "https://github.com/acme/api/pull/9", linkType: .pr)]
        appState.autoMergeState[work.id] = AutoMergeState(
            phase: .enabled, reason: "queued", message: "Waiting on GitHub.", permanent: false)
        appState.autoRebaseState[work.id] = AutoRebaseState(
            phase: .blocked, reason: "out-of-sync-diverged",
            message: "Reconcile by hand.", permanent: true)
        let term = SessionTerminal(sessionID: work.id, name: "agent", cwd: "/tmp", isManaged: true)
        appState.terminals[work.id] = [term]
        appState.remoteControlActiveTerminals.insert(term.id)
        appState.hookState(for: work.id).analytics = SessionAnalytics(totalCost: 9.75)
        appState.analyticsSnapshots[manager.id.uuidString] = SessionAnalyticsSnapshot(
            sessionID: manager.id, endedAt: Date(), status: .completed,
            analytics: SessionAnalytics(totalCost: 2.5))

        let snaps = snapshotLiveSessions(from: appState)
        #expect(snaps.map(\.id) == [work.id, manager.id])

        let workSnap = snaps[0]
        #expect(workSnap.remoteControlActive)
        #expect(workSnap.remoteControlAvailable)
        #expect(workSnap.canDispatch)
        #expect(workSnap.prStatus?.checksPass == .failing)
        #expect(workSnap.prLink?.url == "https://github.com/acme/api/pull/9")
        #expect(workSnap.autoMerge?.phase == .enabled)
        #expect(workSnap.autoRebase?.reason == "out-of-sync-diverged")
        #expect(workSnap.analytics?.source == "live")
        #expect(workSnap.analytics?.totalCost == 9.75)

        let managerSnap = snaps[1]
        #expect(managerSnap.analytics == nil)
        #expect(managerSnap.prStatus == nil)
    }
}
