import Foundation

/// Shared machinery for `CodingAgent.verifyBinaryIdentity` — running a cheap
/// `--help` / `--version` probe against a resolved binary and matching its
/// output for agent-specific markers.
///
/// Extracted from `GrokAgent` (CROW-911) when Cursor's generic `agent` token hit
/// the same collision in the field (CROW-989: xAI's grok-build installs
/// `~/.grok/bin/agent`, so `agent` resolved to Grok's TUI and Crow handed it
/// Cursor's flags). Both adapters now share one implementation of the subprocess
/// race, so the hard-timeout reasoning below is stated and tested once instead of
/// being copied per colliding token — the generalization ADR 0014 anticipated.
///
/// ⚠️ **Trust-boundary note.** Probing *executes* a PATH-resolved third-party
/// binary at daemon boot. That's inherent to identity probing: it's on the user's
/// own PATH, the output is only substring-matched (never logged or evaluated),
/// and the run is hard-bounded so a hanging binary can't stall startup.
public enum BinaryIdentityProbe {
    /// Per-leg cap for one `--help` / `--version` probe.
    public static let defaultTimeoutNanos: UInt64 = 3 * 1_000_000_000

    /// Probe `path` with each arg in `args` (in order) and return `true` as soon
    /// as the merged stdout+stderr contains any string in `markers`.
    ///
    /// Matching is **OR, not AND**, and case-insensitive: one upstream flag
    /// rename can't grey out a genuine install, while a foreign binary carrying
    /// none of the markers is rejected. Callers order `args` so the cheapest
    /// discriminator runs first — a match short-circuits, so a genuine install
    /// usually costs a single spawn.
    ///
    /// `markers` must already be lowercased; they're compared against the
    /// lowercased probe output.
    public static func matches(
        path: String,
        args: [String],
        markers: [String],
        runner: any ShellRunner,
        timeoutNanos: UInt64 = defaultTimeoutNanos
    ) async -> Bool {
        for arg in args {
            let out = await run(path, arg, runner: runner, timeoutNanos: timeoutNanos).lowercased()
            if markers.contains(where: { out.contains($0) }) { return true }
        }
        return false
    }

    /// Run `<binary> <arg>` and return its merged stdout+stderr, or `""` on spawn
    /// failure **or timeout**. The cap is a *hard* bound on the awaiting task: it
    /// races the run against a sleep behind a resume-once guard and returns
    /// whichever finishes first — so even a runner that never completes and
    /// ignores cancellation (a binary that reads stdin, or forks a child holding
    /// the stdout pipe so `readDataToEndOfFile()` never sees EOF) **cannot stall
    /// `registerAgents` at boot** (CROW-911 review — an earlier `withTaskGroup`
    /// form awaited the losing child and so bounded nothing).
    ///
    /// On timeout the run `Task` is cancelled: with the cancellation-aware
    /// `ProcessShellRunner` that `terminate()`s the child so it doesn't leak; a
    /// genuinely uncancellable runner leaks one blocked reader but boot proceeds.
    ///
    /// A non-zero exit is **not** an error here — a foreign binary may print its
    /// banner to stderr and exit 2, and that banner is exactly what identifies
    /// it — so `nonZeroExit` output is returned rather than discarded.
    public static func run(
        _ binary: String,
        _ arg: String,
        runner: any ShellRunner,
        timeoutNanos: UInt64 = defaultTimeoutNanos
    ) async -> String {
        let gate = ResumeOnceGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            @Sendable func finish(_ result: String) {
                if gate.claim() { cont.resume(returning: result) }
            }
            let work = Task {
                let out: String
                do {
                    out = try await runner.run(args: [binary, arg], env: [:], cwd: nil)
                } catch let ShellRunnerError.nonZeroExit(_, output) {
                    out = output
                } catch {
                    out = ""
                }
                finish(out)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                work.cancel()
                finish("")
            }
        }
    }
}

/// A cross-platform (no Darwin `os`) resume-once guard for `BinaryIdentityProbe.run`'s
/// race: `claim()` returns `true` exactly once — for the first of the run and
/// timeout tasks to finish — so the continuation is resumed a single time. An
/// `NSLock`-backed `Bool` rather than `OSAllocatedUnfairLock`, which is
/// Apple-platforms-only and breaks the Linux CI build (#912).
private final class ResumeOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
