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
        let dir = SessionService.workerRunScratchDir(devRoot: "/dev/root", runID: "abc-123")
        #expect(dir == "/dev/root/.crow-worker-runs/abc-123")
    }

    @Test func scratchSlugSanitizesUnsafeIds() {
        #expect(SessionService.scratchSlug("Run/../42?x") == "run-42-x")
        #expect(SessionService.scratchSlug("") == "run")
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
