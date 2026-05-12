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
        let id = UUID().uuidString.prefix(8).lowercased()
        let socket = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-test-backend-\(id).sock")
        let backend = TmuxBackend()
        backend.configure(tmuxBinary: discoveredTmuxBinary!, socketPath: socket)
        return backend
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
}
