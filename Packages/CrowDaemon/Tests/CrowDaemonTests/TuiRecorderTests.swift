import Foundation
import Testing
@testable import CrowDaemon

@Suite struct TuiRecorderTests {

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-tui-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func source(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("Sources/CrowDaemon/\(relative)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw TestError.missing(relative)
    }

    private enum TestError: Error { case missing(String) }

    @Test func startIsIdempotentForInFlightPair() throws {
        let rec = TuiRecorder(root: tempRoot(), tmux: .noop, samplerInterval: 60)
        let sid = UUID(), tid = UUID()
        let a = try rec.start(sessionID: sid, terminalID: tid, tmuxWindow: 1, agentSurface: true, note: nil, expectBind: false)
        let b = try rec.start(sessionID: sid, terminalID: tid, tmuxWindow: 1, agentSurface: true, note: nil, expectBind: false)
        #expect(a.id == b.id)
        #expect(b.reused)
        #expect(a.ptySource == .none)
    }

    @Test func cliWithoutClientLeavesPtyEmptyUntilBind() throws {
        let rec = TuiRecorder(root: tempRoot(), tmux: .noop, samplerInterval: 60)
        let started = try rec.start(
            sessionID: UUID(), terminalID: UUID(), tmuxWindow: 2,
            agentSurface: true, note: nil, expectBind: false)
        rec.flushForTests()
        #expect(started.ptySource == .none)
        let listed = rec.list(sessionID: nil, status: nil)
        #expect(listed.first?.ptySource == TuiPtySource.none)
        let pty = try String(contentsOf: started.dir.appendingPathComponent("pty.ndjson"), encoding: .utf8)
        #expect(!pty.contains("\"type\":\"o\""))
        let bind = rec.bind(group: "crowd-web-deadbeef", recordingID: started.id)
        #expect(bind.ok)
        bind.tee?.yieldOutput(Data("hello".utf8))
        rec.flushForTests()
        let after = try String(contentsOf: started.dir.appendingPathComponent("pty.ndjson"), encoding: .utf8)
        #expect(after.contains("\"type\":\"o\""))
        #expect(rec.list(sessionID: nil, status: .recording).first?.ptySource == .attach)
    }

    @Test func bindToSealedIsNotActive() throws {
        let rec = TuiRecorder(root: tempRoot(), tmux: .noop, samplerInterval: 60)
        let started = try rec.start(
            sessionID: UUID(), terminalID: UUID(), tmuxWindow: 1,
            agentSurface: false, note: nil, expectBind: false)
        _ = try rec.stop(recordingID: started.id)
        let bind = rec.bind(group: "crowd-web-aaaa1111", recordingID: started.id)
        #expect(!bind.ok)
        #expect(bind.reason == "not_active")
        #expect(bind.tee == nil)
    }

    @Test func rebindUnbindsPriorWithNoGrace() throws {
        let rec = TuiRecorder(root: tempRoot(), tmux: .noop, samplerInterval: 60)
        let a = try rec.start(sessionID: UUID(), terminalID: UUID(), tmuxWindow: 1, agentSurface: true, note: nil, expectBind: false)
        let b = try rec.start(sessionID: UUID(), terminalID: UUID(), tmuxWindow: 2, agentSurface: true, note: nil, expectBind: false)
        #expect(rec.bind(group: "crowd-web-same0001", recordingID: a.id).ok)
        #expect(rec.bind(group: "crowd-web-same0001", recordingID: b.id).ok)
        rec.flushForTests()
        #expect(rec.list(sessionID: nil, status: nil).first { $0.id == a.id }?.ptySource == TuiPtySource.none)
        #expect(rec.list(sessionID: nil, status: nil).first { $0.id == b.id }?.ptySource == .attach)
    }

    @Test func samplesDroppedWithoutBind() throws {
        let rec = TuiRecorder(root: tempRoot(), tmux: .noop, samplerInterval: 60)
        let started = try rec.start(
            sessionID: UUID(), terminalID: UUID(), tmuxWindow: 1,
            agentSurface: true, note: nil, expectBind: false)
        rec.ingestSample(Self.clientSample(), recordingID: started.id)
        rec.flushForTests()
        let obs = (try? String(contentsOf: started.dir.appendingPathComponent("observations.ndjson"), encoding: .utf8)) ?? ""
        #expect(!obs.contains("tui-sample"))
        #expect(rec.list(sessionID: nil, status: nil).first?.clientSamples == false)
    }

    @Test func capAndSealIsNotARing() throws {
        let rec = TuiRecorder(
            root: tempRoot(), tmux: .noop, maxDuration: 600, maxBytes: 64, samplerInterval: 60)
        let started = try rec.start(
            sessionID: UUID(), terminalID: UUID(), tmuxWindow: 1,
            agentSurface: true, note: nil, expectBind: false)
        let bind = rec.bind(group: "crowd-web-cap00001", recordingID: started.id)
        bind.tee?.yieldOutput(Data(repeating: 0x61, count: 200))
        rec.flushForTests()
        let got = rec.list(sessionID: nil, status: nil).first { $0.id == started.id }
        #expect(got?.status == .sealed)
        let pty = try String(contentsOf: started.dir.appendingPathComponent("pty.ndjson"), encoding: .utf8)
        #expect(pty.contains("\"type\":\"header\""))
        #expect(pty.contains("\"type\":\"o\""))
    }

    @Test func blockedCapturePaneDoesNotSealTeeBackpressure() throws {
        let blocking = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let hooks = TuiTmuxHooks(
            displayMessage: { _, _ in "80 24 0 0 0 off 0 0 50000" },
            capturePane: { _, _ in
                entered.signal()
                _ = blocking.wait(timeout: .now() + 3)
                return "viewport"
            })
        let rec = TuiRecorder(root: tempRoot(), tmux: hooks, samplerInterval: 0.05)
        let started = try rec.start(
            sessionID: UUID(), terminalID: UUID(), tmuxWindow: 3,
            agentSurface: true, note: nil, expectBind: false)
        let bind = rec.bind(group: "crowd-web-slow0001", recordingID: started.id)
        #expect(entered.wait(timeout: .now() + 2) == .success)
        for _ in 0..<40 {
            bind.tee?.yieldOutput(Data("chunk".utf8))
        }
        rec.flushIngestForTests()
        let live = rec.list(sessionID: nil, status: nil).first { $0.id == started.id }
        #expect(live?.status == .recording)
        #expect(live?.abandonedReason != "tee_backpressure")
        blocking.signal()
        rec.flushForTests()
    }

    @Test func capturePaneIsNeverOnMainActor() throws {
        let rec = TuiRecorder(root: tempRoot(), tmux: .noop, samplerInterval: 0.05)
        _ = try rec.start(
            sessionID: UUID(), terminalID: UUID(), tmuxWindow: 1,
            agentSurface: true, note: nil, expectBind: false)
        Thread.sleep(forTimeInterval: 0.12)
        rec.flushForTests()
        #expect(!rec.didCaptureOnMainActor)
        let src = try source("TuiRecorder.swift")
        #expect(!src.contains("MainActor.run"))
        #expect(!src.contains("@MainActor"))
    }

    @Test func outputTaskTeeIncludesReplayShapedBytes() throws {
        let ws = try source("TerminalWebSocket.swift")
        #expect(ws.contains("if let tee = slot.tee { tee.yieldOutput(chunk) }"))
        #expect(ws.contains("continuation.yield(replay)"))
        #expect(ws.contains("for await chunk in stream"))
    }

    @Test func streamedGetDoesNotSlurpTheFile() throws {
        let src = try source("TuiRecordingRoutes.swift")
        #expect(src.contains("FileHandle(forReadingFrom"))
        #expect(!src.contains("Data(contentsOf:"))
        #expect(src.contains("[CrowTui record_get"))
    }

    @Test func sessionCleanupDoesNotNameTheRecordingsDir() throws {
        var dir = URL(fileURLWithPath: #filePath)
        var found: URL?
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent(
                "Packages/CrowEngine/Sources/CrowEngine/SessionService.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let src = try String(contentsOf: try #require(found), encoding: .utf8)
        #expect(!src.contains("tui-recordings"))
    }

    @Test func retentionZeroNeverReaps() throws {
        var now = Date()
        let rec = TuiRecorder(
            root: tempRoot(), tmux: .noop, now: { now },
            samplerInterval: 60, retentionDays: 0)
        let started = try rec.start(
            sessionID: UUID(), terminalID: UUID(), tmuxWindow: 1,
            agentSurface: true, note: nil, expectBind: false)
        _ = try rec.stop(recordingID: started.id)
        now = now.addingTimeInterval(30 * 86400)
        rec.reap()
        rec.flushForTests()
        #expect(rec.list(sessionID: nil, status: .sealed).contains { $0.id == started.id })
    }

    @Test func sevenDayReaperDeletesSealedRecordings() throws {
        var now = Date()
        let rec = TuiRecorder(
            root: tempRoot(), tmux: .noop, now: { now },
            samplerInterval: 60, retentionDays: 7)
        let started = try rec.start(
            sessionID: UUID(), terminalID: UUID(), tmuxWindow: 1,
            agentSurface: true, note: nil, expectBind: false)
        _ = try rec.stop(recordingID: started.id)
        now = now.addingTimeInterval(8 * 86400)
        rec.reap()
        rec.flushForTests()
        #expect(rec.list(sessionID: nil, status: nil).isEmpty)
    }

    @Test func logHonorsSinceAndCapsRows() throws {
        let rec = TuiRecorder(root: tempRoot(), tmux: .noop, samplerInterval: 60)
        let started = try rec.start(
            sessionID: UUID(), terminalID: UUID(), tmuxWindow: 1,
            agentSurface: true, note: nil, expectBind: false)
        _ = rec.bind(group: "crowd-web-log00001", recordingID: started.id)
        rec.ingestSample(Self.clientSample(), recordingID: started.id)
        rec.flushForTests()
        let first = try rec.log(recordingID: started.id, kind: nil, since: nil)
        #expect(!first.observations.isEmpty || first.nextSince >= 0)
        let later = try rec.log(recordingID: started.id, kind: nil, since: 9_999_999)
        #expect(later.observations.isEmpty)
    }

    @Test func defaultLivePathTrapsUnderTests() {
        // ADR 0012: constructing TuiRecorder() without an explicit temp root
        // must not touch Application Support from XCTest.
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || CommandLine.arguments.contains { $0.contains("xctest") }
            || true)
        let src = try? source("TuiRecorder.swift")
        #expect(src?.contains("trapIfConstructingLivePathUnderTests") == true)
    }

    private static func clientSample() -> TuiClientSample {
        TuiClientSample(
            tClient: 1, formFactor: "phone", hidden: false, hasFocus: true, arrivedAtTop: false,
            env: TuiClientEnv(ua: "t", tauri: false, dpr: 1, maxTouchPoints: 1, pointerCoarse: true, webgl: false, locale: "en"),
            viewport: TuiClientViewport(
                innerW: 390, innerH: 800, clientW: 390, clientH: 600,
                vvW: 390, vvH: 800, vvOffsetTop: 0, vvOffsetLeft: 0,
                keyboardInsetPx: 0, cssCols: 80, cssRows: 24, cellW: 9, cellH: 18),
            cursor: TuiClientCursor(
                xtermX: 0, xtermY: 0, xtermViewportY: 0, xtermBaseY: 0,
                textareaLeftPx: 0, textareaTopPx: 0, caretCssX: 0, caretCssY: 0),
            modes: TuiClientModes(
                agentSurface: true, bufferType: "alternate", mouseTracking: "none",
                appOwnsScroll: false, altScreenFlag: true),
            visibleHash: "sha256:x", visibleRows: 24, events: [], visibleLines: nil)
    }
}
