import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// The pure decision + mapping logic of the Corveil worker runner
/// (corveil/crow#801): which claimable runs to pick under the per-host cap, and
/// how a run's `.crow-run-result.json` (or its absence) maps onto
/// `corveil worker-run complete` arguments. Kept pure so they need no Corveil
/// round-trip or live `AppState`.
@Suite("WorkerRunner claim planning")
struct WorkerRunnerClaimPlanTests {
    @Test func claimsUpToRemainingCapacity() {
        let plan = WorkerRunner.claimPlan(
            activeCount: 1, cap: 3, candidateIDs: ["a", "b", "c", "d"], inFlight: []
        )
        #expect(plan == ["a", "b"])  // 3 - 1 = 2 slots
    }

    @Test func noSlotsWhenAtCap() {
        let plan = WorkerRunner.claimPlan(
            activeCount: 2, cap: 2, candidateIDs: ["a", "b"], inFlight: []
        )
        #expect(plan.isEmpty)
    }

    @Test func skipsInFlightAndDuplicates() {
        let plan = WorkerRunner.claimPlan(
            activeCount: 0, cap: 5, candidateIDs: ["a", "a", "b", "c"], inFlight: ["b"]
        )
        #expect(plan == ["a", "c"])
    }

    @Test func capIsNeverNegative() {
        let plan = WorkerRunner.claimPlan(
            activeCount: 5, cap: 1, candidateIDs: ["a"], inFlight: []
        )
        #expect(plan.isEmpty)
    }

    @Test func preservesCandidateOrder() {
        let plan = WorkerRunner.claimPlan(
            activeCount: 0, cap: 2, candidateIDs: ["z", "y", "x"], inFlight: []
        )
        #expect(plan == ["z", "y"])
    }
}

@Suite("WorkerRun completion mapping")
struct WorkerRunCompletionTests {
    @Test func missingResultCompletesWithError() {
        let args = WorkerRunCompletion.map(result: nil)
        #expect(args.error == "agent finished without producing a result")
        #expect(args.title == nil && args.content == nil)
    }

    @Test func selfReportedErrorPropagates() {
        let result = WorkerRunResult(title: "x", content: "y", output: nil, error: "it broke")
        let args = WorkerRunCompletion.map(result: result)
        #expect(args.error == "it broke")
        // Error wins — success fields are dropped so the run is marked failed.
        #expect(args.title == nil)
    }

    @Test func successCarriesTitleContentOutput() {
        let result = WorkerRunResult(title: "Tidied", content: "3 entities", output: #"{"n":3}"#, error: nil)
        let args = WorkerRunCompletion.map(result: result)
        #expect(args.error == nil)
        #expect(args.title == "Tidied")
        #expect(args.content == "3 entities")
        #expect(args.output == #"{"n":3}"#)
    }

    @Test func emptySuccessIsTreatedAsFailure() {
        let result = WorkerRunResult(title: "", content: "", output: nil, error: "")
        let args = WorkerRunCompletion.map(result: result)
        #expect(args.error == "agent produced an empty result")
    }

    @Test func titleOnlyIsAValidSuccess() {
        let result = WorkerRunResult(title: "Just a title", content: nil, output: nil, error: nil)
        let args = WorkerRunCompletion.map(result: result)
        #expect(args.error == nil)
        #expect(args.title == "Just a title")
    }
}

@Suite("WorkerRunResult decoding")
struct WorkerRunResultDecodeTests {
    @Test func decodesFlatFields() {
        let data = Data(#"{"title":"T","content":"C","error":""}"#.utf8)
        let result = WorkerRunResult.decode(fromJSON: data)
        #expect(result?.title == "T")
        #expect(result?.content == "C")
        #expect(result?.error == "")
    }

    @Test func reserializesNestedOutputObjectToString() {
        let data = Data(#"{"title":"T","content":"C","output":{"entities_written":3}}"#.utf8)
        let result = WorkerRunResult.decode(fromJSON: data)
        let output = try? #require(result?.output)
        // Nested object is re-encoded to a compact JSON string for `--output`.
        #expect(output?.contains("\"entities_written\"") == true)
        #expect(output?.contains("3") == true)
    }

    @Test func returnsNilOnGarbage() {
        #expect(WorkerRunResult.decode(fromJSON: Data("not json".utf8)) == nil)
    }
}

@Suite("Worker-run scratch dir + cleanup")
struct WorkerRunScratchTests {
    @Test func scratchDirLivesUnderDevRootWorkerRunsFolder() {
        // A UUID-shaped id sanitizes to itself (dashes preserved) + a hash suffix.
        let dir = SessionService.workerRunScratchDir(devRoot: "/dev/root", runID: "abc-123")
        #expect(dir == "/dev/root/.crow-worker-runs/\(SessionService.scratchSlug("abc-123"))")
        #expect(dir.hasPrefix("/dev/root/.crow-worker-runs/abc-123-"))
    }

    @Test func scratchSlugSanitizesUnsafeIds() {
        // Readable, path-safe base + deterministic hash suffix.
        #expect(SessionService.scratchSlug("Run/../42?x").hasPrefix("run-42-x-"))
        #expect(SessionService.scratchSlug("").hasPrefix("run-"))
        // Deterministic across calls.
        #expect(SessionService.scratchSlug("abc-123") == SessionService.scratchSlug("abc-123"))
    }

    @Test func scratchSlugAvoidsCollisionsForDistinctRawIds() {
        // Distinct ids that sanitize to the same readable slug must NOT collide.
        let a = SessionService.scratchSlug("aaa!")
        let b = SessionService.scratchSlug("aaa?")
        #expect(a != b)
        #expect(a.hasPrefix("aaa-"))
        #expect(b.hasPrefix("aaa-"))
    }

    @Test func wipeRemovesScratchDirUnderCrowWorkerRuns() throws {
        // Only paths whose parent is `.crow-worker-runs` are wiped (the guard).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-\(UUID().uuidString)")
            .appendingPathComponent(".crow-worker-runs")
        let scratch = root.appendingPathComponent("run-abc")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: scratch.appendingPathComponent("secret.env").path, contents: Data("k".utf8))
        #expect(FileManager.default.fileExists(atPath: scratch.path))

        SessionService.wipeWorkerRunScratch(scratch.path)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))

        // Idempotent + safe on empty input.
        SessionService.wipeWorkerRunScratch(scratch.path)
        SessionService.wipeWorkerRunScratch("")
    }

    @Test func isWorkerRunScratchPathAcceptsOnlyScratchDirs() {
        #expect(SessionService.isWorkerRunScratchPath("/dev/root/.crow-worker-runs/run-42"))
        #expect(SessionService.isWorkerRunScratchPath("/dev/root/.crow-worker-runs/run-42/"))  // trailing slash normalized
        // Reject anything whose immediate parent isn't `.crow-worker-runs`.
        #expect(!SessionService.isWorkerRunScratchPath("/dev/root/.crow-worker-runs"))  // the parent itself
        #expect(!SessionService.isWorkerRunScratchPath("/etc/passwd"))
        #expect(!SessionService.isWorkerRunScratchPath("/dev/root/worktrees/repo-42"))
        #expect(!SessionService.isWorkerRunScratchPath(""))
    }

    @Test func wipeRefusesPathsOutsideCrowWorkerRuns() throws {
        // A corrupted scratch-dir path must never turn the wipe into an arbitrary
        // recursive delete (defense-in-depth, review).
        let victim = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: victim) }

        SessionService.wipeWorkerRunScratch(victim.path)
        // Refused — still present.
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }
}

/// A no-op `ShellRunner` so `tick()` can never spawn a real `corveil` process.
private struct NoopShellRunner: ShellRunner {
    func run(args: [String], env: [String: String], cwd: String?) async throws -> String { "" }
}

/// A `.workerRun` session is pinned to Claude Code (only Claude receives the
/// scoped Corveil env), so it must refuse an agent handoff — otherwise a handoff
/// would launch the remote prompt under auto-permission without credentials
/// (review, Yellow 3).
@Suite("WorkerRun handoff refusal")
@MainActor
struct WorkerRunHandoffTests {
    @Test func handoffAgentRefusesWorkerRunSessions() async {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wr-handoff-\(UUID().uuidString)")
        let appState = AppState()
        let service = SessionService(store: JSONStore(directory: tmp), appState: appState, hostBridge: NoopHostBridge())

        let session = Session(name: "wr", status: .active, kind: .workerRun, agentKind: .claudeCode,
                              workerRunID: "run-1", workerID: "w")
        appState.sessions.append(session)

        await #expect(throws: AgentHandoffError.workerRunNotSupported) {
            _ = try await service.handoffAgent(sessionID: session.id, to: .codex)
        }
    }
}

/// `tick()`-level teardown gating (corveil/crow#801 review). Teardown of
/// existing/persisted runs must run even when the runner config is absent — a
/// removed `runner` block (or a failed config load) makes `configProvider()`
/// return nil, and gating teardown on that would orphan the scoped API key.
@Suite("WorkerRunner tick teardown gating")
@MainActor
struct WorkerRunnerTickTeardownTests {
    private func makeRunner() -> (WorkerRunner, AppState) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wr-tick-\(UUID().uuidString)")
        let appState = AppState()
        let service = SessionService(store: JSONStore(directory: tmp), appState: appState, hostBridge: NoopHostBridge())
        let runner = WorkerRunner(appState: appState, sessionService: service)
        runner.makeBackend = { config in CorveilWorkerBackend(shellRunner: NoopShellRunner(), config: config) }
        return (runner, appState)
    }

    /// Seed a persisted active `.workerRun` session with a managed terminal, then
    /// tick with a **nil config** (and no key / no dev root). Reconcile must still
    /// adopt it into the watch set — proving teardown isn't gated on config.
    @Test func nilConfigStillReconcilesInFlightRun() async {
        let (runner, appState) = makeRunner()
        runner.configProvider = { nil }          // no `runner` block at all
        runner.apiKeyProvider = { nil }          // no key
        runner.envURLProvider = { nil }
        runner.devRootProvider = { nil }         // no dev root

        let session = Session(
            name: "wr-1", status: .active, kind: .workerRun,
            workerRunID: "run-1", workerID: "crow-x-1",
            workerRunScratchDir: "/tmp/dev/.crow-worker-runs/run-1"
        )
        appState.sessions.append(session)
        appState.terminals[session.id] = [
            SessionTerminal(sessionID: session.id, name: "t", cwd: "/tmp", isManaged: true)
        ]

        await runner.tick()

        // Adopted despite nil config / no key / no dev root — so its finish/wipe
        // will be driven on subsequent ticks rather than abandoned.
        let snap = runner.statusSnapshot()
        #expect(snap.watched.contains { $0.runID == "run-1" })
        #expect(snap.enabled == false)  // nil config surfaces as disabled
    }

    /// A max-duration timeout on a still-`.active` run must move the session OFF
    /// `.active` (via completeSession) and wipe the scratch dir — otherwise the
    /// next tick's reconcile re-adopts it, resets `startedAt`, and it becomes a
    /// zombie permanently holding a concurrency slot (review — the Yellow).
    @Test func timeoutOnActiveRunCompletesSessionAndDoesNotReAdopt() async throws {
        let (runner, appState) = makeRunner()
        runner.maxWatchDuration = 0            // any active watched run times out immediately
        runner.configProvider = { RunnerConfig(enabled: true) }
        runner.apiKeyProvider = { "sk-test" }
        runner.devRootProvider = { "/tmp/dev" }

        // Real scratch dir under `.crow-worker-runs` so the wipe is observable and
        // passes the parent-name guard.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wr-timeout-\(UUID().uuidString)")
            .appendingPathComponent(".crow-worker-runs")
        let scratch = root.appendingPathComponent("run-timeout")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: scratch.appendingPathComponent("settings.local.json").path,
                                       contents: Data(#"{"env":{"CORVEIL_API_KEY":"k"}}"#.utf8))

        let session = Session(
            name: "wr-timeout", status: .active, kind: .workerRun,
            workerRunID: "run-timeout", workerID: "crow-x-1",
            workerRunScratchDir: scratch.path
        )
        appState.sessions.append(session)
        appState.terminals[session.id] = [
            SessionTerminal(sessionID: session.id, name: "t", cwd: scratch.path, isManaged: true)
        ]

        await runner.tick()

        // Session moved off .active, watch dropped, secret wiped.
        #expect(appState.sessions.first(where: { $0.id == session.id })?.status == .completed)
        #expect(runner.statusSnapshot().watched.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))

        // A second tick must NOT re-adopt it (status is now .completed, not .active).
        await runner.tick()
        #expect(runner.statusSnapshot().watched.isEmpty)
    }

    /// A failed scratch-dir wipe must NOT drop the watch — the key would then sit
    /// on disk with no retry (completed sessions are skipped by reconcile). The
    /// watch is kept so a later tick retries the wipe (review, Yellow 1).
    @Test func failedWipeKeepsWatchThenRetriesOnceUnblocked() async throws {
        // Perms are ignored under root, which would defeat the forced-failure.
        try #require(getuid() != 0)

        let (runner, appState) = makeRunner()
        runner.maxWatchDuration = 0
        runner.configProvider = { RunnerConfig(enabled: true) }
        runner.apiKeyProvider = { "sk-test" }
        runner.devRootProvider = { "/tmp/dev" }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wr-lock-\(UUID().uuidString)")
            .appendingPathComponent(".crow-worker-runs")
        let scratch = root.appendingPathComponent("run-locked")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: scratch.appendingPathComponent("settings.local.json").path,
                                       contents: Data("k".utf8))
        // Read-only parent so the child dir cannot be unlinked → removeItem fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        let session = Session(
            name: "wr-locked", status: .active, kind: .workerRun,
            workerRunID: "run-locked", workerID: "crow-x-1",
            workerRunScratchDir: scratch.path
        )
        appState.sessions.append(session)
        appState.terminals[session.id] = [
            SessionTerminal(sessionID: session.id, name: "t", cwd: scratch.path, isManaged: true)
        ]

        await runner.tick()

        // Session completed, but the wipe failed → watch KEPT (key still on disk).
        #expect(appState.sessions.first(where: { $0.id == session.id })?.status == .completed)
        #expect(FileManager.default.fileExists(atPath: scratch.path))
        #expect(runner.statusSnapshot().watched.contains { $0.runID == "run-locked" })

        // Unblock removal; the next tick retries the wipe and finally drops it.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        await runner.tick()
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(runner.statusSnapshot().watched.isEmpty)
    }

    /// The orphan sweep removes a scratch dir with no matching `.workerRun`
    /// session (crash / failed-wipe orphan holding the scoped key) while keeping
    /// one that a live session still references (review, Yellow 1 backstop).
    @Test func tickSweepsOrphanScratchDirsButKeepsLiveOnes() async throws {
        let (runner, appState) = makeRunner()
        let devRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wr-sweep-\(UUID().uuidString)")
        let wrRoot = devRoot.appendingPathComponent(".crow-worker-runs")
        let keep = wrRoot.appendingPathComponent("run-live")
        let orphan = wrRoot.appendingPathComponent("run-orphan")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: devRoot) }

        runner.configProvider = { nil }   // sweep runs during teardown regardless
        runner.apiKeyProvider = { nil }
        runner.devRootProvider = { devRoot.path }

        // A live, FULLY-LINKED .workerRun session references only `keep` (a
        // managed terminal is required so reconcile adopts it rather than
        // fail-closing it for incomplete linkage).
        let live = Session(
            name: "live", status: .active, kind: .workerRun,
            workerRunID: "run-live", workerID: "w", workerRunScratchDir: keep.path
        )
        appState.sessions.append(live)
        appState.terminals[live.id] = [
            SessionTerminal(sessionID: live.id, name: "t", cwd: keep.path, isManaged: true)
        ]

        await runner.tick()

        #expect(FileManager.default.fileExists(atPath: keep.path))       // referenced → kept
        #expect(!FileManager.default.fileExists(atPath: orphan.path))    // orphan → swept
    }

    /// A run whose lease has lapsed (no successful heartbeat within `leaseSeconds`)
    /// is failed closed — completed, wiped, slot freed — so Crow doesn't keep
    /// executing a claim Corveil may have re-queued to another runner (review).
    @Test func lostLeaseFailsRunClosed() async throws {
        let (runner, appState) = makeRunner()
        runner.leaseSeconds = 0                 // any watched run is instantly "lease-lost"
        runner.configProvider = { RunnerConfig(enabled: true) }
        runner.apiKeyProvider = { "sk-test" }
        runner.devRootProvider = { "/tmp/dev" }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wr-lease-\(UUID().uuidString)")
            .appendingPathComponent(".crow-worker-runs")
        let scratch = root.appendingPathComponent("run-lease")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(
            name: "wr-lease", status: .active, kind: .workerRun,
            workerRunID: "run-lease", workerID: "crow-x-1", workerRunScratchDir: scratch.path
        )
        let term = SessionTerminal(sessionID: session.id, name: "t", cwd: scratch.path, isManaged: true)
        appState.sessions.append(session)
        appState.terminals[session.id] = [term]
        appState.autoLaunchTerminals.insert(term.id)   // observe the agent being stopped

        await runner.tick()

        #expect(appState.sessions.first(where: { $0.id == session.id })?.status == .completed)
        #expect(runner.statusSnapshot().watched.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        // Fail-closed stops the agent so it can't keep using its in-process key.
        #expect(!appState.autoLaunchTerminals.contains(term.id))
    }

    /// A user moving a watched run off `.active` (paused/archived) must fail the
    /// Corveil claim AND stop the agent — not just wipe — so it can't keep using
    /// its in-process key while the lapsing lease lets another runner claim the
    /// run (review). The user's chosen status is preserved (not completed).
    @Test func userPausedRunFailsClaimAndStopsAgent() async throws {
        let (runner, appState) = makeRunner()
        runner.configProvider = { RunnerConfig(enabled: true) }
        runner.apiKeyProvider = { "sk-test" }
        runner.devRootProvider = { "/tmp/dev" }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wr-paused-\(UUID().uuidString)")
            .appendingPathComponent(".crow-worker-runs")
        let scratch = root.appendingPathComponent("run-paused")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(
            name: "wr-paused", status: .active, kind: .workerRun,
            workerRunID: "run-paused", workerID: "crow-x-1", workerRunScratchDir: scratch.path
        )
        let term = SessionTerminal(sessionID: session.id, name: "t", cwd: scratch.path, isManaged: true)
        appState.sessions.append(session)
        appState.terminals[session.id] = [term]
        appState.autoLaunchTerminals.insert(term.id)

        // Tick 1 adopts the active run into the watch set.
        await runner.tick()
        #expect(runner.statusSnapshot().watched.contains { $0.runID == "run-paused" })

        // User pauses it; tick 2 must fail-close it (stopWatching default case).
        if let idx = appState.sessions.firstIndex(where: { $0.id == session.id }) {
            appState.sessions[idx].status = .paused
        }
        await runner.tick()

        #expect(runner.statusSnapshot().watched.isEmpty)                       // watch dropped
        #expect(!FileManager.default.fileExists(atPath: scratch.path))         // secret wiped
        #expect(!appState.autoLaunchTerminals.contains(term.id))              // agent stopped
        // User's chosen status is preserved (NOT forced to .completed).
        #expect(appState.sessions.first(where: { $0.id == session.id })?.status == .paused)
    }

    /// An active `.workerRun` session with incomplete linkage (here: no managed
    /// terminal) can't be driven, and the orphan sweep won't remove a dir a live
    /// session references. Reconcile must fail it closed — wipe the scratch dir
    /// and move the session off `.active` — rather than skipping it forever and
    /// stranding the key (review).
    @Test func incompleteLinkageIsFailedClosed() async throws {
        let (runner, appState) = makeRunner()
        runner.configProvider = { nil }
        runner.apiKeyProvider = { nil }
        runner.devRootProvider = { "/tmp/dev" }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wr-incomplete-\(UUID().uuidString)")
            .appendingPathComponent(".crow-worker-runs")
        let scratch = root.appendingPathComponent("run-incomplete")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: scratch.appendingPathComponent("settings.local.json").path,
                                       contents: Data("k".utf8))
        defer { try? FileManager.default.removeItem(at: root) }

        // Active worker-run session WITH a scratch dir but NO managed terminal.
        let session = Session(
            name: "wr-incomplete", status: .active, kind: .workerRun,
            workerRunID: "run-incomplete", workerID: "crow-x-1", workerRunScratchDir: scratch.path
        )
        appState.sessions.append(session)

        await runner.tick()

        #expect(appState.sessions.first(where: { $0.id == session.id })?.status == .completed)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))  // key wiped, not stranded
        #expect(runner.statusSnapshot().watched.isEmpty)               // never adopted
    }

    /// With config present but `enabled: false`, teardown likewise still runs.
    @Test func disabledConfigStillReconcilesInFlightRun() async {
        let (runner, appState) = makeRunner()
        runner.configProvider = { RunnerConfig(enabled: false) }
        runner.apiKeyProvider = { nil }
        runner.devRootProvider = { "/tmp/dev" }

        let session = Session(
            name: "wr-2", status: .active, kind: .workerRun,
            workerRunID: "run-2", workerID: "crow-x-1",
            workerRunScratchDir: "/tmp/dev/.crow-worker-runs/run-2"
        )
        appState.sessions.append(session)
        appState.terminals[session.id] = [
            SessionTerminal(sessionID: session.id, name: "t", cwd: "/tmp", isManaged: true)
        ]

        await runner.tick()
        #expect(runner.statusSnapshot().watched.contains { $0.runID == "run-2" })
    }
}
