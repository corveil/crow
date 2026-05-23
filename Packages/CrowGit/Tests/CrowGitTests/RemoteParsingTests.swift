import Testing
@testable import CrowGit

/// Unit tests for the `origin`-remote normalization that backs both the
/// `org/repo` summary scope and the clickable-commit URLs.
@Suite("GitManager remote parsing")
struct RemoteParsingTests {

    @Test func sshGitHub() {
        let url = "git@github.com:radiusmethod/crow.git"
        #expect(GitManager.host(fromRemote: url) == "github.com")
        #expect(GitManager.slug(fromRemote: url) == "radiusmethod/crow")
    }

    @Test func httpsGitHubWithDotGit() {
        let url = "https://github.com/radiusmethod/crow.git"
        #expect(GitManager.host(fromRemote: url) == "github.com")
        #expect(GitManager.slug(fromRemote: url) == "radiusmethod/crow")
    }

    @Test func httpsGitHubNoDotGit() {
        let url = "https://github.com/acme/api"
        #expect(GitManager.host(fromRemote: url) == "github.com")
        #expect(GitManager.slug(fromRemote: url) == "acme/api")
    }

    @Test func sshGitLabNestedGroup() {
        let url = "git@gitlab.com:group/sub/repo.git"
        #expect(GitManager.host(fromRemote: url) == "gitlab.com")
        #expect(GitManager.slug(fromRemote: url) == "group/sub/repo")
    }

    @Test func selfHostedGitLab() {
        let url = "https://gitlab.example.com/team/proj.git"
        #expect(GitManager.host(fromRemote: url) == "gitlab.example.com")
        #expect(GitManager.slug(fromRemote: url) == "team/proj")
    }

    @Test func unparseableRemote() {
        #expect(GitManager.host(fromRemote: "not a url") == "")
        #expect(GitManager.slug(fromRemote: "not a url") == "")
    }

    @Test func gitHubCommitPrefix() {
        #expect(
            GitManager.commitURLPrefix(host: "github.com", slug: "radiusmethod/crow")
                == "https://github.com/radiusmethod/crow/commit/"
        )
    }

    @Test func gitLabCommitPrefixUsesDashCommit() {
        #expect(
            GitManager.commitURLPrefix(host: "gitlab.com", slug: "group/sub/repo")
                == "https://gitlab.com/group/sub/repo/-/commit/"
        )
        #expect(
            GitManager.commitURLPrefix(host: "gitlab.example.com", slug: "team/proj")
                == "https://gitlab.example.com/team/proj/-/commit/"
        )
    }
}
