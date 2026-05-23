import Foundation

/// Reaps orphaned, *legacy PID-keyed* tmux sockets left behind by pre-#330
/// Crow builds. Called once at app launch, BEFORE the new instance configures
/// its tmux server.
///
/// Since #330 the running instance uses a single stable socket
/// (`$TMPDIR/crow-tmux.sock`) that deliberately *outlives* the app process so
/// a relaunch can re-attach to the still-running sessions. That stable socket
/// is intentionally NEVER reaped — the regex below only matches the old
/// `$TMPDIR/crow-tmux-<pid>.sock` naming, so `crow-tmux.sock` (no PID) falls
/// through untouched, and a healthy persistent server is preserved.
///
/// What's left for this reaper is one-time cleanup of orphans from the old
/// per-PID design: a `crow-tmux-<pid>.sock` whose owning CrowApp is gone leaks
/// ~10-20 MB of RSS plus a stale socket file. (These self-heal on the app side
/// too — a persisted binding pointing at a dead PID socket mismatches the
/// stable socket and falls back to a fresh window — but reaping reclaims the
/// leaked server.)
///
/// The reaper is idempotent and best-effort. It enumerates
/// `$TMPDIR/crow-tmux-<pid>.sock`, extracts the PID encoded in each filename,
/// and:
///   - Skips the current process's own socket (we're about to bind it).
///   - Skips sockets whose PID is still bound to a live `CrowApp` process
///     (defensive — must not reap a peer's server out from under it).
///   - Otherwise: runs `tmux -S <socket> kill-server` (no-op if already
///     dead), then unlinks the socket file.
public enum TmuxOrphanReaper {

    /// Scan `$TMPDIR` and reap orphans. Returns the number of sockets
    /// cleaned up (purely informational — caller can log).
    @discardableResult
    public static func reap(tmuxBinary: String, currentPID: pid_t) -> Int {
        let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: tmpdir) else { return 0 }
        // Capture PID via regex; matches our explicit naming pattern in
        // AppDelegate.launchMainApp ("crow-tmux-\(pid).sock").
        let socketRegex = try! NSRegularExpression(pattern: #"^crow-tmux-(\d+)\.sock$"#)
        var reaped = 0
        for name in entries {
            let nsName = name as NSString
            let range = NSRange(location: 0, length: nsName.length)
            guard let match = socketRegex.firstMatch(in: name, range: range),
                  let pidRange = Range(match.range(at: 1), in: name),
                  let pid = pid_t(name[pidRange])
            else { continue }
            if pid == currentPID { continue }
            if processIsCrowApp(pid: pid) { continue }
            let socketPath = (tmpdir as NSString).appendingPathComponent(name)
            killServer(tmuxBinary: tmuxBinary, socketPath: socketPath)
            try? fm.removeItem(atPath: socketPath)
            NSLog("[CrowTelemetry tmux:orphan_reaped pid=\(pid) socket=\(socketPath)]")
            reaped += 1
        }
        if reaped > 0 {
            NSLog("[Crow] Reaped \(reaped) orphan tmux server(s) from past Crow runs")
        }
        return reaped
    }

    /// True if `pid` is alive AND the process at that PID is a CrowApp.
    /// Uses `/bin/ps -p <pid> -o command=` and matches against "CrowApp" in
    /// the executable path. False when the PID is dead, when ps fails, or
    /// when the PID has been reused by an unrelated process (PID reuse
    /// after a Crow crash) — exactly the cases where reaping is correct.
    private static func processIsCrowApp(pid: pid_t) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "command="]
        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let cmd = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cmd.contains("CrowApp")
    }

    /// Best-effort `tmux -S <socket> kill-server`. Failures are normal and
    /// silenced: the socket may be stale (no process bound), the server may
    /// have exited between our check and this call, or the socket may not
    /// be a tmux socket at all (paranoid case). We don't care — the unlink
    /// of the file is the load-bearing cleanup.
    private static func killServer(tmuxBinary: String, socketPath: String) {
        let ctrl = TmuxController(
            tmuxBinary: tmuxBinary,
            socketPath: socketPath,
            sessionName: TmuxBackend.cockpitSessionName
        )
        ctrl.killServer()
    }
}
