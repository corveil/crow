import Foundation
import Testing
import ArgumentParser
@testable import CrowCLILib

// MARK: - `crow defaults` parsing (CROW-810)
//
// `validate()` runs during `parse`, so every rejection below surfaces here
// without a socket.

private func defaultsSetParseError(_ args: [String]) -> String {
    do {
        _ = try DefaultsSet.parse(args)
        return ""
    } catch {
        return String(describing: error)
    }
}

// MARK: - Scalars

@Test func defaultsSetParsesScalars() throws {
    let cmd = try DefaultsSet.parse([
        "--provider", "gitlab",
        "--cli", "glab",
        "--branch-prefix", "feat/",
    ])
    #expect(cmd.provider == "gitlab")
    #expect(cmd.cli == "glab")
    #expect(cmd.branchPrefix == "feat/")
}

@Test func defaultsSetOmittedFlagsAreNilOrEmpty() throws {
    let cmd = try DefaultsSet.parse(["--provider", "github"])
    #expect(cmd.cli == nil)
    #expect(cmd.branchPrefix == nil)
    #expect(cmd.binary.isEmpty)
    #expect(cmd.addExcludeReviewRepo.isEmpty)
    #expect(cmd.clearExcludeReviewRepos == false)
}

@Test func defaultsSetRequiresAtLeastOneField() {
    #expect(throws: (any Error).self) { _ = try DefaultsSet.parse([]) }
    #expect(defaultsSetParseError([]).contains("Nothing to set"))
}

/// `GitManager` compares the stored provider with `==`, so an accepted casing
/// variant would silently fall through to the wrong forge branch.
@Test func defaultsSetRejectsUnknownProviderAndCLI() {
    for bad in ["bitbucket", "GitHub", "gitea", ""] {
        #expect(throws: (any Error).self, "expected provider '\(bad)' to be rejected") {
            _ = try DefaultsSet.parse(["--provider", bad])
        }
    }
    for bad in ["hub", "GH", "git", ""] {
        #expect(throws: (any Error).self, "expected cli '\(bad)' to be rejected") {
            _ = try DefaultsSet.parse(["--cli", bad])
        }
    }
}

/// Delegates to `ConfigDefaults.isValidBranchPrefix`, so a prefix git would
/// refuse fails at the flag rather than at `git worktree add` much later.
@Test func defaultsSetRejectsInvalidBranchPrefix() {
    for bad in ["bad..prefix", "has space/", "tilde~/", "trailing.", "at@{x}/", "star*/"] {
        #expect(throws: (any Error).self, "expected prefix '\(bad)' to be rejected") {
            _ = try DefaultsSet.parse(["--branch-prefix", bad])
        }
    }
}

/// Empty is legal in the model and means "no prefix" — it must not be mistaken
/// for "flag not provided".
@Test func defaultsSetAcceptsEmptyBranchPrefix() throws {
    #expect(try DefaultsSet.parse(["--branch-prefix", ""]).branchPrefix == "")
}

// MARK: - Lists

@Test func defaultsSetAccumulatesRepeatableListFlags() throws {
    let cmd = try DefaultsSet.parse([
        "--add-exclude-review-repo", "acme/docs",
        "--add-exclude-review-repo", "acme/api",
        "--remove-ignore-review-label", "wip",
    ])
    #expect(cmd.addExcludeReviewRepo == ["acme/docs", "acme/api"])
    #expect(cmd.removeIgnoreReviewLabel == ["wip"])
    #expect(cmd.addIgnoreReviewLabel.isEmpty)
}

@Test func defaultsSetParsesEachListsClearFlag() throws {
    #expect(try DefaultsSet.parse(["--clear-exclude-review-repos"]).clearExcludeReviewRepos)
    #expect(try DefaultsSet.parse(["--clear-exclude-ticket-repos"]).clearExcludeTicketRepos)
    #expect(try DefaultsSet.parse(["--clear-ignore-review-labels"]).clearIgnoreReviewLabels)
}

@Test func defaultsSetRejectsClearCombinedWithAddOrRemoveOnTheSameList() {
    let cases = [
        ["--clear-exclude-review-repos", "--add-exclude-review-repo", "acme/docs"],
        ["--clear-exclude-review-repos", "--remove-exclude-review-repo", "acme/docs"],
        ["--clear-ignore-review-labels", "--add-ignore-review-label", "wip"],
    ]
    for args in cases {
        #expect(throws: (any Error).self, "expected \(args) to be rejected") {
            _ = try DefaultsSet.parse(args)
        }
    }
    #expect(defaultsSetParseError(cases[0]).contains("--clear-exclude-review-repos"))
}

/// Per list, not globally: clearing one list while editing another is a single
/// legitimate call.
@Test func defaultsSetAllowsClearingOneListWhileEditingAnother() throws {
    let cmd = try DefaultsSet.parse([
        "--clear-exclude-ticket-repos",
        "--add-ignore-review-label", "wip",
    ])
    #expect(cmd.clearExcludeTicketRepos)
    #expect(cmd.addIgnoreReviewLabel == ["wip"])
}

/// A flag passed with only whitespace is a typo; sending it would be an inert
/// write reported as a success.
@Test func defaultsSetRejectsBlankOnlyListValues() {
    #expect(throws: (any Error).self) {
        _ = try DefaultsSet.parse(["--add-exclude-review-repo", "   "])
    }
}

// MARK: - --binary

@Test func defaultsSetParsesBinaryOverrides() throws {
    let cmd = try DefaultsSet.parse([
        "--binary", "corveil=/opt/corveil/bin/corveil",
        "--binary", "codex=",
    ])
    #expect(cmd.binary == ["corveil=/opt/corveil/bin/corveil", "codex="])
    #expect(try parseBinaryOverrides(cmd.binary)
        == ["corveil": "/opt/corveil/bin/corveil", "codex": ""])
}

/// Split on the FIRST `=` only, so a path may legitimately contain one.
@Test func parseBinaryOverridesSplitsOnFirstEqualsOnly() throws {
    #expect(try parseBinaryOverrides(["codex=/opt/codex=v2/bin/codex"])
        == ["codex": "/opt/codex=v2/bin/codex"])
}

@Test func parseBinaryOverridesRejectsMissingSeparator() {
    for bad in ["corveil", "/opt/corveil/bin/corveil", ""] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            _ = try parseBinaryOverrides([bad])
        }
    }
}

/// A blank or path-like key is a real hazard, not a tidiness rule: `Scaffolder`
/// resolves it under `.claude/bin` with `appendingPathComponent` and then
/// `removeItem`s the result, so `""` targets the bin directory itself.
@Test func parseBinaryOverridesRejectsBlankAndPathLikeNames() {
    for bad in ["=/usr/bin/true", "   =/usr/bin/true", "bin/corveil=/usr/bin/true",
                "../escape=/usr/bin/true", ".=/usr/bin/true", "a\\b=/usr/bin/true"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            _ = try parseBinaryOverrides([bad])
        }
    }
}

/// `crow` is owned by `Scaffolder`, which re-points it at the running app's own
/// CLI every launch — an override there can never take effect.
@Test func parseBinaryOverridesRejectsTheReservedCrowName() {
    #expect(throws: (any Error).self) {
        _ = try parseBinaryOverrides(["crow=/usr/local/bin/crow"])
    }
    #expect(throws: (any Error).self) { _ = try parseBinaryOverrides(["crow="]) }
}

/// Two values for one tool are contradictory; resolving last-wins would silently
/// discard one.
@Test func parseBinaryOverridesRejectsDuplicateNames() {
    #expect(throws: (any Error).self) {
        _ = try parseBinaryOverrides(["corveil=/a/corveil", "corveil=/b/corveil"])
    }
    #expect(throws: (any Error).self) {
        _ = try parseBinaryOverrides(["corveil=/a/corveil", "corveil="])
    }
}

/// The daemon probes the target with `isExecutableFile(atPath:)`, which resolves
/// a relative path against *its* cwd and does no tilde expansion — so `~` is
/// expanded here and relative paths are refused outright.
@Test func parseBinaryOverridesExpandsTildeAndRejectsRelativePaths() throws {
    let expanded = try parseBinaryOverrides(["corveil=~/bin/corveil"])["corveil"]
    #expect(expanded?.hasPrefix("/") == true)
    #expect(expanded?.hasSuffix("/bin/corveil") == true)
    #expect(expanded?.contains("~") == false)

    for bad in ["corveil=bin/corveil", "corveil=./corveil", "corveil=../corveil"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            _ = try parseBinaryOverrides([bad])
        }
    }
}

/// A blank path is the documented way to remove an entry — it must survive the
/// absolute-path check.
@Test func parseBinaryOverridesAcceptsBlankPathAsRemoval() throws {
    #expect(try parseBinaryOverrides(["corveil="]) == ["corveil": ""])
    #expect(try parseBinaryOverrides(["corveil=   "]) == ["corveil": ""])
}

// MARK: - Group

@Test func defaultsGetTakesNoArguments() throws {
    _ = try DefaultsGet.parse([])
}

@Test func defaultsGroupRoutesToSubcommands() throws {
    #expect(try Defaults.parseAsRoot(["get"]) is DefaultsGet)
    #expect(try Defaults.parseAsRoot(["set", "--provider", "github"]) is DefaultsSet)
}

@Test func defaultsGroupRejectsUnknownSubcommands() {
    #expect(throws: (any Error).self) { _ = try Defaults.parseAsRoot(["list"]) }
    #expect(throws: (any Error).self) { _ = try Defaults.parseAsRoot(["reset"]) }
}
