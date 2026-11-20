import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// Pre-expiry compaction policy (CROW-1493).
@Suite("Auto-compact policy")
struct AutoCompactPolicyTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let on = ContextCompactionSettings(autoCompact: true, minContextTokens: 200_000, idleMinutes: 50)

    /// A 500k-token Claude session idle 55 minutes on a 1h cache, at its prompt.
    func eligible(_ edit: (inout AutoCompactPolicy.Inputs) -> Void = { _ in }) -> AutoCompactPolicy.Inputs {
        var inputs = AutoCompactPolicy.Inputs(
            agentKind: .claudeCode, status: .active, agentState: .idle,
            snapshot: ContextSnapshot(
                tokens: 500_000, model: "claude-opus-5-5", lastRequestAt: now.addingTimeInterval(-55 * 60),
                cacheTTL: 3_600))
        edit(&inputs)
        return inputs
    }

    func verdict(_ inputs: AutoCompactPolicy.Inputs, _ settings: ContextCompactionSettings? = nil) -> AutoCompactPolicy.Verdict {
        AutoCompactPolicy.evaluate(inputs, settings: settings ?? on, now: now)
    }

    @Test func compactsALargeIdleSessionWhileItsCacheIsWarm() {
        #expect(verdict(eligible()) == .compact)
    }

    @Test func offByDefault() {
        #expect(verdict(eligible(), ContextCompactionSettings()) == .skip(.disabled))
    }

    @Test func neverSendsUnlessTheAgentIsIdle() {
        for state in [AgentReadinessState.working, .waitingPermission, .starting, .exited] {
            #expect(verdict(eligible { $0.agentState = state }) == .skip(.agentNotIdle))
        }
        #expect(verdict(eligible { $0.agentState = nil }) == .skip(.agentNotIdle))
    }

    @Test func claudeCodeOnly() {
        #expect(verdict(eligible { $0.agentKind = .codex }) == .skip(.unsupportedAgent))
    }

    @Test func leavesFinishedSessionsAlone() {
        #expect(verdict(eligible { $0.status = .completed }) == .skip(.inactiveSession))
        #expect(verdict(eligible { $0.status = .archived }) == .skip(.inactiveSession))
        #expect(verdict(eligible { $0.status = .paused }) == .compact)
        #expect(verdict(eligible { $0.status = .inReview }) == .compact)
    }

    @Test func smallContextIsLeftAlone() {
        #expect(verdict(eligible { $0.snapshot?.tokens = 199_999 }) == .skip(.belowThreshold))
        #expect(verdict(eligible { $0.snapshot?.tokens = nil }) == .skip(.belowThreshold))
    }

    @Test func theIdleWindowIsBetweenTheSettingAndTheCacheLifetime() {
        #expect(verdict(eligible { $0.snapshot?.lastRequestAt = now.addingTimeInterval(-49 * 60) })
            == .skip(.notIdleLongEnough))
        // Inside the last minute of the cache: too late to be sure the call lands.
        #expect(verdict(eligible { $0.snapshot?.lastRequestAt = now.addingTimeInterval(-59.5 * 60) })
            == .skip(.cacheExpired))
        #expect(verdict(eligible { $0.snapshot?.lastRequestAt = now.addingTimeInterval(-3 * 3_600) })
            == .skip(.cacheExpired))
    }

    @Test func aFiveMinuteCacheNeedsAShortIdleSetting() {
        let fiveMinute = eligible {
            $0.snapshot?.cacheTTL = 300
            $0.snapshot?.lastRequestAt = now.addingTimeInterval(-3 * 60)
        }
        #expect(verdict(fiveMinute) == .skip(.notIdleLongEnough))
        var short = on
        short.idleMinutes = 2
        #expect(verdict(fiveMinute, short) == .compact)
    }

    @Test func unknownsSkip() {
        #expect(verdict(eligible { $0.snapshot = nil }) == .skip(.noTranscript))
        #expect(verdict(eligible { $0.snapshot?.cacheTTL = nil }) == .skip(.unknownCacheLifetime))
        #expect(verdict(eligible { $0.snapshot?.lastRequestAt = nil }) == .skip(.unknownIdle))
    }

    @Test func oneAttemptPerLastCallAndNoneAfterACompaction() {
        let last = now.addingTimeInterval(-55 * 60)
        #expect(verdict(eligible { $0.lastAttemptFor = last }) == .skip(.alreadyAttempted))
        // A newer call since the last attempt makes it eligible again.
        #expect(verdict(eligible { $0.lastAttemptFor = last.addingTimeInterval(-3_600) }) == .compact)
        #expect(verdict(eligible { $0.snapshot?.compactedAt = now.addingTimeInterval(-60) }) == .skip(.alreadyCompacted))
    }
}

/// The `context` JSON and transcript lookup (CROW-1493).
@Suite("Session context report")
struct SessionContextReportTests {
    @Test func jsonShape() throws {
        let last = Date(timeIntervalSince1970: 2_000_000_000)
        let snap = ContextSnapshot(
            tokens: 512_000, model: "claude-opus-5-5", maxTokens: 1_000_000, lastRequestAt: last, cacheTTL: 3_600)
        let located = SessionContextReport.Located(path: "/x.jsonl", format: .claude)
        let json = SessionContextReport.json((snap, located), largeThreshold: 200_000, now: last.addingTimeInterval(4_000))
        let o = try #require(json.objectValue)
        #expect(o["tokens"] == .int(512_000))
        #expect(o["max_tokens"] == .int(1_000_000))
        #expect(o["idle_seconds"] == .int(4_000))
        #expect(o["cache_ttl_seconds"] == .int(3_600))
        #expect(o["cache_expired"] == .bool(true))
        #expect(o["large"] == .bool(true))
        #expect(o["compacted_at"] == .null)
        // No path: `list-sessions` is remote-readable and needs none.
        #expect(o["path"] == nil)
        #expect(SessionContextReport.json(nil, largeThreshold: 1) == .null)
    }

    @Test func unknownLifetimeIsNullNotFalse() throws {
        let snap = ContextSnapshot(tokens: 10, lastRequestAt: Date())
        let located = SessionContextReport.Located(path: "/x", format: .codex)
        let o = try #require(SessionContextReport.json((snap, located), largeThreshold: 200_000).objectValue)
        #expect(o["cache_expired"] == .null)
        #expect(o["large"] == .bool(false))
    }

    @Test func findsTheTranscriptByConversationIDAndNeverGuesses() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let roots = HarnessTranscriptLocator.Roots(
            claudeProjectsDir: dir.appendingPathComponent("claude").path,
            grokSessionsDir: dir.appendingPathComponent("grok").path,
            codexSessionsDir: dir.appendingPathComponent("codex").path,
            antigravityBrainDir: dir.appendingPathComponent("agy").path,
            museSessionsDir: dir.appendingPathComponent("muse").path)
        let cwd = "/work/repo"
        let project = URL(fileURLWithPath: roots.claudeProjectsDir)
            .appendingPathComponent(AgentLogSource.posixPathSlug(cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        func line(_ tokens: Int) -> String {
            #"{"type":"assistant","timestamp":"2026-11-20T10:00:00.000Z","message":{"model":"claude-opus-5-5","content":[],"usage":{"input_tokens":\#(tokens)}}}"# + "\n"
        }
        try Data(line(111).utf8).write(to: project.appendingPathComponent("conv-a.jsonl"))
        try Data(line(222).utf8).write(to: project.appendingPathComponent("conv-b.jsonl"))
        let cache = ContextSnapshotCache()

        let exact = SessionContextReport.Source(sessionID: UUID(), agentKind: .claudeCode, conversationID: "conv-a", cwd: cwd)
        let hit = try #require(SessionContextReport.snapshot(for: exact, roots: roots, cache: cache))
        #expect(hit.0.tokens == 111)
        #expect(hit.1.format == .claude)

        // No id: no guess at the newest file, even though conv-b is right there.
        let unknown = SessionContextReport.Source(sessionID: UUID(), agentKind: .claudeCode, conversationID: nil, cwd: cwd)
        #expect(SessionContextReport.snapshot(for: unknown, roots: roots, cache: cache) == nil)
    }

    @Test @MainActor func noConversationIDMeansNoSource() {
        let appState = AppState()
        var session = Session(name: "fresh", agentKind: .claudeCode)
        appState.sessions.append(session)
        #expect(SessionContextReport.source(for: session, appState: appState) == nil)
        session.harnessConversationID = "conv"
        #expect(SessionContextReport.source(for: session, appState: appState)?.conversationID == "conv")
        #expect(SessionContextReport.source(for: Session(name: "c", agentKind: .cursor), appState: appState) == nil)
    }

    @Test func cacheRereadsOnlyWhenTheFileChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        func line(_ tokens: Int) -> String {
            #"{"type":"assistant","timestamp":"2026-11-20T10:00:00.000Z","message":{"model":"claude-opus-5-5","content":[],"usage":{"input_tokens":\#(tokens)}}}"# + "\n"
        }
        try Data(line(1).utf8).write(to: file)
        let cache = ContextSnapshotCache()
        #expect(cache.snapshot(path: file.path, format: .claude)?.tokens == 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(2_000).utf8))
        try handle.close()
        #expect(cache.snapshot(path: file.path, format: .claude)?.tokens == 2_000)
        #expect(cache.snapshot(path: dir.appendingPathComponent("missing").path, format: .claude) == nil)
    }
}

/// The controller's guards around the send (CROW-1493). Fake IO, so no tmux.
@Suite("Auto-compact controller")
@MainActor
struct AutoCompactControllerTests {
    final class Recorder {
        var sent: [(UUID, String)] = []
        var composer = "\u{1B}[38;5;244m──────────\n❯ \n\u{1B}[38;5;244m──────────"
        var failSend = false
    }

    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func fixture(
        tokens: Int = 500_000, idleMinutes: Double = 55, autoCompact: Bool = true
    ) -> (AppState, Session, AutoCompactController, Recorder) {
        let appState = AppState()
        var session = Session(name: "big", agentKind: .claudeCode)
        session.harnessConversationID = "conv"
        appState.sessions.append(session)
        let terminal = SessionTerminal(sessionID: session.id, name: "Claude Code", cwd: "/work", isManaged: true)
        appState.terminals[session.id] = [terminal]
        appState.terminalReadiness[terminal.id] = .agentLaunched
        let recorder = Recorder()
        let snap = ContextSnapshot(
            tokens: tokens, model: "claude-opus-5-5", lastRequestAt: now.addingTimeInterval(-idleMinutes * 60),
            cacheTTL: 3_600)
        let located = SessionContextReport.Located(path: "/x.jsonl", format: .claude)
        let controller = AutoCompactController(
            appState: appState,
            settingsProvider: { ContextCompactionSettings(autoCompact: autoCompact) },
            io: AutoCompactController.IO(
                captureComposer: { _ in recorder.composer },
                send: { terminal, text in
                    if recorder.failSend { throw CocoaError(.fileWriteUnknown) }
                    recorder.sent.append((terminal.id, text))
                },
                paneCommands: { [terminal.id: "claude"] }),
            snapshotProvider: { sources in
                Dictionary(uniqueKeysWithValues: sources.map { ($0.sessionID, (snap, located)) })
            })
        return (appState, session, controller, recorder)
    }

    @Test func sendsCompactOnceAndExcusesItFromTheGrade() async {
        let (appState, session, controller, recorder) = fixture()
        let outcomes = await controller.tick(now: now)
        #expect(outcomes.map(\.sent) == [true])
        #expect(recorder.sent.map(\.1) == ["/compact\n"])
        #expect(appState.hookState(for: session.id).crowCompactionRequestedAt == now)
        // Same last call next minute: no second send.
        await controller.tick(now: now.addingTimeInterval(60))
        #expect(recorder.sent.count == 1)
    }

    @Test func aDraftInTheComposerBlocksTheSend() async {
        let (_, _, controller, recorder) = fixture()
        recorder.composer = "──────────\n❯ half-typed thought\n──────────"
        let outcomes = await controller.tick(now: now)
        #expect(outcomes.first?.composer == .hasInput)
        #expect(recorder.sent.isEmpty)
        // Not latched: once the draft is gone the next tick may send.
        recorder.composer = "──────────\n❯ \n──────────"
        await controller.tick(now: now.addingTimeInterval(60))
        #expect(recorder.sent.count == 1)
    }

    @Test func anUnreadablePaneBlocksTheSend() async {
        let (_, _, controller, recorder) = fixture()
        recorder.composer = "Do you want to proceed?\n❯ 1. Yes"
        let outcomes = await controller.tick(now: now)
        #expect(outcomes.first?.composer == .notFound)
        #expect(recorder.sent.isEmpty)
    }

    @Test func aWorkingAgentIsLeftAlone() async {
        let (appState, session, controller, recorder) = fixture()
        appState.hookState(for: session.id).activityState = .working
        let outcomes = await controller.tick(now: now)
        #expect(outcomes.first?.verdict == .skip(.agentNotIdle))
        #expect(recorder.sent.isEmpty)
    }

    @Test func offMeansNoWorkAtAll() async {
        let (_, _, controller, recorder) = fixture(autoCompact: false)
        #expect(await controller.tick(now: now).isEmpty)
        #expect(recorder.sent.isEmpty)
    }

    @Test func aFailedSendIsNotRetriedEveryMinute() async {
        let (appState, session, controller, recorder) = fixture()
        recorder.failSend = true
        let outcomes = await controller.tick(now: now)
        #expect(outcomes.first?.sent == false)
        #expect(appState.hookState(for: session.id).crowCompactionRequestedAt == nil)
        recorder.failSend = false
        await controller.tick(now: now.addingTimeInterval(60))
        #expect(recorder.sent.isEmpty)
    }
}
