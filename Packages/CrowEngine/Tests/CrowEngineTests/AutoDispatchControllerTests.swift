import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// `crow:auto` routing away from a cold, large primary Manager (CROW-1501).
@Suite("Auto-dispatch routing")
struct AutoDispatchRoutingTests {
    typealias W = SessionContextReport.Warmth
    let coldLarge = W(cacheExpired: true, large: true)
    let id = UUID()

    @Test func primaryUnlessItIsKnownColdAndLarge() {
        for primary in [nil, W(cacheExpired: nil, large: true), W(cacheExpired: false, large: true),
                        W(cacheExpired: true, large: false)] {
            #expect(AutoDispatchRouting.target(primary: primary, spare: nil) == .primary)
        }
        #expect(AutoDispatchRouting.target(primary: coldLarge, spare: nil) == .fresh)
    }

    @Test func reusesASpareThatCanTakeAPasteAndIsNotColdAndLarge() {
        for state in [AgentReadinessState.idle, .working] {
            for warmth in [nil, W(cacheExpired: true, large: false), W(cacheExpired: false, large: true)] {
                let spare = AutoDispatchRouting.Spare(id: id, warmth: warmth, agentState: state)
                #expect(AutoDispatchRouting.target(primary: coldLarge, spare: spare) == .spare(id))
            }
        }
    }

    @Test func replacesASpareThatIsBusyStartingOrColdAndLarge() {
        for state in [AgentReadinessState.starting, .waitingPermission, .exited] {
            let spare = AutoDispatchRouting.Spare(id: id, warmth: nil, agentState: state)
            #expect(AutoDispatchRouting.target(primary: coldLarge, spare: spare) == .fresh)
        }
        let spare = AutoDispatchRouting.Spare(id: id, warmth: coldLarge, agentState: .idle)
        #expect(AutoDispatchRouting.target(primary: coldLarge, spare: spare) == .fresh)
    }

    @Test func warmthMatchesTheContextJSON() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snap = ContextSnapshot(tokens: 300_000, lastRequestAt: now.addingTimeInterval(-7_200), cacheTTL: 3_600)
        let warmth = SessionContextReport.warmth(snap, largeThreshold: 200_000, now: now)
        #expect(warmth == W(cacheExpired: true, large: true))
        let json = SessionContextReport.json(
            (snap, SessionContextReport.Located(path: "/x.jsonl", format: .claude)), largeThreshold: 200_000, now: now)
        guard case .object(let fields) = json else { Issue.record("not an object"); return }
        #expect(fields["cache_expired"] == .bool(true))
        #expect(fields["large"] == .bool(true))
        #expect(SessionContextReport.warmth(nil, largeThreshold: 1) == nil)
    }

    @Test func spareNames() {
        #expect(AutoDispatchController.freshName(existing: []) == "auto-dispatch")
        #expect(AutoDispatchController.freshName(existing: ["auto-dispatch"]) == "auto-dispatch 2")
        #expect(AutoDispatchController.freshName(existing: ["auto-dispatch", "auto-dispatch 2"]) == "auto-dispatch 3")
        #expect(AutoDispatchController.isSpareName("auto-dispatch"))
        #expect(AutoDispatchController.isSpareName("auto-dispatch 4"))
        #expect(!AutoDispatchController.isSpareName("auto-dispatch x"))
        #expect(!AutoDispatchController.isSpareName("Manager 2"))
    }
}

@Suite("Auto-dispatch controller")
@MainActor
struct AutoDispatchControllerTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    final class Recorder {
        var sent: [(UUID, String)] = []
        var created: [(name: String, prompt: String, workspace: UUID)] = []
        var routed: [AutoDispatchController.Dispatch] = []
    }

    struct Fixture {
        let appState: AppState
        let controller: AutoDispatchController
        let recorder: Recorder
        let primaryTerminal: SessionTerminal
        let workspace: WorkspaceInfo
    }

    /// The primary Manager with `tokens` of context, idle `idleMinutes` on a
    /// 1h cache. `snapshots` overrides per session.
    func fixture(
        tokens: Int = 500_000, idleMinutes: Double = 90, defaultWorkspace: Bool = true,
        extraSnapshots: [UUID: ContextSnapshot] = [:], configure: (AppState) -> Void = { _ in }
    ) -> Fixture {
        let appState = AppState()
        var primary = Session(id: AppState.managerSessionID, name: "Manager", kind: .manager, agentKind: .claudeCode)
        primary.harnessConversationID = "primary-conv"
        appState.sessions.append(primary)
        let terminal = SessionTerminal(sessionID: primary.id, name: "Manager", cwd: "/dev", command: "claude")
        appState.terminals[primary.id] = [terminal]
        configure(appState)

        let workspace = WorkspaceInfo(name: "corveil")
        var config = AppConfig(workspaces: [workspace])
        if defaultWorkspace { config.defaults.managerWorkspace = "corveil" }
        let recorder = Recorder()
        var snaps = extraSnapshots
        snaps[primary.id] = ContextSnapshot(
            tokens: tokens, lastRequestAt: now.addingTimeInterval(-idleMinutes * 60), cacheTTL: 3_600)
        let located = SessionContextReport.Located(path: "/x.jsonl", format: .claude)
        let frozen = snaps
        let controller = AutoDispatchController(
            appState: appState,
            configProvider: { config },
            launchCommand: { urls, explore in
                (urls.count == 1 ? "/crow-workspace " : "/crow-batch-workspace ")
                    + (explore ? "--explore " : "") + urls.joined(separator: " ") + "\n"
            },
            io: AutoDispatchController.IO(
                send: { recorder.sent.append(($0.id, $1)) },
                paneCommands: { nil },
                createManager: { name, prompt, workspaceID in
                    recorder.created.append((name, prompt, workspaceID))
                    let session = Session(name: name, kind: .manager, agentKind: .claudeCode)
                    appState.sessions.append(session)
                    return session.id
                }),
            snapshotProvider: { sources in
                var out: [UUID: (ContextSnapshot, SessionContextReport.Located)] = [:]
                for source in sources { if let snap = frozen[source.sessionID] { out[source.sessionID] = (snap, located) } }
                return out
            },
            now: { [now] in now },
            onRouted: { recorder.routed.append($0) })
        return Fixture(appState: appState, controller: controller, recorder: recorder,
                       primaryTerminal: terminal, workspace: workspace)
    }

    func request(_ n: Int, explore: Bool = false) -> AutoDispatchController.Request {
        .init(url: "https://github.com/o/r/issues/\(n)", repo: "o/r", number: n, title: "t\(n)", explore: explore)
    }

    @Test func aWarmPrimaryGetsEveryLineAsBefore() async {
        let f = fixture(idleMinutes: 10)
        f.controller.enqueue(request(1))
        f.controller.enqueue(request(2))
        await f.controller.waitUntilDrained()
        #expect(f.recorder.sent.map(\.0) == [f.primaryTerminal.id, f.primaryTerminal.id])
        #expect(f.recorder.sent.map(\.1) == [
            "/crow-workspace https://github.com/o/r/issues/1\n",
            "/crow-workspace https://github.com/o/r/issues/2\n",
        ])
        #expect(f.recorder.created.isEmpty)
        #expect(f.recorder.routed.map(\.sessionID) == [AppState.managerSessionID])
    }

    @Test func aSmallColdPrimaryIsStillUsed() async {
        let f = fixture(tokens: 50_000, idleMinutes: 300)
        f.controller.enqueue(request(1))
        await f.controller.waitUntilDrained()
        #expect(f.recorder.sent.count == 1)
        #expect(f.recorder.created.isEmpty)
    }

    @Test func aColdLargePrimaryStartsOneFreshManagerPerBurstAndKind() async {
        let f = fixture()
        f.controller.enqueue(request(1))
        f.controller.enqueue(request(2))
        f.controller.enqueue(request(3, explore: true))
        await f.controller.waitUntilDrained()
        #expect(f.recorder.sent.isEmpty)
        #expect(f.recorder.created.map(\.name) == ["auto-dispatch", "auto-dispatch 2"])
        #expect(f.recorder.created.map(\.prompt) == [
            AutoDispatchController.freshPrompt(
                "/crow-batch-workspace https://github.com/o/r/issues/1 https://github.com/o/r/issues/2\n"),
            AutoDispatchController.freshPrompt("/crow-workspace --explore https://github.com/o/r/issues/3\n"),
        ])
        #expect(f.recorder.created.last?.prompt.hasSuffix("\n\n/crow-workspace --explore https://github.com/o/r/issues/3\n") == true)
        #expect(f.recorder.created.allSatisfy { $0.workspace == f.workspace.id })
        #expect(f.recorder.routed.map { $0.requests.map(\.number) } == [[1, 2], [3]])
        #expect(f.recorder.routed.allSatisfy { $0.target == .fresh && $0.sessionID != nil })
    }

    @Test func anIdleSpareIsReusedInsteadOfStartingAnother() async {
        var spareID = UUID()
        var spareTerminal: SessionTerminal?
        let f = fixture { appState in
            var spare = Session(name: "auto-dispatch", kind: .manager, agentKind: .claudeCode)
            spare.harnessConversationID = "spare-conv"
            spareID = spare.id
            appState.sessions.append(spare)
            let terminal = SessionTerminal(sessionID: spare.id, name: "auto-dispatch", cwd: "/dev", command: "claude")
            appState.terminals[spare.id] = [terminal]
            appState.terminalReadiness[terminal.id] = .agentLaunched
            spareTerminal = terminal
        }
        f.controller.enqueue(request(7))
        await f.controller.waitUntilDrained()
        #expect(f.recorder.created.isEmpty)
        #expect(f.recorder.sent.map(\.0) == [spareTerminal?.id])
        #expect(f.recorder.routed.first?.target == .spare(spareID))
    }

    @Test func noWorkspaceForAFreshManagerFallsBackToThePrimary() async {
        let f = fixture(defaultWorkspace: false)
        f.controller.enqueue(request(1))
        await f.controller.waitUntilDrained()
        #expect(f.recorder.created.isEmpty)
        #expect(f.recorder.sent.map(\.0) == [f.primaryTerminal.id])
    }

    @Test func noPrimaryTerminalDropsAndReportsNoSession() async {
        let f = fixture(idleMinutes: 10) { appState in appState.terminals[AppState.managerSessionID] = [] }
        f.controller.enqueue(request(1))
        await f.controller.waitUntilDrained()
        #expect(f.recorder.sent.isEmpty)
        #expect(f.recorder.routed.map(\.sessionID) == [nil])
    }
}
