import Foundation
import Testing
import CrowCore

@Suite struct AgentLogSourceTests {
    @Test func posixPathSlugReplacesNonAlphanumericWithDash() {
        // Verified rule: every non-[A-Za-z0-9] char → '-' (leading slash → '-').
        #expect(AgentLogSource.posixPathSlug("/Users/j/Dev2/RadiusMethod/crow-1056-x")
            == "-Users-j-Dev2-RadiusMethod-crow-1056-x")
    }

    @Test func posixPathSlugReplacesDotsAndUnderscores() {
        #expect(AgentLogSource.posixPathSlug("/a/head_lamp-0.39.0/b")
            == "-a-head-lamp-0-39-0-b")
    }

    @Test func posixPathSlugKeepsExistingHyphens() {
        #expect(AgentLogSource.posixPathSlug("already-hyphenated") == "already-hyphenated")
    }

    @Test func fileFactory() {
        let s = AgentLogSource.file("/tmp/x.jsonl", format: .jsonl)
        #expect(s.selector == .file)
        #expect(s.format == .jsonl)
        #expect(s.path == "/tmp/x.jsonl")
        #expect(s.fileExtension == nil)
    }

    @Test func directoryFactory() {
        let s = AgentLogSource.directory("/tmp/dir", format: .jsonl, fileExtension: "jsonl")
        #expect(s.selector == .directory)
        #expect(s.fileExtension == "jsonl")
        #expect(s.recursive == false)
        #expect(s.cwdFilter == nil)
    }

    @Test func directoryFactoryCarriesCwdFilterAndRecursion() {
        // The Codex shape: a recursive, cwd-filtered, prefix-scoped global store.
        let s = AgentLogSource.directory(
            "/home/.codex/sessions", format: .logDir, fileExtension: "jsonl",
            fileNamePrefix: "rollout-", recursive: true, cwdFilter: "/dev/ws/repo-1")
        #expect(s.selector == .directory)
        #expect(s.format == .logDir)
        #expect(s.fileNamePrefix == "rollout-")
        #expect(s.recursive == true)
        #expect(s.cwdFilter == "/dev/ws/repo-1")
    }
}

@Suite struct LogSyncHarnessTests {
    @Test func mapsKnownHarnesses() {
        #expect(LogSyncHarness(agentKind: .claudeCode) == .claude)
        #expect(LogSyncHarness(agentKind: .cursor) == .cursor)
        #expect(LogSyncHarness(agentKind: .codex) == .codex)
        #expect(LogSyncHarness(agentKind: .openCode) == .opencode)
        // Grok (CROW-1098) and Antigravity (CROW-1107) are internally first-class,
        // even though they collapse to `unknown` on the wire.
        #expect(LogSyncHarness(agentKind: .grok) == .grok)
        #expect(LogSyncHarness(agentKind: .antigravity) == .antigravity)
    }

    @Test func mapsEverythingElseToUnknown() {
        #expect(LogSyncHarness(agentKind: .muse) == .unknown)
    }

    @Test func rawValuesMatchServerContract() {
        // The server-enumerated harnesses: rawValue == wireValue (the DB CHECK on
        // crow_session_artifacts.harness).
        #expect(LogSyncHarness.claude.rawValue == "claude")
        #expect(LogSyncHarness.cursor.rawValue == "cursor")
        #expect(LogSyncHarness.codex.rawValue == "codex")
        #expect(LogSyncHarness.opencode.rawValue == "opencode")
        #expect(LogSyncHarness.unknown.rawValue == "unknown")
        #expect(LogSyncArtifactKind.sessionTranscript.rawValue == "session_transcript")
    }

    @Test func internalHarnessesCollapseToUnknownOnTheWire() {
        // Internally distinct (drives the ledger slot / backfill display /
        // format+agentKind), but the server doesn't enumerate `grok` or
        // `antigravity`, so the wire value is `unknown` — the upload is accepted,
        // just not harness-typed.
        #expect(LogSyncHarness.grok.rawValue == "grok")
        #expect(LogSyncHarness.grok.wireValue == "unknown")
        #expect(LogSyncHarness.antigravity.rawValue == "antigravity")
        #expect(LogSyncHarness.antigravity.wireValue == "unknown")
    }

    @Test func serverEnumeratedHarnessesWireAsThemselves() {
        for h in [LogSyncHarness.claude, .cursor, .codex, .opencode, .unknown] {
            #expect(h.wireValue == h.rawValue)
        }
    }
}
