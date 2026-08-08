import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// #944 — the auto-rebase watcher used to publish nothing at all, so a worktree
/// wedged in `out-of-sync-diverged` backed off forever with no surface but
/// `crowd-automation.log`. Its verdict now rides `list-sessions-live` as
/// `auto_rebase_state`, the exact wire shape `auto_merge_state` uses.
///
/// The justification for keeping it off `pr` is sharper here than it was for
/// auto-merge: `prStatusJSON` never carries `mergeStateStatus` at all, so a PR
/// that is BEHIND its base renders as a fully green pill and there is nowhere
/// inside `pr` this verdict could have gone.
@Suite("auto_rebase_state on list-sessions-live (#944)")
struct AutoRebaseStatePayloadTests {

    @MainActor
    private func offlineRouter(appState: AppState) -> CommandRouter {
        makeCommandRouter(
            appState: appState, store: JSONStore.temporary(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil)
    }

    @MainActor
    private func liveEntry(_ appState: AppState, _ id: UUID) async -> [String: JSONValue]? {
        let resp = await offlineRouter(appState: appState)
            .handle(request: JSONRPCRequest(id: 1, method: "list-sessions-live"))
        #expect(resp.error == nil)
        return resp.result?["sessions"]?.objectValue?[id.uuidString]?.objectValue
    }

    @Test @MainActor func omitsTheKeyEntirelyWhenThereIsNoVerdict() async {
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]

        let entry = await liveEntry(appState, session.id)
        // Absent, never null. Silence is the default for auto-rebase — no PR
        // opts into it — so this is also the overwhelmingly common case, and
        // byte-for-byte what a pre-#944 daemon sends.
        #expect(entry?["auto_rebase_state"] == nil)
    }

    @Test @MainActor func carriesTheVerdictBesidePR() async {
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        appState.prStatus[session.id] = PRStatus(
            checksPass: .passing, reviewStatus: .approved, mergeable: .mergeable, isOpen: true)
        appState.autoRebaseState[session.id] = AutoRebaseState(
            phase: .blocked, reason: "out-of-sync-diverged",
            message: "Crow has tried to rebase this branch 5 times; reconcile it by hand.",
            permanent: true)

        let entry = await liveEntry(appState, session.id)
        let state = entry?["auto_rebase_state"]?.objectValue
        #expect(state?["phase"]?.stringValue == "blocked")
        #expect(state?["reason"]?.stringValue == "out-of-sync-diverged")
        #expect(state?["permanent"]?.boolValue == true)
        #expect(state?["message"]?.stringValue?.contains("reconcile it by hand") == true)
        // A sibling of `pr`, not inside it.
        #expect(entry?["pr"]?.objectValue?["auto_rebase_state"] == nil)
        // The green pill that made this invisible: nothing in `pr` says BEHIND.
        #expect(entry?["pr"]?.objectValue?["merge"]?.stringValue == "mergeable")
    }

    @Test @MainActor func survivesASessionWithNoPRStatus() async {
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        appState.autoRebaseState[session.id] = AutoRebaseState(
            phase: .stalled, reason: "dirty-worktree",
            message: "The worktree has uncommitted changes.", permanent: false)

        let entry = await liveEntry(appState, session.id)
        #expect(entry?["pr"]?.objectValue?["has_pr"]?.boolValue == false)
        #expect(entry?["auto_rebase_state"]?.objectValue?["phase"]?.stringValue == "stalled")
    }

    /// The one assertion the auto-merge suite can't make: both watchers can
    /// have a live verdict for the same session at once (a `crow:merge` PR that
    /// auto-merge is blocked on *and* auto-rebase is deferring on), and the two
    /// keys must be independent.
    @Test @MainActor func bothWatcherVerdictsCoexistIndependently() async {
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        appState.autoMergeState[session.id] = AutoMergeState(
            phase: .blocked, reason: "repo-disallows-auto-merge", message: "m", permanent: true)
        appState.autoRebaseState[session.id] = AutoRebaseState(
            phase: .stalled, reason: "out-of-sync-ahead", message: "r", permanent: false)

        let entry = await liveEntry(appState, session.id)
        #expect(entry?["auto_merge_state"]?.objectValue?["reason"]?.stringValue
                == "repo-disallows-auto-merge")
        #expect(entry?["auto_rebase_state"]?.objectValue?["reason"]?.stringValue
                == "out-of-sync-ahead")
    }

    @Test @MainActor func getPRStatusStaysAPureForgeView() async {
        // Same boundary `auto_merge_state` pins: `get-pr-status` answers "what
        // does the forge say", never "what is Crow's watcher doing about it".
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        appState.prStatus[session.id] = PRStatus(checksPass: .passing, isOpen: true)
        appState.autoRebaseState[session.id] = AutoRebaseState(
            phase: .blocked, reason: "out-of-sync-diverged", message: "x", permanent: true)

        let resp = await offlineRouter(appState: appState).handle(request: JSONRPCRequest(
            id: 1, method: "get-pr-status", params: ["session_id": .string(session.id.uuidString)]))
        #expect(resp.error == nil)
        #expect(resp.result?["auto_rebase_state"] == nil)
    }
}
