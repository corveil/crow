import Foundation
import Testing
@testable import Crow

/// Resolution logic for where a job's repo lives on disk (CROW-327). A job's
/// `repo` is an `owner/repo` slug; the checkout is the slug's last component
/// under `{devRoot}/{workspace}/`. Legacy jobs store a bare repo name and a
/// blank workspace, which `runJob` instead resolves by folder name.
@Suite("Job repo resolution")
struct JobRepoResolutionTests {

    @Test func repoFolderTakesSlugLastComponent() {
        #expect(SessionService.jobRepoFolder(for: "radiusmethod/api") == "api")
    }

    @Test func repoFolderHandlesNestedGitLabGroups() {
        #expect(SessionService.jobRepoFolder(for: "group/sub/project") == "project")
    }

    @Test func repoFolderPassesBareNameThrough() {
        // Legacy bare-name jobs (no owner) keep their value verbatim.
        #expect(SessionService.jobRepoFolder(for: "api") == "api")
    }

    @Test func worktreeLayoutComposesWorkspaceScopedPath() {
        let layout = SessionService.jobWorktreeLayout(
            devRoot: "/dev", workspace: "RadiusMethod", repo: "radiusmethod/api"
        )
        #expect(layout.workspacePath == "/dev/RadiusMethod")
        #expect(layout.repoPath == "/dev/RadiusMethod/api")
        #expect(layout.repoFolder == "api")
    }

    @Test func worktreeLayoutUsesSlugLastComponentForNestedGroup() {
        let layout = SessionService.jobWorktreeLayout(
            devRoot: "/dev", workspace: "Corp", repo: "group/sub/project"
        )
        #expect(layout.repoPath == "/dev/Corp/project")
        #expect(layout.repoFolder == "project")
    }
}
