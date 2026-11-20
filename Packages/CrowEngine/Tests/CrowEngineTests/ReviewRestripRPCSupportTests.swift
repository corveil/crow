import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// Coverage for `ReviewRestripRPC`, the body of `crow review restrip`
/// (CROW-1492): which sessions and paths it acts on, what it removes, and
/// that it never follows a symlink out of the attacker-controlled clone.
@Suite("Review clone daemon re-strip (CROW-1492)")
struct ReviewRestripRPCSupportTests {

    // MARK: - Fixtures

    /// A dev root with a `crow-reviews/` folder and one `Corveil` workspace.
    /// Resolved with `realpath` so `/var` → `/private/var` can't confuse the
    /// path checks.
    private static func makeDevRoot() throws -> String {
        let raw = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-restrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (raw as NSString).appendingPathComponent(DevRootLayout.reviewsDirName),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: (raw as NSString).appendingPathComponent("Corveil"),
            withIntermediateDirectories: true)
        guard let resolved = realpath(raw, nil) else { return raw }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func makeClone(devRoot: String, name: String = "crow-pr-1") throws -> String {
        let clone = ((devRoot as NSString)
            .appendingPathComponent(DevRootLayout.reviewsDirName) as NSString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: clone, withIntermediateDirectories: true)
        return clone
    }

    /// Write every path in `ReviewCloneRestrip.paths` into `clone`, as a
    /// hostile PR head would after `gh pr checkout`.
    private static func populateHostileConfig(_ clone: String) throws {
        let fm = FileManager.default
        for relative in ReviewCloneRestrip.paths {
            let full = (clone as NSString).appendingPathComponent(relative)
            if relative.hasSuffix(".json") {
                try fm.createDirectory(
                    atPath: (full as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
                try #"{"hooks":{}}"#.write(toFile: full, atomically: true, encoding: .utf8)
            } else {
                try fm.createDirectory(atPath: full, withIntermediateDirectories: true)
                try "x".write(
                    toFile: (full as NSString).appendingPathComponent("hooks.json"),
                    atomically: true, encoding: .utf8)
            }
        }
    }

    private static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    private static func review(_ kind: SessionKind = .review) -> Session {
        Session(name: "review", kind: kind, agentKind: .claudeCode)
    }

    private static func worktree(_ session: Session, path: String) -> SessionWorktree {
        SessionWorktree(
            sessionID: session.id, repoName: "crow", repoPath: path,
            worktreePath: path, branch: "pr-1", isPrimary: true)
    }

    // MARK: - Which clone it acts on

    @Test func acceptsAReviewSessionsOwnCloneUnderCrowReviews() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let clone = try Self.makeClone(devRoot: devRoot)
        let session = Self.review()

        let path = try ReviewRestripRPC.clonePath(
            session: session, worktree: Self.worktree(session, path: clone), devRoot: devRoot)

        #expect(path == clone)
    }

    @Test func rejectsAnUnknownSession() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        #expect(throws: RPCError.self) {
            _ = try ReviewRestripRPC.clonePath(session: nil, worktree: nil, devRoot: devRoot)
        }
    }

    /// A work, job or Manager session's worktree is trusted code, not a review
    /// clone: Crow must never delete its committed `.claude/settings.json`.
    @Test(arguments: [SessionKind.work, .job, .manager])
    func rejectsEveryNonReviewSession(kind: SessionKind) throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let clone = try Self.makeClone(devRoot: devRoot)
        try Self.populateHostileConfig(clone)
        let session = Self.review(kind)

        #expect(throws: RPCError.self) {
            _ = try ReviewRestripRPC.clonePath(
                session: session, worktree: Self.worktree(session, path: clone), devRoot: devRoot)
        }
        #expect(Self.exists((clone as NSString).appendingPathComponent(".claude/settings.json")))
    }

    @Test func rejectsAReviewSessionWithNoClone() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        #expect(throws: RPCError.self) {
            _ = try ReviewRestripRPC.clonePath(session: Self.review(), worktree: nil, devRoot: devRoot)
        }
    }

    /// A review row whose path is a workspace worktree, the dev root, outside
    /// the dev root, nested too deep, or climbs out with `..`, is refused.
    @Test func rejectsPathsThatAreNotAReviewClone() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let workspaceWorktree = (devRoot as NSString).appendingPathComponent("Corveil/crow-1-x")
        try FileManager.default.createDirectory(atPath: workspaceWorktree, withIntermediateDirectories: true)
        let nested = (devRoot as NSString)
            .appendingPathComponent("\(DevRootLayout.reviewsDirName)/crow-pr-1/sub")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let outside = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-restrip-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        let session = Self.review()

        for path in [
            workspaceWorktree,
            devRoot,
            (devRoot as NSString).appendingPathComponent(DevRootLayout.reviewsDirName),
            nested,
            outside,
            devRoot + "/\(DevRootLayout.reviewsDirName)/../Corveil/crow-1-x",
            "relative/crow-pr-1",
        ] {
            #expect(throws: RPCError.self, "\(path) must be refused") {
                _ = try ReviewRestripRPC.clonePath(
                    session: session, worktree: Self.worktree(session, path: path), devRoot: devRoot)
            }
        }
    }

    /// `crow-reviews/evil` → a workspace worktree resolves outside
    /// `crow-reviews/`, and a symlink to another review clone is still refused
    /// because the clone directory itself must not be a symlink.
    @Test func rejectsASymlinkedCloneDirectory() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let realClone = try Self.makeClone(devRoot: devRoot, name: "crow-pr-2")
        let workspaceWorktree = (devRoot as NSString).appendingPathComponent("Corveil/crow-1-x")
        try FileManager.default.createDirectory(atPath: workspaceWorktree, withIntermediateDirectories: true)
        let reviews = (devRoot as NSString).appendingPathComponent(DevRootLayout.reviewsDirName)
        let toWorkspace = (reviews as NSString).appendingPathComponent("crow-pr-3")
        let toClone = (reviews as NSString).appendingPathComponent("crow-pr-4")
        try FileManager.default.createSymbolicLink(atPath: toWorkspace, withDestinationPath: workspaceWorktree)
        try FileManager.default.createSymbolicLink(atPath: toClone, withDestinationPath: realClone)
        let session = Self.review()

        for path in [toWorkspace, toClone] {
            #expect(throws: RPCError.self, "\(path) must be refused") {
                _ = try ReviewRestripRPC.clonePath(
                    session: session, worktree: Self.worktree(session, path: path), devRoot: devRoot)
            }
        }
    }

    @Test func rejectsAMissingClone() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let missing = (devRoot as NSString)
            .appendingPathComponent("\(DevRootLayout.reviewsDirName)/crow-pr-9")
        let session = Self.review()
        #expect(throws: RPCError.self) {
            _ = try ReviewRestripRPC.clonePath(
                session: session, worktree: Self.worktree(session, path: missing), devRoot: devRoot)
        }
    }

    // MARK: - What it removes

    /// The ticket's acceptance case: `.claude/settings.json` (and the rest of
    /// the union) is gone from the working tree, while `.claude/skills/` and
    /// ordinary source survive.
    @Test func removesEveryRestoredLayerAndKeepsTheRest() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let clone = try Self.makeClone(devRoot: devRoot)
        try Self.populateHostileConfig(clone)
        let skill = (clone as NSString).appendingPathComponent(".claude/skills/crow-review-pr/SKILL.md")
        try FileManager.default.createDirectory(
            atPath: (skill as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "skill".write(toFile: skill, atomically: true, encoding: .utf8)
        let source = (clone as NSString).appendingPathComponent("main.swift")
        try "print(1)".write(toFile: source, atomically: true, encoding: .utf8)

        let report = ReviewRestripRPC.restrip(clonePath: clone)

        #expect(report.isComplete)
        #expect(Set(report.removed) == Set(ReviewCloneRestrip.paths))
        for relative in ReviewCloneRestrip.paths {
            #expect(!Self.exists((clone as NSString).appendingPathComponent(relative)), "\(relative) survived")
        }
        #expect(Self.exists(skill))
        #expect(Self.exists(source))
    }

    @Test func isIdempotent() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let clone = try Self.makeClone(devRoot: devRoot)
        try Self.populateHostileConfig(clone)

        _ = ReviewRestripRPC.restrip(clonePath: clone)
        let second = ReviewRestripRPC.restrip(clonePath: clone)

        #expect(second.isComplete)
        #expect(second.removed.isEmpty)
    }

    /// A committed `.claude -> <outside dir>` must not turn the daemon, which
    /// has no sandbox, into a tool for deleting the operator's own settings.
    /// The target survives, and the strip reports itself incomplete so the
    /// skill stops the review.
    @Test func neverFollowsASymlinkedClaudeDirOutOfTheClone() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let clone = try Self.makeClone(devRoot: devRoot)
        let victim = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-restrip-victim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: victim, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: victim) }
        let victimSettings = (victim as NSString).appendingPathComponent("settings.json")
        try "{}".write(toFile: victimSettings, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: (clone as NSString).appendingPathComponent(".claude"), withDestinationPath: victim)

        let report = ReviewRestripRPC.restrip(clonePath: clone)

        #expect(Self.exists(victimSettings), "the daemon followed .claude out of the clone")
        #expect(!report.isComplete)
        #expect(report.remaining.map(\.path).contains(".claude/settings.json"))
        #expect(ReviewRestripRPC.incompleteMessage(report).contains("stop the review"))
    }

    /// A symlinked leaf is removed as a link; its target is untouched.
    @Test func removesASymlinkedLeafWithoutTouchingItsTarget() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let clone = try Self.makeClone(devRoot: devRoot)
        let victim = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-restrip-leaf-\(UUID().uuidString).json")
        try "{}".write(toFile: victim, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: victim) }
        let claudeDir = (clone as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let link = (claudeDir as NSString).appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: victim)
        // A dangling link counts as present too.
        let dangling = (clone as NSString).appendingPathComponent(".mcp.json")
        try FileManager.default.createSymbolicLink(atPath: dangling, withDestinationPath: "/nonexistent-crow-1492")

        let report = ReviewRestripRPC.restrip(clonePath: clone)

        #expect(report.isComplete)
        #expect(Set(report.removed) == [".claude/settings.json", ".mcp.json"])
        #expect(!Self.exists(link))
        #expect(!Self.exists(dangling))
        #expect(Self.exists(victim))
    }

    /// A `.claude` that is a plain file (not a folder) can't hold the settings
    /// files; it is reported rather than silently treated as clean.
    @Test func reportsANonDirectoryClaudeParent() throws {
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let clone = try Self.makeClone(devRoot: devRoot)
        try "not a dir".write(
            toFile: (clone as NSString).appendingPathComponent(".claude"), atomically: true, encoding: .utf8)

        let report = ReviewRestripRPC.restrip(clonePath: clone)

        #expect(!report.isComplete)
        #expect(Set(report.remaining.map(\.path)) == [".claude/settings.json", ".claude/settings.local.json"])
    }

    // MARK: - One list

    /// Config-looking paths that are not in the list. A per-agent strip that
    /// starts removing one of these has grown a layer the daemon re-strip
    /// lacks.
    private static let decoys = [
        ".claude/skills/x.md", ".claude/commands/x.md", ".claude/agents/x.md",
        ".claude/hooks/x.sh", ".github/workflows/ci.yml", ".vscode/settings.json",
        ".windsurf/rules.md", ".continue/config.json", ".opencode/config.json",
        ".crush/config.json", ".zed/settings.json", "AGENTS.md", "CLAUDE.md",
        "GEMINI.md", ".cursorrules", "opencode.json",
    ]

    /// `ReviewCloneRestrip.paths` is the union of the per-agent launch-path
    /// strips. If a strip gains a layer the list lacks (or the reverse), the
    /// daemon re-strip and the launch strip disagree about what is hostile.
    @Test func pathListIsTheUnionOfThePerAgentStrips() throws {
        let strips: [(String) -> Void] = [
            { SessionService.stripCursorConfigFromReviewClone(clonePath: $0) },
            { SessionService.stripGrokConfigFromReviewClone(clonePath: $0) },
            { SessionService.stripAntigravityConfigFromReviewClone(clonePath: $0) },
            { SessionService.stripMuseConfigFromReviewClone(clonePath: $0) },
            { SessionService.stripCodexConfigFromReviewClone(clonePath: $0) },
        ]
        let devRoot = try Self.makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var removedByStrips = Set<String>()
        for (index, strip) in strips.enumerated() {
            let clone = try Self.makeClone(devRoot: devRoot, name: "crow-pr-strip-\(index)")
            try Self.populateHostileConfig(clone)
            for decoy in Self.decoys {
                let full = (clone as NSString).appendingPathComponent(decoy)
                try FileManager.default.createDirectory(
                    atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try "x".write(toFile: full, atomically: true, encoding: .utf8)
            }
            strip(clone)
            for relative in ReviewCloneRestrip.paths + Self.decoys
            where !Self.exists((clone as NSString).appendingPathComponent(relative)) {
                removedByStrips.insert(relative)
            }
        }
        #expect(removedByStrips == Set(ReviewCloneRestrip.paths))
    }
}
