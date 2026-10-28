import Foundation
import Testing

@testable import CrowCore

/// `WorktreePathPolicy` (CROW-1396): the one placement rule `add-worktree` and
/// `setup.sh` both enforce before a worktree is created.
@Suite struct WorktreePathPolicyTests {
    private static let workspaces = ["Corveil", "personal"]

    /// A real directory, so symlink resolution is exercised the way it runs in
    /// production (`/var` → `/private/var` on macOS).
    private func makeDevRoot() throws -> String {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-1396-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func validate(_ path: String, _ root: String) -> Result<WorktreePathPolicy.Placement, WorktreePathPolicy.Rejection> {
        WorktreePathPolicy.validate(path, devRoot: root, workspaceNames: Self.workspaces)
    }

    @Test func acceptsWorkspaceFolderAndReportsConfiguredName() throws {
        let root = try makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try validate("\(root)/Corveil/crow-1-x", root).get() == .workspace("Corveil"))
        #expect(try validate("\(root)/corveil/crow-1-x", root).get() == .workspace("Corveil"))
        #expect(try validate("\(root)/PERSONAL/x/", root).get() == .workspace("personal"))
    }

    @Test func acceptsReviewClone() throws {
        let root = try makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try validate("\(root)/crow-reviews/crow-pr-12", root).get() == .reviews)
    }

    /// `..` inside the tail collapses before the shape check: this lands back
    /// on `{root}/Corveil/x`.
    @Test func acceptsDotDotThatStaysInsideAWorkspace() throws {
        let root = try makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try validate("\(root)/personal/../Corveil/x", root).get() == .workspace("Corveil"))
    }

    /// A workspace folder reached through a symlink resolves to where it
    /// really is — outside the dev root here.
    @Test func resolvesSymlinkedWorkspaceFolder() throws {
        let root = try makeDevRoot()
        let elsewhere = try makeDevRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: elsewhere)
        }
        try FileManager.default.createSymbolicLink(
            atPath: "\(root)/Corveil", withDestinationPath: elsewhere)
        #expect(throws: WorktreePathPolicy.Rejection.self) { try validate("\(root)/Corveil/x", root).get() }
    }

    /// A dev root given through a symlink still accepts its own children.
    @Test func acceptsDevRootGivenThroughSymlink() throws {
        let real = try makeDevRoot()
        let link = real + "-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        defer {
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.removeItem(atPath: real)
        }
        #expect(try validate("\(real)/Corveil/x", link).get() == .workspace("Corveil"))
        #expect(try validate("\(link)/Corveil/x", real).get() == .workspace("Corveil"))
    }

    @Test(arguments: [
        ("/corveil-3004-dock-greeting", "directly in the dev root"),
        ("/Corveil/worktrees/x", "too deep"),
        ("/Corveil", "the 'Corveil' folder itself"),
        ("/bmlt-enabled/x", "'bmlt-enabled' is not a configured workspace"),
        ("/crow-reviews/a/b", "too deep"),
        ("", "the dev root itself"),
        ("/Corveil/../../escape", "outside the dev root"),
    ])
    func rejects(suffix: String, reason: String) throws {
        let root = try makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard case .failure(let rejection) = validate(root + suffix, root) else {
            Issue.record("expected \(suffix) to be rejected")
            return
        }
        #expect(rejection.reason.contains(reason), "\(rejection.reason)")
    }

    @Test func rejectsPathOutsideDevRoot() throws {
        let root = try makeDevRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard case .failure(let rejection) = validate("/opt/elsewhere/x", root) else {
            Issue.record("expected rejection")
            return
        }
        #expect(rejection.reason == "it is outside the dev root")
    }

    @Test func rejectsRelativePath() {
        guard case .failure(let rejection) = validate("Corveil/x", "/crow-1396-nonexistent/root") else {
            Issue.record("expected rejection")
            return
        }
        #expect(rejection.reason == "it is not an absolute path")
    }

    /// The error names the path, the expected form, the configured workspaces
    /// and the fix.
    @Test func messageCarriesEverythingNeededToFixIt() {
        guard case .failure(let rejection) = validate("/crow-1396-nonexistent/root/bmlt-enabled/x", "/crow-1396-nonexistent/root") else {
            Issue.record("expected rejection")
            return
        }
        #expect(rejection.message.contains("'/crow-1396-nonexistent/root/bmlt-enabled/x'"))
        #expect(rejection.message.contains("/crow-1396-nonexistent/root/{workspace}/{dir}"))
        #expect(rejection.message.contains("/crow-1396-nonexistent/root/crow-reviews/{dir}"))
        #expect(rejection.message.contains("Configured workspaces: Corveil, personal"))
        #expect(rejection.message.contains("crow workspace add"))
    }

    @Test func messageSaysWhenNoWorkspaceIsConfigured() {
        guard case .failure(let rejection) = WorktreePathPolicy.validate(
            "/crow-1396-nonexistent/root/x/y", devRoot: "/crow-1396-nonexistent/root", workspaceNames: []) else {
            Issue.record("expected rejection")
            return
        }
        #expect(rejection.message.contains("(none configured)"))
    }
}
