import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// #888 — the auto-merge watcher's verdict used to reach only
/// `crowd-automation.log`. It now rides `list-sessions-live` as
/// `auto_merge_state`, a *sibling* of `pr` rather than a member of it. These pin
/// the wire shape, because both halves of that choice are load-bearing: a
/// pre-#888 daemon sends no key at all (so absence, not null, has to mean
/// "nothing to report"), and a verdict has to survive a session with no
/// `PRStatus` — which is exactly the `not-in-viewer-prs` case.
@Suite("auto_merge_state on list-sessions-live (#888)")
struct AutoMergeStatePayloadTests {

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
        // Absent, never null — this is also byte-for-byte what an older daemon
        // sends, so the web's `am && am.phase` presence test degrades cleanly.
        #expect(entry?["auto_merge_state"] == nil)
    }

    @Test @MainActor func carriesTheVerdictBesidePR() async {
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        appState.prStatus[session.id] = PRStatus(
            checksPass: .passing, reviewStatus: .approved, mergeable: .mergeable,
            isOpen: true, hasMergeLabel: true)
        appState.autoMergeState[session.id] = AutoMergeState(
            phase: .blocked, reason: "repo-disallows-auto-merge",
            message: "corveil/corveil has GitHub's \"Allow auto-merge\" setting turned off.",
            permanent: true)

        let entry = await liveEntry(appState, session.id)
        let state = entry?["auto_merge_state"]?.objectValue
        #expect(state?["phase"]?.stringValue == "blocked")
        #expect(state?["reason"]?.stringValue == "repo-disallows-auto-merge")
        #expect(state?["permanent"]?.boolValue == true)
        #expect(state?["message"]?.stringValue?.contains("Allow auto-merge") == true)
        // A sibling of `pr`, not inside it: `pr` still reports only what the
        // forge said about the pull request.
        #expect(entry?["pr"]?.objectValue?["has_merge_label"]?.boolValue == true)
        #expect(entry?["pr"]?.objectValue?["auto_merge_state"] == nil)
    }

    @Test @MainActor func survivesASessionWithNoPRStatus() async {
        // The concrete reason it isn't folded into `prStatusJSON`: a PR absent
        // from the viewer fetch has no `PRStatus` at all, and that absence is
        // itself the verdict worth showing.
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        appState.autoMergeState[session.id] = AutoMergeState(
            phase: .stalled, reason: "not-in-viewer-prs",
            message: "This PR didn't appear in the last provider fetch.", permanent: false)

        let entry = await liveEntry(appState, session.id)
        #expect(entry?["pr"]?.objectValue?["has_pr"]?.boolValue == false)
        #expect(entry?["auto_merge_state"]?.objectValue?["phase"]?.stringValue == "stalled")
    }

    @Test @MainActor func getPRStatusStaysAPureForgeView() async {
        // `prStatusJSON` is shared byte-identically with `get-pr-status`, which
        // answers "what does the forge say about this PR" — not "what is Crow's
        // watcher doing about it".
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        appState.prStatus[session.id] = PRStatus(checksPass: .passing, isOpen: true)
        appState.autoMergeState[session.id] = AutoMergeState(
            phase: .blocked, reason: "repo-disallows-auto-merge", message: "x", permanent: true)

        let resp = await offlineRouter(appState: appState).handle(request: JSONRPCRequest(
            id: 1, method: "get-pr-status", params: ["session_id": .string(session.id.uuidString)]))
        #expect(resp.error == nil)
        #expect(resp.result?["auto_merge_state"] == nil)
    }
}
