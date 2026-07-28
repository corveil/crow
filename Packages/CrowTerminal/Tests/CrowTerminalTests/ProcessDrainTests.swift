import Foundation
import Testing
@testable import CrowTerminal

/// Regression tests for the CROW-874 subprocess wedge.
///
/// Deliberately **not** gated on `discoveredTmuxBinary`: these exercise the
/// process/pipe plumbing, not tmux, so they must run everywhere — including CI
/// hosts with no tmux formula. `CrowTerminal` is excluded from PR CI entirely
/// (ADR 0007), which is all the more reason not to add a second gate.
@Suite("Process drain (CROW-874)")
struct ProcessDrainTests {
    /// `run()` builds argv as `[tmuxBinary, "-S", socketPath] + args`. Parking
    /// `sh -c` in the socket slot and pointing the binary at `env -S` turns that
    /// into `env sh -c <script>` — a real `run()` call against a real child, with
    /// no stub binary to install.
    private func shellController() -> TmuxController {
        TmuxController(tmuxBinary: "/usr/bin/env", socketPath: "sh -c", sessionName: "drain-probe")
    }

    @Test func drainIsBoundedWhenAGrandchildHoldsThePipeOpen() throws {
        // `sleep 30 &` inherits the stdout pipe and outlives the shell, so the
        // read end never sees EOF. Before the fix this blocked for the full 30s
        // — on the MainActor, for `reload-tmux-config` and friends.
        let started = Date()
        let out = try shellController().run(["printf ALPHA; sleep 30 &"], timeout: 1.0)
        let elapsed = Date().timeIntervalSince(started)

        // Lower bound as well as upper: without it this passes vacuously if a
        // later change makes the drain return early for some unrelated reason.
        #expect(elapsed >= TmuxController.drainGrace)
        #expect(elapsed < TmuxController.drainGrace + 2.0,
                "drain took \(elapsed)s; should be bounded by drainGrace, not the grandchild")
        // The child exited before the drain deadline, so every byte it wrote is
        // already captured — this is what the incremental reader buys.
        // `readDataToEndOfFile` would have yielded "" here.
        #expect(out == "ALPHA")
    }

    @Test func drainDoesNotDelayTheNormalPath() throws {
        // The bound must not tax the 99.9% case: with no fd holder, EOF arrives
        // immediately and `run()` must not wait out drainGrace.
        let started = Date()
        let out = try shellController().run(["printf BRAVO"], timeout: 2.0)
        #expect(out == "BRAVO")
        #expect(Date().timeIntervalSince(started) < TmuxController.drainGrace)
    }

    @Test func nonZeroExitStillReportsStderr() throws {
        // Bounding the drain must not cost the diagnostics on the failure path.
        #expect(throws: TmuxError.self) {
            try shellController().run(["printf CHARLIE 1>&2; exit 3"], timeout: 2.0)
        }
        do {
            _ = try shellController().run(["printf CHARLIE 1>&2; exit 3"], timeout: 2.0)
        } catch let TmuxError.cliFailed(_, status, _, stderr) {
            #expect(status == 3)
            #expect(stderr == "CHARLIE")
        }
    }

    @Test func ptyChildDoesNotInheritUnrelatedDescriptors() throws {
        // The root cause: posix_spawn hands the child a copy of the whole fd
        // table unless CLOEXEC_DEFAULT is set, and PTYProcess's children are the
        // cockpit attach clients — the longest-lived processes Crow spawns. A
        // TmuxController pipe write end captured that way is exactly why the
        // drain above never saw EOF.
        //
        // Asks the child to *use* the descriptor rather than watching the pipe
        // for EOF: EOF is a property of every holder of the write end, so any
        // other test spawning concurrently would make that signal lie. A write
        // that lands can only have come from this child.
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { close(readEnd); close(writeEnd) }

        let pty = PTYProcess(deliverOnMainQueue: false)
        try pty.start(command: "echo LEAKED >&\(writeEnd); sleep 1", workingDirectory: nil)
        defer { pty.terminate() }

        // Give the child time to run the echo, then look for its output. The
        // shell's own error text goes to the PTY, not this pipe, so anything
        // arriving here is proof of inheritance.
        var poller = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, 1500)

        if ready > 0 {
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, 64) }
            let text = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
            #expect(!text.contains("LEAKED"),
                    "PTY child inherited fd \(writeEnd) — posix_spawn needs CLOEXEC_DEFAULT (CROW-874)")
        }
    }
}
