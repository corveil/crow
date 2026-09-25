import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// CROW-1301 — under rapid session creation `add-worktree` reported success but
/// the worktree was absent from a following `list-worktrees`, so `setup.sh` died
/// at `launch_agent` ("no registered worktree with a branch").
///
/// Root cause: the store-mtime poll (`startStoreReloadPoll`) fired `store.reload()`
/// + `reseed` on the daemon's OWN store writes (it only sees the mtime move, not
/// who moved it). `reload()` overwrote `_data` from disk unconditionally, so a
/// reload whose disk read landed in the pre-save window of an in-flight `mutate`
/// dropped the just-appended worktree, and `reseed` propagated that loss into
/// `AppState` — which is what `list-worktrees` reads. The fix makes `reload()`
/// refuse to adopt our own write (and any snapshot behind an unpersisted mutate),
/// so a poll cycle can never clobber a just-registered worktree.
@Suite struct WorktreeReloadRaceTests {
    @MainActor
    private func router(appState: AppState, store: JSONStore, devRoot: String) -> CommandRouter {
        makeCommandRouter(
            appState: appState, store: store, git: GitManager(),
            devRoot: devRoot, cockpit: nil)
    }

    /// Mirror `setup.sh`: register the checkout on disk so `add-worktree` records
    /// metadata only instead of shelling out to `git worktree add`.
    private func materialize(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "gitdir: /dev/null".write(
            toFile: (path as NSString).appendingPathComponent(".git"),
            atomically: true, encoding: .utf8)
    }

    @MainActor
    private func addWorktree(
        _ router: CommandRouter, session: Session, path: String, branch: String, id: Int
    ) async -> JSONRPCResponse {
        await router.handle(request: JSONRPCRequest(id: id, method: "add-worktree", params: [
            "session_id": .string(session.id.uuidString),
            "repo": .string("crow"),
            "path": .string(path),
            "branch": .string(branch),
        ]))
    }

    /// A single store-reload poll cycle immediately after a successful
    /// `add-worktree` must leave the worktree in `AppState`. `reload()` reports
    /// "no external change" for our own write, and even the following `reseed`
    /// (rebuilt from the store) keeps the row — the deterministic core of the fix.
    @Test @MainActor func pollCycleAfterAddWorktreeKeepsRow() async throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-1301-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let wt = (root as NSString).appendingPathComponent("wt-1")
        try materialize(wt)

        let appState = AppState()
        let store = JSONStore.temporary()
        let session = Session(name: "crow-1301")
        appState.sessions.append(session)
        store.mutate { $0.sessions.append(session) }

        let resp = await addWorktree(
            router(appState: appState, store: store, devRoot: root),
            session: session, path: wt, branch: "feature/crow-1301", id: 1)
        #expect(resp.error == nil)
        #expect(!appState.worktrees(for: session.id).isEmpty)

        // The poll's read step: our own write is not adopted (would otherwise
        // drive the reseed that dropped the row mid-burst).
        #expect(store.reload() == false)
        // The poll's reseed step, run unconditionally here: rebuilt from the
        // (uncloberred) store, it must still carry the worktree.
        CrowDaemon.reseed(appState, from: store)
        #expect(appState.worktrees(for: session.id).count == 1)
        #expect(appState.worktrees(for: session.id).first?.branch == "feature/crow-1301")
    }

    /// Reproduce the burst: fire many `add-worktree`s while a background loop
    /// hammers the exact `reload()` + `reseed` the poll runs. After each
    /// registration the row `list-worktrees`/`setup.sh` reads must be present —
    /// the invariant that used to break only under concurrent store writes.
    @Test @MainActor func rapidAddWorktreeSurvivesConcurrentStoreReload() async throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-1301-burst-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }

        let appState = AppState()
        let store = JSONStore.temporary()
        let r = router(appState: appState, store: store, devRoot: root)

        // The store-reload poll, sped up and unconditional: reload + reseed as
        // fast as possible so a reload races the mutates below. Reseeding
        // unconditionally (ignoring reload's verdict) keeps this a guard against
        // ANY reload snapshot regression, not just the poll's gating.
        let loop = Task.detached {
            while !Task.isCancelled {
                _ = store.reload()
                await MainActor.run { CrowDaemon.reseed(appState, from: store) }
                await Task.yield()
            }
        }

        let iterations = 80
        for i in 0..<iterations {
            let session = Session(name: "burst-\(i)")
            appState.sessions.append(session)
            store.mutate { $0.sessions.append(session) }

            let wt = (root as NSString).appendingPathComponent("wt-\(i)")
            try materialize(wt)
            let resp = await addWorktree(
                r, session: session, path: wt, branch: "feature/burst-\(i)", id: i)
            #expect(resp.error == nil)
            // Exactly the `setup.sh` launch-guard read, right after the coder's
            // `add-worktree` succeeded: it must never be empty (CROW-1301).
            #expect(!appState.worktrees(for: session.id).isEmpty)
        }

        loop.cancel()
        _ = await loop.value

        // Every registered worktree survived the storm.
        for i in 0..<iterations {
            let session = appState.sessions.first { $0.name == "burst-\(i)" }
            #expect(session != nil)
            if let session {
                #expect(appState.worktrees(for: session.id).count == 1)
            }
        }
    }
}
