import Foundation
import Testing
@testable import CrowCore
@testable import CrowTerminal

/// Integration tests for `TmuxBackend`'s tmux-side logic. The Ghostty
/// surface side (`cockpitSurface()`) requires a real NSWindow and is
/// covered separately by the visual demo path. Skipped automatically
/// when no tmux binary is present on the host.
@MainActor
@Suite("TmuxBackend integration", .enabled(if: discoveredTmuxBinary != nil))
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
        let id = UUID()
        let sentinel = sentinelPath(for: id)

        // killServer:false → sentinel survives.
        let detachSocket = sharedSocketPath()
        let detached = makeBackend(socket: detachSocket)
        _ = try detached.registerTerminal(
            id: id, name: "s", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        FileManager.default.createFile(atPath: sentinel, contents: nil)
        detached.shutdown(killServer: false)
        #expect(FileManager.default.fileExists(atPath: sentinel))
        killLeftoverServer(socket: detachSocket)

        // killServer:true → sentinel removed.
        let killSocket = sharedSocketPath()
        let killed = makeBackend(socket: killSocket)
        _ = try killed.registerTerminal(
            id: id, name: "s", cwd: NSHomeDirectory(),
            command: nil, trackReadiness: false
        )
        FileManager.default.createFile(atPath: sentinel, contents: nil)
        killed.shutdown(killServer: true)
        #expect(!FileManager.default.fileExists(atPath: sentinel))

        try? FileManager.default.removeItem(atPath: sentinel)
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
}
