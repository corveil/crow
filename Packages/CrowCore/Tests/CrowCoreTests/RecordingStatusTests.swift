import Foundation
import Testing
@testable import CrowCore

/// CROW-1423: the pure rules behind the two recording-indicator glyphs.
@Suite struct RecordingStatusTests {
    static let devRoot = "/dev/root"
    static let now = Date(timeIntervalSince1970: 1_000_000)
    static let gw = WorkspaceGateway(baseURL: "https://corveil.io",
                                     customHeaders: ["x-citadel-api-key": "Bearer sk-citadel-secret"])

    static func config(upload: Bool = true, gateway: WorkspaceGateway? = gw, id: UUID = UUID()) -> AppConfig {
        AppConfig(workspaces: [WorkspaceInfo(id: id, name: "Corveil", uploadSessionLogs: upload, gateway: gateway)])
    }

    static func work(_ status: SessionStatus = .active) -> Session {
        Session(name: "w", status: status, kind: .work)
    }

    static func transcripts(
        _ session: Session, wt: String? = "/dev/root/corveil/crow-1-x", config: AppConfig? = config(),
        ledger: LogSyncLedger = LogSyncLedger(), notes: [LogSyncSkipNote] = []
    ) -> RecordingStatus.TranscriptIndicator {
        RecordingStatus.transcripts(session: session, worktreePath: wt, devRoot: devRoot, config: config,
                                    ledger: ledger, skipNotes: notes, now: now)
    }

    static func entry(_ status: LogSyncLedger.Status, reason: String? = nil, at: Double = 999_000) -> LogSyncLedger.Entry {
        .init(status: status, sha256: "x", sizeBytes: 2048, at: at, reason: reason)
    }

    // MARK: - Launch detection

    @Test func detectsClaudeLaunchLinePrefixWithoutReadingHeaders() {
        let line = "export ANTHROPIC_BASE_URL='https://corveil.io' ANTHROPIC_CUSTOM_HEADERS='x-citadel-api-key: Bearer sk-1' && claude --rc"
        let found = LaunchedGateway.detect(launchText: line)
        #expect(found?.baseURL == "https://corveil.io")
        #expect(found?.via == .launchLine)
    }

    @Test func detectsSetupShBarePrefix() {
        let line = "unset ANTHROPIC_CUSTOM_HEADERS && ANTHROPIC_BASE_URL='https://gw.acme.io' claude 'prompt'"
        #expect(LaunchedGateway.detect(launchText: line)?.baseURL == "https://gw.acme.io")
    }

    @Test func detectsExplicitClear() {
        let found = LaunchedGateway.detect(launchText: "unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS && claude")
        #expect(found?.via == LaunchedGateway.Via.none)
        #expect(found?.baseURL == nil)
    }

    @Test func detectsCodexOverride() {
        let line = "codex -c model_provider=crow-corveil -c model_providers.crow-corveil.base_url='https://corveil.io/v1' resume"
        let found = LaunchedGateway.detect(launchText: line)
        #expect(found?.baseURL == "https://corveil.io/v1")
        #expect(found?.via == .codexOverride)
    }

    @Test func ignoresLookalikeVariable() {
        #expect(LaunchedGateway.detect(launchText: "XANTHROPIC_BASE_URL=evil claude") == nil)
    }

    @Test func claudeFallsBackToSettingsEnvThenDirect() {
        let settings = Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://corveil.io","ANTHROPIC_CUSTOM_HEADERS":"x: y"}}"#.utf8)
        let viaSettings = LaunchedGateway.record(launchText: "claude --resume abc", agentKind: .claudeCode, settingsJSON: settings)
        #expect(viaSettings.via == .settingsEnv)
        #expect(viaSettings.baseURL == "https://corveil.io")
        let direct = LaunchedGateway.record(launchText: "claude", agentKind: .claudeCode, settingsJSON: nil)
        #expect(direct.via == LaunchedGateway.Via.none)
    }

    /// Claude Code applies its settings `env` over the inherited environment,
    /// so the settings value wins over whatever the launch line said.
    @Test func claudeSettingsEnvBeatsTheLaunchLine() {
        let settings = Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://corveil.io"}}"#.utf8)
        let overUnset = LaunchedGateway.record(
            launchText: "unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS && claude",
            agentKind: .claudeCode, settingsJSON: settings)
        #expect(overUnset.via == .settingsEnv)
        #expect(overUnset.baseURL == "https://corveil.io")
        let overOther = LaunchedGateway.record(
            launchText: "export ANTHROPIC_BASE_URL='https://other.example' && claude",
            agentKind: .claudeCode, settingsJSON: settings)
        #expect(overOther.baseURL == "https://corveil.io")
        // No settings value: the launch line decides.
        let lineOnly = LaunchedGateway.record(
            launchText: "export ANTHROPIC_BASE_URL='https://other.example' && claude",
            agentKind: .claudeCode, settingsJSON: Data(#"{"env":{}}"#.utf8))
        #expect(lineOnly.via == .launchLine)
        #expect(lineOnly.baseURL == "https://other.example")
        let cleared = LaunchedGateway.record(
            launchText: "unset ANTHROPIC_BASE_URL && claude", agentKind: .claudeCode, settingsJSON: nil)
        #expect(cleared.via == LaunchedGateway.Via.none)
    }

    /// A Codex override on a Claude line (or the reverse) is not that
    /// harness's route.
    @Test func eachHarnessReadsOnlyItsOwnRoute() {
        let codexLine = "codex -c model_providers.crow-corveil.base_url='https://corveil.io/v1'"
        #expect(LaunchedGateway.record(launchText: codexLine, agentKind: .claudeCode, settingsJSON: nil).via
            == LaunchedGateway.Via.none)
        #expect(LaunchedGateway.record(
            launchText: "ANTHROPIC_BASE_URL='https://corveil.io' codex", agentKind: .codex, settingsJSON: nil).via
            == LaunchedGateway.Via.none)
    }

    /// The record rides remote-readable RPCs: user info, query and fragment
    /// never survive, and something that isn't an http(s) URL isn't shown.
    @Test func recordedBaseURLIsReducedToSchemeHostPortPath() {
        #expect(LaunchedGateway.displayableBaseURL("https://user:pw@gw.example:8443/v1?key=sk-1#frag")
            == "https://gw.example:8443/v1")
        #expect(LaunchedGateway.displayableBaseURL("javascript:alert(1)") == nil)
        #expect(LaunchedGateway.displayableBaseURL("not a url") == nil)
        #expect(LaunchedGateway.displayableBaseURL("https://" + String(repeating: "a", count: 400) + ".io")?.count == 256)
        let settings = Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://u:secret@gw.example/?token=t"}}"#.utf8)
        let rec = LaunchedGateway.record(launchText: "claude", agentKind: .claudeCode, settingsJSON: settings)
        #expect(rec.baseURL == "https://gw.example/")
        #expect(rec.via == .settingsEnv)
        let junk = Data(#"{"env":{"ANTHROPIC_BASE_URL":"file:///etc/passwd"}}"#.utf8)
        let unknown = LaunchedGateway.record(launchText: "claude", agentKind: .claudeCode, settingsJSON: junk)
        #expect(unknown.baseURL == nil)
        #expect(unknown.via == .unknown)
    }

    @Test func ledgerIndexGroupsByUIDAndHarness() {
        var ledger = LogSyncLedger()
        let uid = UUID().uuidString
        ledger.record(key: LogSyncLedger.key(sessionUID: uid, harness: .codex, kind: .sessionTranscript),
                      entry: Self.entry(.uploaded))
        ledger.record(key: LogSyncLedger.key(sessionUID: uid, harness: .claude, kind: .sessionTranscript),
                      entry: Self.entry(.failedTransient))
        ledger.record(key: LogSyncLedger.key(sessionUID: "other", harness: .claude, kind: .sessionTranscript),
                      entry: Self.entry(.uploaded))
        let index = RecordingStatus.LedgerIndex(ledger)
        #expect(index.entries(uid: uid).map(\.harness) == [LogSyncHarness.claude.rawValue, LogSyncHarness.codex.rawValue])
        #expect(index.entries(uid: "missing").isEmpty)
    }

    @Test func otherHarnessesAreUnknownAndCodexWithoutOverrideIsDirect() {
        #expect(LaunchedGateway.record(launchText: "cursor-agent", agentKind: .cursor, settingsJSON: nil).via == .unknown)
        #expect(LaunchedGateway.record(launchText: "codex", agentKind: .codex, settingsJSON: nil).via == LaunchedGateway.Via.none)
    }

    @Test func sessionDecodesWithoutLaunchedGateway() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"s","status":"active","createdAt":0,"updatedAt":0}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(session.launchedGateway == nil)
    }

    // MARK: - Gateway indicator

    @Test func gatewayStates() {
        func state(_ launched: LaunchedGateway?, _ configured: String?, routable: Bool = true) -> RecordingStatus.GatewayState {
            RecordingStatus.gateway(launched: launched, configuredBaseURL: configured,
                                    harnessRoutable: routable, agentName: "Claude Code").state
        }
        let viaCorveil = LaunchedGateway(baseURL: "https://corveil.io/", via: .launchLine, agentKind: .claudeCode)
        let direct = LaunchedGateway(baseURL: nil, via: .none, agentKind: .claudeCode)
        #expect(state(viaCorveil, "https://CORVEIL.io") == .routed)
        #expect(state(viaCorveil, "https://other.example") == .drift)
        #expect(state(viaCorveil, nil) == .drift)
        #expect(state(direct, "https://corveil.io") == .drift)
        #expect(state(direct, nil) == .direct)
        #expect(state(nil, "https://corveil.io") == .unverified)
        #expect(state(nil, nil) == .off)
        #expect(state(nil, "https://corveil.io", routable: false) == .unsupported)
    }

    @Test func codexV1SuffixIsTheSameGateway() {
        #expect(RecordingStatus.sameGateway("https://corveil.io/v1", "https://corveil.io"))
        #expect(!RecordingStatus.sameGateway("https://corveil.io", "https://corveil.dev"))
    }

    // MARK: - Transcripts: opt-in

    @Test func primaryManagerNeverUploads() {
        let primary = Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)
        #expect(Self.transcripts(primary).state == .notOptedIn)
    }

    @Test func untaggedManagerIsNotOptedIn() {
        let m = Session(name: "m", kind: .manager)
        let r = Self.transcripts(m)
        #expect(r.state == .notOptedIn)
        #expect(r.detail.contains("untagged"))
    }

    @Test func workspaceUploadOffIsNotOptedIn() {
        let r = Self.transcripts(Self.work(), config: Self.config(upload: false))
        #expect(r.state == .notOptedIn)
        #expect(r.detail.contains("upload off"))
    }

    @Test func workspaceWithoutKeyHeaderIsNotOptedIn() {
        let noKey = WorkspaceGateway(baseURL: "https://corveil.io", customHeaders: ["x-other": "v"])
        #expect(Self.transcripts(Self.work(), config: Self.config(gateway: noKey)).state == .notOptedIn)
        #expect(Self.transcripts(Self.work(), config: Self.config(gateway: nil)).state == .notOptedIn)
    }

    @Test func reviewCloneIsNotMatchedToAWorkspace() {
        let r = Self.transcripts(Session(name: "r", kind: .review), wt: "/dev/root/crow-reviews/crow-pr-9")
        #expect(r.state == .notOptedIn)
        #expect(r.detail.contains("crow-reviews"))
    }

    @Test func workspaceFolderMatchesCaseInsensitively() {
        #expect(Self.transcripts(Self.work(), wt: "/dev/root/CORVEIL/x").state == .waiting)
    }

    @Test func detailNeverCarriesTheKey() {
        for s in [Self.work(), Session(name: "m", kind: .manager, workspaceID: UUID())] {
            #expect(!Self.transcripts(s).detail.contains("sk-citadel"))
        }
    }

    // MARK: - Transcripts: work sessions

    @Test func workSessionStates() {
        let s = Self.work()
        let uid = s.id.uuidString
        func ledger(_ e: LogSyncLedger.Entry, harness: String = "claude") -> LogSyncLedger {
            LogSyncLedger(entries: ["\(uid):\(harness):session_transcript": e])
        }
        #expect(Self.transcripts(s).state == .waiting)
        #expect(Self.transcripts(s, ledger: ledger(Self.entry(.uploaded))).state == .uploaded)
        #expect(Self.transcripts(s, ledger: ledger(Self.entry(.failedTransient, reason: "transient"))).state == .retrying)
        let rejected = Self.transcripts(s, ledger: ledger(Self.entry(.skippedPermanent, reason: "too_large")))
        #expect(rejected.state == .rejected)
        #expect(rejected.detail.contains("too_large"))
        let skipped = Self.transcripts(s, notes: [LogSyncSkipNote(reason: "no-transcript", detail: "no claude-code transcript under ~/.claude/projects/x")])
        #expect(skipped.state == .skipped)
        #expect(skipped.detail.contains("no claude-code transcript"))
    }

    @Test func anotherSessionsLedgerEntryDoesNotCount() {
        let other = LogSyncLedger(entries: ["\(UUID().uuidString):claude:session_transcript": Self.entry(.uploaded)])
        #expect(Self.transcripts(Self.work(), ledger: other).state == .waiting)
    }

    @Test func uploadedWhileOpenWarnsAboutWriteOnce() {
        let s = Self.work(.active)
        let l = LogSyncLedger(entries: ["\(s.id.uuidString):claude:session_transcript": Self.entry(.uploaded)])
        #expect(Self.transcripts(s, ledger: l).detail.contains("write-once"))
        let done = Self.work(.completed)
        let l2 = LogSyncLedger(entries: ["\(done.id.uuidString):claude:session_transcript": Self.entry(.uploaded)])
        #expect(!Self.transcripts(done, ledger: l2).detail.contains("write-once"))
    }

    @Test func completedWaitingSaysNextPass() {
        #expect(Self.transcripts(Self.work(.completed)).detail.contains("next collector pass"))
    }

    // MARK: - Transcripts: Managers

    @Test func managerCountsConversations() {
        let wsID = UUID()
        var m = Session(name: "m", kind: .manager, workspaceID: wsID)
        m.harnessConversationHistory = [
            HarnessConversationRef(agentKind: .claudeCode, id: "conv-a"),
            HarnessConversationRef(agentKind: .claudeCode, id: "conv-b"),
        ]
        m.harnessConversationID = "conv-c"  // current, not yet in the history
        let cfg = Self.config(id: wsID)
        let ledger = LogSyncLedger(entries: [
            "conv-a:claude:session_transcript": Self.entry(.uploaded),
            "conv-b:claude:session_transcript": Self.entry(.uploaded),
        ])
        let r = Self.transcripts(m, wt: nil, config: cfg, ledger: ledger)
        #expect(r.state == .waiting)
        #expect(r.uploaded == 2)
        #expect(r.total == 3)
        #expect(r.detail.hasPrefix("2 of 3 conversations uploaded"))

        var all = ledger
        all.record(key: "conv-c:claude:session_transcript", entry: Self.entry(.uploaded))
        #expect(Self.transcripts(m, wt: nil, config: cfg, ledger: all).state == .uploaded)

        var failing = ledger
        failing.record(key: "conv-c:claude:session_transcript", entry: Self.entry(.failedTransient))
        #expect(Self.transcripts(m, wt: nil, config: cfg, ledger: failing).state == .retrying)
    }

    /// The collector's Manager-wide skips (no agent terminal, no gateway key)
    /// carry no conversation scope; they still make the glyph `skipped` with
    /// the reason, not "waiting". A per-conversation skip does too.
    @Test func managerSkipNotesMakeTheGlyphSkipped() {
        let wsID = UUID()
        var m = Session(name: "m", kind: .manager, workspaceID: wsID)
        m.harnessConversationID = "conv-a"
        let cfg = Self.config(id: wsID)
        let noCwd = LogSyncSkipNote(reason: "no-cwd", detail: "Manager has no agent terminal")
        let wide = Self.transcripts(m, wt: nil, config: cfg, notes: [noCwd])
        #expect(wide.state == .skipped)
        #expect(wide.detail.contains("Manager has no agent terminal"))
        #expect(wide.uploaded == 0 && wide.total == 1)

        let scoped = LogSyncSkipNote(reason: "no-transcript", detail: "no transcript file", scope: "conv-a")
        let one = Self.transcripts(m, wt: nil, config: cfg, notes: [scoped])
        #expect(one.state == .skipped)
        #expect(one.detail.contains("conv-a: no transcript file"))

        // Already uploaded stays uploaded, whatever the collector says now.
        let ledger = LogSyncLedger(entries: ["conv-a:claude:session_transcript": Self.entry(.uploaded)])
        #expect(Self.transcripts(m, wt: nil, config: cfg, ledger: ledger, notes: [noCwd]).state == .uploaded)

        // No conversation yet, but the collector can't reach it anyway.
        var fresh = Session(name: "f", kind: .manager, workspaceID: wsID)
        fresh.harnessConversationID = nil
        #expect(Self.transcripts(fresh, wt: nil, config: cfg, notes: [noCwd]).state == .skipped)
    }

    @Test func managerWithNoConversationIsWaitingZeroOfZero() {
        let wsID = UUID()
        let m = Session(name: "m", kind: .manager, workspaceID: wsID)
        let r = Self.transcripts(m, wt: nil, config: Self.config(id: wsID))
        #expect(r.state == .waiting)
        #expect(r.total == 0)
    }

    @Test func managerWhoseWorkspaceWasRemovedIsNotOptedIn() {
        let m = Session(name: "m", kind: .manager, workspaceID: UUID())
        #expect(Self.transcripts(m, wt: nil).state == .notOptedIn)
    }

    // MARK: - Skip board

    @Test func skipBoardClearsAndDedupes() {
        let board = LogSyncSkipBoard()
        let id = UUID()
        let note = LogSyncSkipNote(reason: "no-transcript", detail: "d")
        board.record(id, note)
        board.record(id, note)
        #expect(board.notes(for: id) == [note])
        board.clear(id)
        #expect(board.notes(for: id).isEmpty)
    }
}

/// Debug mode gates the recording indicator; it must be off for every
/// existing config (no `debugMode` block) and tolerate a partial block.
@Suite struct DebugModeSettingsTests {
    @Test func offWhenAbsentAndTolerantOfPartialBlock() throws {
        let absent = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(absent.debugMode.enabled == false)
        let partial = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"debugMode":{}}"#.utf8))
        #expect(partial.debugMode.enabled == false)
        let on = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"debugMode":{"enabled":true}}"#.utf8))
        #expect(on.debugMode.enabled)
    }

    @Test func roundTrips() throws {
        var config = AppConfig()
        config.debugMode.enabled = true
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(back.debugMode.enabled)
    }
}
