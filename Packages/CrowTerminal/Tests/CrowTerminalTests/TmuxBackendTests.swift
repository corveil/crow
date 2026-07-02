import Foundation
import Testing
@testable import CrowCore
@testable import CrowTerminal

/// Integration tests for `TmuxBackend`'s tmux-side logic. The xterm.js
/// surface side (`cockpitSurface()`) requires a visible NSWindow and is
/// covered separately by the visual demo path. Skipped automatically
/// when no tmux binary is present on the host.
@MainActor
// Serialized: these are real-tmux integration tests that spawn login shells and
// assert on readiness *timing* (e.g. a 0.15s watch budget). Run in parallel they
// contend for CPU during shell startup and the tight-timing cases flake — most
// visibly once the #408 concurrent-launch test spins up several shells at once.
@Suite("TmuxBackend integration", .enabled(if: discoveredTmuxBinary != nil), .serialized)
struct TmuxBackendTests {

    private func makeBackend() -> TmuxBackend {
        makeBackend(socket: sharedSocketPath())
    }

    /// Configure a backend on a caller-chosen socket. The persistence tests
    /// (#330) need two distinct backend instances pointed at the *same* socket
    /// to model a quit/relaunch where the server outlived the app.
    private func makeBackend(socket: String) -> TmuxBackend {
        let backend = TmuxBackend()
        backend.configure(tmuxBinary: discoveredTmuxBinary!, socketPath: socket)
        return backend
    }

    private func sharedSocketPath() -> String {
        let id = UUID().uuidString.prefix(8).lowercased()
        return (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-test-backend-\(id).sock")
    }

    /// Mirrors `TmuxBackend.sentinelPath(for:)` (which is private). Kept in sync
    /// by the sentinel-survival test — if the format drifts, that test's
    /// killServer assertion fails loudly.
    private func sentinelPath(for id: UUID) -> String {
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        return (dir as NSString)
            .appendingPathComponent("crow-ready-\(id.uuidString).sentinel")
    }

    /// Best-effort kill of a server left running by a `killServer: false`
    /// shutdown in a test, so we don't leak tmux servers across the suite.
    private func killLeftoverServer(socket: String) {
        TmuxController(
            tmuxBinary: discoveredTmuxBinary!,
            socketPath: socket,
            sessionName: TmuxBackend.cockpitSessionName
        ).killServer()
    }

    @Test func registerTerminalCreatesWindowAndBinding() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let id = UUID()
        let binding = try backend.registerTerminal(
            id: id,
            name: "test",
            cwd: NSHomeDirectory(),
            command: nil,
            trackReadiness: false
        )
        #expect(binding.sessionName == TmuxBackend.cockpitSessionName)
        #expect(binding.windowIndex >= 0)
        #expect(backend.isRunning)
    }

    @Test func multipleRegistersGetDistinctWindowIndices() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let bindingA = try backend.registerTerminal(
            id: UUID(), name: "a", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        let bindingB = try backend.registerTerminal(
            id: UUID(), name: "b", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        #expect(bindingA.windowIndex != bindingB.windowIndex)
    }

    @Test func makeActiveOnUnregisteredThrows() async throws {
        let backend = makeBackend()
        defer { backend.shutdown() }
        // Register one terminal so the server is up.
        _ = try backend.registerTerminal(
            id: UUID(), name: "anchor", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        #expect(throws: TmuxBackendError.self) {
            try backend.makeActive(id: UUID())  // unrelated id
        }
    }

    @Test func makeActiveTracksActiveTerminal() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let a = UUID()
        let b = UUID()
        _ = try backend.registerTerminal(
            id: a, name: "a", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        _ = try backend.registerTerminal(
            id: b, name: "b", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )

        try backend.makeActive(id: a)
        #expect(backend.activeTerminalID == a)
        // Re-activating the same terminal is a no-op but must not lose the
        // marker (the dedup path returns early without touching it).
        try backend.makeActive(id: a)
        #expect(backend.activeTerminalID == a)

        try backend.makeActive(id: b)
        #expect(backend.activeTerminalID == b)

        // Destroying the active terminal clears the marker so a reused window
        // index can't be wrongly deduped away.
        backend.destroyTerminal(id: b)
        #expect(backend.activeTerminalID == nil)
    }

    @Test func destroyRemovesBinding() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let id = UUID()
        _ = try backend.registerTerminal(
            id: id, name: "kill-me", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        backend.destroyTerminal(id: id)
        #expect(throws: TmuxBackendError.self) {
            try backend.makeActive(id: id)  // should now be unknown
        }
    }

    @Test func adoptThrowsForMissingWindow() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        // Register one terminal so the server has a session.
        _ = try backend.registerTerminal(
            id: UUID(), name: "real", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )

        let phantomBinding = TmuxBinding(
            socketPath: backend.socketPath,
            sessionName: TmuxBackend.cockpitSessionName,
            windowIndex: 9999
        )
        #expect(throws: TmuxBackendError.self) {
            try backend.adoptTerminal(id: UUID(), binding: phantomBinding, trackReadiness: false)
        }
    }

    @Test func sendTextRoundTripsThroughBuffer() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let id = UUID()
        // /bin/cat as the window's child echoes whatever we send.
        let binding = try backend.registerTerminal(
            id: id,
            name: "cat-window",
            cwd: NSHomeDirectory(),
            command: nil,
            trackReadiness: false
        )

        // sendText shouldn't throw for a known terminal.
        let payload = "PROD2-TEST-\(UUID().uuidString)"
        try backend.sendText(id: id, text: payload)

        // Verify the controller produced a window in the expected place.
        // We're not asserting on echo content here — that's brittle in a
        // unit test. The actual delivery is exercised in
        // TmuxController's loadBufferAndPaste test.
        #expect(binding.windowIndex >= 0)
    }

    @Test func sendTextWithTrailingNewlineDoesNotThrow() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let id = UUID()
        _ = try backend.registerTerminal(
            id: id,
            name: "newline-test",
            cwd: NSHomeDirectory(),
            command: nil,
            trackReadiness: false
        )

        // Trailing \n triggers the paste + separate Enter path (#264/#272).
        // Verify the full code path executes without throwing.
        let payload = "AUTO-RESPOND-TEST-\(UUID().uuidString)\n"
        try backend.sendText(id: id, text: payload)
    }

    @Test func sendTextEmptyWithNewlineDoesNotThrow() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let id = UUID()
        _ = try backend.registerTerminal(
            id: id,
            name: "bare-enter",
            cwd: NSHomeDirectory(),
            command: nil,
            trackReadiness: false
        )

        // Edge case: bare "\n" should only send Enter (no paste).
        try backend.sendText(id: id, text: "\n")
    }

    /// Regression for #486: when the user mouse-wheels into copy-mode and
    /// Crow then issues a programmatic send (Manager paste, auto-respond,
    /// quick action), the pane must be cancelled out of copy-mode before
    /// `paste-buffer` runs — otherwise the paste is silently swallowed.
    @Test func sendTextCancelsCopyModeBeforePaste() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let id = UUID()
        let binding = try backend.registerTerminal(
            id: id,
            name: "copy-mode-cancel",
            cwd: NSHomeDirectory(),
            command: nil,
            trackReadiness: false
        )

        // Force the pane into copy-mode via a side-channel controller.
        let ctrl = TmuxController(
            tmuxBinary: discoveredTmuxBinary!,
            socketPath: backend.socketPath,
            sessionName: TmuxBackend.cockpitSessionName
        )
        let target = "\(TmuxBackend.cockpitSessionName):\(binding.windowIndex)"
        _ = try ctrl.run(["copy-mode", "-H", "-t", target])

        let inModeBefore = try ctrl.run([
            "display-message", "-p", "-t", target, "-F", "#{pane_in_mode}"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(inModeBefore == "1")

        // sendText should pre-cancel copy-mode so the paste actually lands.
        try backend.sendText(id: id, text: "PROD2-486-\(UUID().uuidString)")

        let inModeAfter = try ctrl.run([
            "display-message", "-p", "-t", target, "-F", "#{pane_in_mode}"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(inModeAfter == "0")
    }

    /// Sanity: the if-shell guard around `send-keys -X cancel` must not
    /// error when the pane is NOT in a mode (the common case). Otherwise
    /// every send would start failing.
    @Test func sendTextOnNormalPaneIsUnaffectedByCancelGuard() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let id = UUID()
        _ = try backend.registerTerminal(
            id: id,
            name: "no-copy-mode",
            cwd: NSHomeDirectory(),
            command: nil,
            trackReadiness: false
        )

        // Pane is in its normal state. The new cancel-if-active step should
        // be a no-op; sendText must still complete cleanly.
        try backend.sendText(id: id, text: "PROD2-486-normal-\(UUID().uuidString)\n")
    }

    /// Regression for the bare-Enter leg of #486: `crow send "\n"` (and the
    /// `sendTextEmptyWithNewlineDoesNotThrow` shape) skip the paste path
    /// entirely and go straight to `send-keys Enter`. Without the pre-cancel
    /// hoisted out of the `if !payload.isEmpty` block, the Enter is routed
    /// through the copy-mode key table (emacs `copy-selection-and-cancel`,
    /// vi `cancel`) — exits copy-mode but never delivers a CR to the shell.
    /// Verify the cancel still runs and the pane leaves copy-mode.
    @Test func sendTextBareEnterCancelsCopyMode() throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let id = UUID()
        let binding = try backend.registerTerminal(
            id: id,
            name: "bare-enter-copy-mode",
            cwd: NSHomeDirectory(),
            command: nil,
            trackReadiness: false
        )

        let ctrl = TmuxController(
            tmuxBinary: discoveredTmuxBinary!,
            socketPath: backend.socketPath,
            sessionName: TmuxBackend.cockpitSessionName
        )
        let target = "\(TmuxBackend.cockpitSessionName):\(binding.windowIndex)"
        _ = try ctrl.run(["copy-mode", "-H", "-t", target])

        let inModeBefore = try ctrl.run([
            "display-message", "-p", "-t", target, "-F", "#{pane_in_mode}"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(inModeBefore == "1")

        // Bare "\n" — empty payload, didPaste stays false. The pre-cancel
        // must still run.
        try backend.sendText(id: id, text: "\n")

        let inModeAfter = try ctrl.run([
            "display-message", "-p", "-t", target, "-F", "#{pane_in_mode}"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(inModeAfter == "0")
    }

    @Test func retryReadinessEmitsTimedOutWhenSentinelMissing() async throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        // Register a terminal with trackReadiness=false so the default 30s
        // watch isn't armed by registerTerminal. The wrapper still touches
        // the sentinel on first prompt — retryReadinessWatch wipes it before
        // the new watch begins, so the test deterministically observes a
        // timeout.
        let id = UUID()
        _ = try backend.registerTerminal(
            id: id, name: "no-watch", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )

        // Capture every readiness event the backend emits for this terminal.
        // No lock needed — TmuxBackend is @MainActor, the test struct is
        // @MainActor, and the callback hops back to MainActor before firing,
        // so all access here is serialized on the main actor.
        var received: [TerminalReadiness] = []
        backend.onReadinessChanged = { reportedID, state in
            guard reportedID == id else { return }
            received.append(state)
        }

        // 150ms is short enough that the idle shell won't fire another
        // precmd while we wait, so the watch will time out.
        backend.retryReadinessWatch(id: id, timeoutBudget: 0.15)

        // Wait long enough for the watch to resolve and the MainActor hop
        // to deliver the callback.
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(received.contains(.timedOut))
        #expect(!received.contains(.shellReady))
    }

    // MARK: - #330 persistence: server survives quit, relaunch re-attaches

    /// A `killServer: false` shutdown (clean app quit) leaves the server and
    /// its windows running. A fresh backend pointed at the same socket — i.e.
    /// the relaunched app — re-binds the existing window via `adoptTerminal`
    /// instead of spawning a new one.
    @Test func serverSurvivesDetachAndIsAdoptedOnRelaunch() throws {
        let socket = sharedSocketPath()
        let backendA = makeBackend(socket: socket)
        let id = UUID()
        let binding = try backendA.registerTerminal(
            id: id, name: "persist", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )

        // Clean quit — detach, don't kill.
        backendA.shutdown(killServer: false)

        // Relaunch: a brand-new backend on the SAME socket finds the live
        // session and adopts the window. backendB.shutdown() (killServer:true)
        // tears the shared server down so nothing leaks.
        let backendB = makeBackend(socket: socket)
        defer { backendB.shutdown() }
        try backendB.adoptTerminal(id: id, binding: binding, trackReadiness: false)
        #expect(backendB.isRegistered(id: id))
        #expect(backendB.isRunning)
    }

    /// A `killServer: true` shutdown tears the server down. The next backend on
    /// the same socket cold-starts a fresh cockpit session (anchor window
    /// only), so the prior window index is gone and adoption fails — the
    /// post-reboot clean-slate path.
    @Test func killServerShutdownTearsDownServer() throws {
        let socket = sharedSocketPath()
        let backendA = makeBackend(socket: socket)
        let id = UUID()
        let binding = try backendA.registerTerminal(
            id: id, name: "ephemeral", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        backendA.shutdown(killServer: true)

        let backendB = makeBackend(socket: socket)
        defer { backendB.shutdown() }
        #expect(throws: TmuxBackendError.self) {
            try backendB.adoptTerminal(id: id, binding: binding, trackReadiness: false)
        }
    }

    /// The sentinel file is KEPT across a `killServer: false` shutdown (so the
    /// next launch's `adoptTerminal` can detect the already-ready shell) and
    /// UNLINKED across a `killServer: true` shutdown (legacy cleanup).
    @Test func sentinelKeptOnDetachRemovedOnKill() throws {
        // killServer:false → sentinel survives. Independent id/socket per half
        // so the two assertions don't share any state.
        let keptID = UUID()
        let keptSentinel = sentinelPath(for: keptID)
        let detachSocket = sharedSocketPath()
        let detached = makeBackend(socket: detachSocket)
        _ = try detached.registerTerminal(
            id: keptID, name: "s", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        FileManager.default.createFile(atPath: keptSentinel, contents: nil)
        detached.shutdown(killServer: false)
        #expect(FileManager.default.fileExists(atPath: keptSentinel))
        killLeftoverServer(socket: detachSocket)
        try? FileManager.default.removeItem(atPath: keptSentinel)

        // killServer:true → sentinel removed.
        let killedID = UUID()
        let killedSentinel = sentinelPath(for: killedID)
        let killSocket = sharedSocketPath()
        let killed = makeBackend(socket: killSocket)
        _ = try killed.registerTerminal(
            id: killedID, name: "s", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        FileManager.default.createFile(atPath: killedSentinel, contents: nil)
        killed.shutdown(killServer: true)
        #expect(!FileManager.default.fileExists(atPath: killedSentinel))

        try? FileManager.default.removeItem(atPath: killedSentinel)
    }

    /// Adopting with `trackReadiness: false` must NOT fire `.shellReady`, even
    /// when the sentinel still exists from before the quit. This is what stops
    /// SessionService from pasting a second `claude --continue` into a pane
    /// where Claude is already running on relaunch (#330).
    @Test func adoptWithoutReadinessDoesNotEmitShellReady() async throws {
        let socket = sharedSocketPath()
        let backendA = makeBackend(socket: socket)
        let id = UUID()
        let binding = try backendA.registerTerminal(
            id: id, name: "ready-test", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        // Simulate the wrapper having marked the shell ready before the quit.
        let sentinel = sentinelPath(for: id)
        FileManager.default.createFile(atPath: sentinel, contents: nil)
        backendA.shutdown(killServer: false)

        let backendB = makeBackend(socket: socket)
        defer { backendB.shutdown() }  // killServer:true also unlinks the sentinel

        var received: [TerminalReadiness] = []
        backendB.onReadinessChanged = { reportedID, state in
            guard reportedID == id else { return }
            received.append(state)
        }
        try backendB.adoptTerminal(id: id, binding: binding, trackReadiness: false)
        // Give any erroneous MainActor callback hop a chance to land.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(received.isEmpty)
    }

    // MARK: - #408 concurrent managed launch: no bare-zsh orphans

    /// The #408 repro. Spawn several managed terminals at once, each deferring
    /// its launch until `.shellReady` (registered with `command: nil`, then the
    /// command pasted on the readiness fire — exactly what the new-terminal RPC
    /// now does). Every window must reach readiness and run the pasted process;
    /// none may be left at a bare login shell.
    @Test func concurrentManagedLaunchesAllReachReadyNoBareShells() async throws {
        let backend = makeBackend()
        defer { backend.shutdown() }

        let n = 6
        let ids = (0..<n).map { _ in UUID() }
        var windowIndexByID: [UUID: Int] = [:]
        var ready = Set<UUID>()
        var timedOut = Set<UUID>()

        backend.onReadinessChanged = { id, state in
            switch state {
            case .shellReady:
                guard !ready.contains(id) else { return }
                ready.insert(id)
                // The deferred paste: `exec` a marker process so the pane is no
                // longer a bare login shell — proof the launch landed in a live
                // shell rather than being dropped (the #408 failure).
                try? backend.sendText(id: id, text: "exec sleep 97\n")
            case .timedOut:
                timedOut.insert(id)
            default:
                break
            }
        }

        for id in ids {
            let binding = try backend.registerTerminal(
                id: id, name: "managed-\(id.uuidString.prefix(4))",
                cwd: NSHomeDirectory(), command: nil, trackReadiness: true
            )
            windowIndexByID[id] = binding.windowIndex
        }

        // Wait (bounded) for all to report `.shellReady`. Shell startup is
        // CPU-contended with N concurrent wrappers; 30s mirrors the backend's
        // default readiness budget.
        let deadline = Date().addingTimeInterval(30)
        while ready.count < n && timedOut.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(timedOut.isEmpty)
        #expect(ready.count == n)

        // Assert no managed window is left at a bare login shell. Poll briefly:
        // the exec'd markers replace their shells asynchronously.
        let ctrl = TmuxController(
            tmuxBinary: discoveredTmuxBinary!, socketPath: backend.socketPath,
            sessionName: TmuxBackend.cockpitSessionName
        )
        let ourIndices = Set(windowIndexByID.values)
        var bareShells: [Int] = []
        let checkDeadline = Date().addingTimeInterval(5)
        repeat {
            try await Task.sleep(nanoseconds: 200_000_000)
            let windows = try ctrl.listWindowCommands().filter { ourIndices.contains($0.index) }
            bareShells = windows
                .filter { TmuxBackend.orphanLoginShells.contains($0.command) }
                .map { $0.index }
        } while !bareShells.isEmpty && Date() < checkDeadline

        #expect(bareShells.isEmpty)
    }

    // MARK: - #450 stale-config reconciliation

    /// Integration regression for #450: when Crow attaches to a tmux server
    /// that loaded an older bundled conf, source-file the on-disk version on
    /// the live server so server-scoped options catch up — without touching
    /// existing windows.
    @Test func staleConfIsReconciledOnAttach() throws {
        let socket = sharedSocketPath()
        let dir = NSTemporaryDirectory() as NSString
        let confPath = dir.appendingPathComponent("crow-test-conf-\(UUID().uuidString.prefix(8)).conf")
        defer { try? FileManager.default.removeItem(atPath: confPath) }

        // Conf A: status on. Back-date the file so its mtime is clearly older
        // than the server we're about to start.
        try "set -gs status on\n".write(toFile: confPath, atomically: true, encoding: .utf8)
        let oldMTime = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes(
            [.modificationDate: oldMTime], ofItemAtPath: confPath
        )

        let ctrl = TmuxController(
            tmuxBinary: discoveredTmuxBinary!,
            socketPath: socket,
            sessionName: TmuxBackend.cockpitSessionName
        )
        defer {
            ctrl.killServer()
            try? FileManager.default.removeItem(atPath: socket)
        }
        try ctrl.newSessionDetached(
            configPath: confPath,
            command: "/usr/bin/tail -f /dev/null"
        )
        let beforeWindows = try ctrl.listWindowIndices()
        let statusBefore = try ctrl.run(["show", "-gv", "status"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(statusBefore == "on")

        // Conf B: status off. mtime defaults to now → clearly newer than the
        // server's start time.
        try "set -gs status off\n".write(toFile: confPath, atomically: true, encoding: .utf8)

        TmuxBackend.reconcileBundledConfigIfStale(
            controller: ctrl,
            configURL: URL(fileURLWithPath: confPath)
        )

        let statusAfter = try ctrl.run(["show", "-gv", "status"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(statusAfter == "off")

        // Existing windows survive.
        let afterWindows = try ctrl.listWindowIndices()
        #expect(afterWindows == beforeWindows)
    }

    /// When the conf is older than the server start, reconciliation is a
    /// no-op — the running settings stay as-is.
    @Test func freshConfIsNotReconciled() throws {
        let socket = sharedSocketPath()
        let dir = NSTemporaryDirectory() as NSString
        let confPath = dir.appendingPathComponent("crow-test-conf-\(UUID().uuidString.prefix(8)).conf")
        defer { try? FileManager.default.removeItem(atPath: confPath) }

        // Conf seeds status=on at server start.
        try "set -gs status on\n".write(toFile: confPath, atomically: true, encoding: .utf8)
        let ctrl = TmuxController(
            tmuxBinary: discoveredTmuxBinary!,
            socketPath: socket,
            sessionName: TmuxBackend.cockpitSessionName
        )
        defer {
            ctrl.killServer()
            try? FileManager.default.removeItem(atPath: socket)
        }
        try ctrl.newSessionDetached(
            configPath: confPath,
            command: "/usr/bin/tail -f /dev/null"
        )

        // Rewrite the file content but back-date mtime so it predates server
        // start. Reconciler must skip and the running value must not change.
        try "set -gs status off\n".write(toFile: confPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: confPath
        )

        TmuxBackend.reconcileBundledConfigIfStale(
            controller: ctrl,
            configURL: URL(fileURLWithPath: confPath)
        )

        let status = try ctrl.run(["show", "-gv", "status"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(status == "on")
    }
}

// MARK: - CROW-487 crowBinDir propagation

/// `configure(...)` stores the per-devroot bin dir so `registerTerminal` can
/// inject `CROW_BIN_DIR` (consumed by the shell wrapper to win PATH precedence
/// after user rc sourcing — see crow-shell-wrapper.sh). Separate suite so it
/// runs even when tmux isn't installed — the integration suite is gated on
/// `discoveredTmuxBinary != nil`, but this check is pure state propagation.
@MainActor
@Suite("TmuxBackend crowBinDir")
struct TmuxBackendCrowBinDirTests {
    @Test func configurePropagatesCrowBinDir() {
        let backend = TmuxBackend()
        backend.configure(
            tmuxBinary: "/usr/bin/tmux",
            socketPath: "/tmp/crow-487-probe.sock",
            crowBinDir: "/devroot/.claude/bin"
        )
        #expect(backend.crowBinDir == "/devroot/.claude/bin")
    }

    @Test func configureDefaultsCrowBinDirToEmpty() {
        let backend = TmuxBackend()
        backend.configure(
            tmuxBinary: "/usr/bin/tmux",
            socketPath: "/tmp/crow-487-probe.sock"
        )
        #expect(backend.crowBinDir == "")
    }
}

/// Pure-policy tests for `shouldReconcile`. No tmux required, so the suite is
/// always enabled (unlike the integration suite above).
@Suite("TmuxBackend stale-config policy")
struct TmuxBackendConfigPolicyTests {
    @Test func reconcileWhenConfNewer() {
        let server = Date(timeIntervalSince1970: 1_000)
        let conf = Date(timeIntervalSince1970: 2_000)
        #expect(TmuxBackend.shouldReconcile(configMTime: conf, serverStartTime: server))
    }

    @Test func skipWhenConfOlder() {
        let server = Date(timeIntervalSince1970: 2_000)
        let conf = Date(timeIntervalSince1970: 1_000)
        #expect(!TmuxBackend.shouldReconcile(configMTime: conf, serverStartTime: server))
    }

    @Test func skipWhenConfEqualsServerStart() {
        let same = Date(timeIntervalSince1970: 1_500)
        #expect(!TmuxBackend.shouldReconcile(configMTime: same, serverStartTime: same))
    }

    @Test func reconcileWhenServerStartUnknown() {
        let conf = Date(timeIntervalSince1970: 1_000)
        #expect(TmuxBackend.shouldReconcile(configMTime: conf, serverStartTime: nil))
    }

    @Test func reconcileWhenConfMTimeUnknown() {
        let server = Date(timeIntervalSince1970: 1_000)
        #expect(TmuxBackend.shouldReconcile(configMTime: nil, serverStartTime: server))
    }

    @Test func reconcileWhenBothUnknown() {
        #expect(TmuxBackend.shouldReconcile(configMTime: nil, serverStartTime: nil))
    }
}

/// Policy tests for the Manager exit detector (#558): report an exit only once
/// the agent was seen running and the window's foreground has fallen back to a
/// bare login shell. Pure over `managerAgentDidExit`, so no tmux needed.
@Suite("Manager exit-monitor policy (#558)")
struct ManagerExitMonitorTests {

    @Test func firesWhenAgentRanThenDroppedToShell() {
        // The agent (claude/codex/…) exited and the pane fell back to a shell.
        #expect(TmuxBackend.managerAgentDidExit(paneCommand: "zsh", sawAgentRunning: true))
        #expect(TmuxBackend.managerAgentDidExit(paneCommand: "-zsh", sawAgentRunning: true))
        #expect(TmuxBackend.managerAgentDidExit(paneCommand: "bash", sawAgentRunning: true))
        #expect(TmuxBackend.managerAgentDidExit(paneCommand: "fish", sawAgentRunning: true))
    }

    @Test func doesNotFireBeforeAgentSeenRunning() {
        // Startup window: the wrapper shell shows before `claude` launches.
        #expect(!TmuxBackend.managerAgentDidExit(paneCommand: "zsh", sawAgentRunning: false))
        #expect(!TmuxBackend.managerAgentDidExit(paneCommand: "bash", sawAgentRunning: false))
    }

    @Test func doesNotFireWhileAgentRunning() {
        // A non-shell foreground means the agent (or a child of it) is running.
        #expect(!TmuxBackend.managerAgentDidExit(paneCommand: "claude", sawAgentRunning: true))
        #expect(!TmuxBackend.managerAgentDidExit(paneCommand: "node", sawAgentRunning: true))
        #expect(!TmuxBackend.managerAgentDidExit(paneCommand: "codex", sawAgentRunning: true))
    }

    @Test func doesNotFireWhenWindowGone() {
        // nil = display-message failed / window vanished. Covers attach-client
        // teardown and restart/shutdown — never a false positive.
        #expect(!TmuxBackend.managerAgentDidExit(paneCommand: nil, sawAgentRunning: true))
        #expect(!TmuxBackend.managerAgentDidExit(paneCommand: nil, sawAgentRunning: false))
    }
}
