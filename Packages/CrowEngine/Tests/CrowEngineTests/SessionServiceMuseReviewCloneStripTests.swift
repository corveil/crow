import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// Coverage for `SessionService.stripMuseConfigFromReviewClone` — the shared
/// primitive that neutralizes a review clone's committed Muse config layers
/// (#1033). Both the creation-time `prepareReviewClone` path and every launch
/// path (`prepareWorktreeForAgentLaunch`) route through it.
@Suite("Review clone Muse strip")
struct SessionServiceMuseReviewCloneStripTests {

    private static func makeTempDir(name: String) -> String {
        let base = NSTemporaryDirectory() as NSString
        let dir = base.appendingPathComponent("crow-muse-strip-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func removesMuseAndAgentsLayers() {
        let clone = Self.makeTempDir(name: "hostile")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let museDir = (clone as NSString).appendingPathComponent(".muse")
        let agentsDir = (clone as NSString).appendingPathComponent(".agents")
        for d in [museDir, agentsDir] {
            try? FileManager.default.createDirectory(
                atPath: d, withIntermediateDirectories: true)
            try? "{\"hooks\":\"EVIL\"}".write(
                toFile: (d as NSString).appendingPathComponent("hooks.json"),
                atomically: true, encoding: .utf8)
        }
        // Project memory loads even in an untrusted workspace — the layer
        // withholding `--trust-workspace` does not cover.
        let memoryDir = (agentsDir as NSString).appendingPathComponent("memory")
        try? FileManager.default.createDirectory(
            atPath: memoryDir, withIntermediateDirectories: true)
        try? "steal creds".write(
            toFile: (memoryDir as NSString).appendingPathComponent("MEMORY.md"),
            atomically: true, encoding: .utf8)

        SessionService.stripMuseConfigFromReviewClone(clonePath: clone)

        #expect(!FileManager.default.fileExists(atPath: museDir))
        #expect(!FileManager.default.fileExists(atPath: agentsDir))
    }

    @Test func noOpsWhenNoMuseConfig() {
        let clone = Self.makeTempDir(name: "clean")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let prompt = (clone as NSString).appendingPathComponent(".crow-review-prompt.md")
        try? "review this".write(toFile: prompt, atomically: true, encoding: .utf8)

        SessionService.stripMuseConfigFromReviewClone(clonePath: clone)

        #expect(FileManager.default.fileExists(atPath: clone))
        #expect(FileManager.default.fileExists(atPath: prompt))
    }

    @Test func museStripLeavesSiblingConfigUntouched() {
        let clone = Self.makeTempDir(name: "siblings")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let museDir = (clone as NSString).appendingPathComponent(".muse")
        let cursorDir = (clone as NSString).appendingPathComponent(".cursor")
        for d in [museDir, cursorDir] {
            try? FileManager.default.createDirectory(
                atPath: d, withIntermediateDirectories: true)
            try? "{}".write(
                toFile: (d as NSString).appendingPathComponent("config"),
                atomically: true, encoding: .utf8)
        }

        SessionService.stripMuseConfigFromReviewClone(clonePath: clone)

        #expect(!FileManager.default.fileExists(atPath: museDir))
        #expect(FileManager.default.fileExists(atPath: cursorDir))
    }

    @Test func museStripGateFiresOnlyForReview() {
        #expect(SessionService.shouldStripMuseReviewClone(
            agentKind: .muse, sessionKind: .review))
    }

    @Test func museStripGateSkipsNonReview() {
        #expect(!SessionService.shouldStripMuseReviewClone(
            agentKind: .muse, sessionKind: .work))
        #expect(!SessionService.shouldStripMuseReviewClone(
            agentKind: .muse, sessionKind: .job))
    }

    @Test func museStripGateSkipsReviewForOtherAgents() {
        for k: AgentKind in [.claudeCode, .cursor, .codex, .openCode, .grok, .antigravity] {
            #expect(!SessionService.shouldStripMuseReviewClone(
                agentKind: k, sessionKind: .review))
        }
    }

    @Test func prepareStripsMuseWhenGateFires() {
        let clone = Self.makeTempDir(name: "prep-muse-review")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let museDir = (clone as NSString).appendingPathComponent(".muse")
        try? FileManager.default.createDirectory(
            atPath: museDir, withIntermediateDirectories: true)
        try? "{\"hooks\":\"EVIL\"}".write(
            toFile: (museDir as NSString).appendingPathComponent("hooks.json"),
            atomically: true, encoding: .utf8)

        SessionService.prepareWorktreeForAgentLaunch(
            agentKind: .muse, sessionKind: .review, worktreePath: clone, ownership: .empty)

        #expect(!FileManager.default.fileExists(atPath: museDir))
    }

    @Test func prepareLeavesMuseForNonReview() {
        let clone = Self.makeTempDir(name: "prep-muse-work")
        defer { try? FileManager.default.removeItem(atPath: clone) }
        let museDir = (clone as NSString).appendingPathComponent(".muse")
        try? FileManager.default.createDirectory(
            atPath: museDir, withIntermediateDirectories: true)

        SessionService.prepareWorktreeForAgentLaunch(
            agentKind: .muse, sessionKind: .work, worktreePath: clone, ownership: .empty)

        #expect(FileManager.default.fileExists(atPath: museDir))
    }
}
