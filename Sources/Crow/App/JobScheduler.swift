import Foundation
import CrowCore
import CrowTerminal

/// Drives scheduled jobs (CROW-317).
///
/// Ticks on a `Timer` (like `IssueTracker`) and, for each enabled job that is
/// due, asks `SessionService.runJob` to spin up a worktree + session + Claude
/// terminal in the job's scoped repo. The first prompt is dispatched by the
/// terminal-readiness machine on launch; any remaining prompts are delivered
/// here once the terminal reports `.claudeLaunched`, spaced by a fixed gap.
///
/// Job config (including `lastRunAt`) lives in `AppConfig`; this class reads it
/// through `jobsProvider`/`devRootProvider` closures and reports each run back
/// via `onJobRan` so AppDelegate can persist `lastRunAt`. Keeping the canonical
/// config in AppDelegate avoids a second source of truth.
@MainActor
final class JobScheduler {
    private let appState: AppState
    private let sessionService: SessionService
    private var timer: Timer?

    /// How often to evaluate jobs. A job fires within one tick of becoming due.
    private let tickInterval: TimeInterval = 30
    /// Gap between consecutive prompt sends after Claude has launched.
    private let promptGap: TimeInterval = 20
    /// Max polls (× 5s) to wait for `.claudeLaunched` before giving up on the
    /// follow-up prompts for a run.
    private let maxLaunchWaitPolls = 60

    /// Jobs currently being created — guards against a long worktree creation
    /// double-firing on the next tick before `lastRunAt` is persisted.
    private var inFlight: Set<UUID> = []

    /// Reads the current job list (from AppDelegate's `appConfig`).
    var jobsProvider: () -> [JobConfig] = { [] }
    /// Reads the configured dev root.
    var devRootProvider: () -> String? = { nil }
    /// Reports a successful run so AppDelegate can persist the job's `lastRunAt`.
    var onJobRan: (UUID, Date) -> Void = { _, _ in }

    init(appState: AppState, sessionService: SessionService) {
        self.appState = appState
        self.sessionService = sessionService
    }

    func start() {
        // First tick after one interval — gives the app a grace period at
        // launch and lets overdue jobs fire shortly after.
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = tickInterval / 4
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    private func tick() {
        guard let devRoot = devRootProvider() else { return }
        let now = Date()
        for job in jobsProvider() where job.enabled {
            guard !inFlight.contains(job.id) else { continue }
            let baseline = job.lastRunAt ?? job.createdAt
            guard let next = job.nextRunDate(after: baseline), next <= now else { continue }
            fire(job, devRoot: devRoot)
        }
    }

    // MARK: - Manual run

    /// Fire a job on demand, regardless of its enabled flag or schedule.
    func runNow(_ jobID: UUID) {
        guard let devRoot = devRootProvider() else { return }
        guard let job = jobsProvider().first(where: { $0.id == jobID }) else { return }
        fire(job, devRoot: devRoot)
    }

    /// Launch one job: guard against double-launch, spin up the worktree/session/
    /// Claude terminal, persist the run time, then deliver any remaining prompts.
    /// Shared by `tick()` (scheduled) and `runNow(_:)` (manual).
    private func fire(_ job: JobConfig, devRoot: String) {
        guard !inFlight.contains(job.id) else { return }
        inFlight.insert(job.id)
        let captured = job
        Task { @MainActor in
            defer { self.inFlight.remove(captured.id) }
            if let result = await self.sessionService.runJob(captured, devRoot: devRoot) {
                // Persist run time first so the job isn't re-fired next tick.
                self.onJobRan(captured.id, Date())
                self.deliverRemainingPrompts(captured, terminalID: result.terminalID)
            }
        }
    }

    // MARK: - Multi-prompt delivery (best-effort)

    /// Deliver every prompt after the first non-empty one, once Claude has
    /// launched, spaced by `promptGap`.
    private func deliverRemainingPrompts(_ job: JobConfig, terminalID: UUID) {
        let remaining = job.prompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .dropFirst()
        guard !remaining.isEmpty else { return }

        waitForClaudeLaunched(terminalID: terminalID, polls: 0) { [weak self] in
            self?.sendSequentially(Array(remaining), terminalID: terminalID)
        }
    }

    /// Poll the readiness machine until the terminal reports `.claudeLaunched`,
    /// then run `then`. Bounded so a stuck launch doesn't poll forever.
    private func waitForClaudeLaunched(terminalID: UUID, polls: Int, then: @escaping () -> Void) {
        if appState.terminalReadiness[terminalID] == .claudeLaunched {
            then()
            return
        }
        guard polls < maxLaunchWaitPolls else {
            NSLog("[JobScheduler] gave up waiting for claude launch on \(terminalID)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.waitForClaudeLaunched(terminalID: terminalID, polls: polls + 1, then: then)
        }
    }

    /// Send prompts one at a time, waiting `promptGap` before each so they don't
    /// collide with Claude still processing the previous one. Stops if the
    /// terminal disappears (e.g. the session was deleted).
    private func sendSequentially(_ prompts: [String], terminalID: UUID) {
        guard !prompts.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + promptGap) { [weak self] in
            guard let self else { return }
            guard let terminal = self.appState.terminals.values
                .flatMap({ $0 })
                .first(where: { $0.id == terminalID }) else {
                NSLog("[JobScheduler] terminal \(terminalID) gone; stopping prompt delivery")
                return
            }
            TerminalRouter.send(terminal, text: prompts[0] + "\n")
            self.sendSequentially(Array(prompts.dropFirst()), terminalID: terminalID)
        }
    }
}
