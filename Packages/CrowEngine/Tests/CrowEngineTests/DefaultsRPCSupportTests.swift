import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// Param decoding and response encoding for the `defaults-*` RPC handlers
/// behind `crow defaults` (CROW-810).
@Suite("Defaults RPC support")
struct DefaultsRPCSupportTests {

    // MARK: - Scalar patches

    @Test func patchProviderAcceptsOnlyKnownForges() throws {
        #expect(try DefaultsRPC.patchProvider(["provider": .string("github")]) == "github")
        #expect(try DefaultsRPC.patchProvider(["provider": .string("gitlab")]) == "gitlab")
        #expect(try DefaultsRPC.patchProvider([:]) == nil)
        #expect(try DefaultsRPC.patchProvider(["provider": .null]) == nil)

        // "GitHub" is rejected rather than canonicalized: `GitManager` compares
        // the stored value with `==`, so a silently-accepted casing variant would
        // fall through to the gitlab branch.
        for value: JSONValue in [.string("GitHub"), .string("bitbucket"), .string(""), .int(1), .bool(true)] {
            #expect(throws: RPCError.self, "expected \(value) to be rejected") {
                _ = try DefaultsRPC.patchProvider(["provider": value])
            }
        }
    }

    @Test func patchCLIAcceptsOnlyKnownForgeCLIs() throws {
        #expect(try DefaultsRPC.patchCLI(["cli": .string("gh")]) == "gh")
        #expect(try DefaultsRPC.patchCLI(["cli": .string("glab")]) == "glab")
        #expect(try DefaultsRPC.patchCLI([:]) == nil)

        for value: JSONValue in [.string("hub"), .string("GH"), .string(""), .array([])] {
            #expect(throws: RPCError.self, "expected \(value) to be rejected") {
                _ = try DefaultsRPC.patchCLI(["cli": value])
            }
        }
    }

    /// Delegates to `ConfigDefaults.isValidBranchPrefix` rather than re-deriving
    /// git's ref rules — pin that the delegation is wired, not the rules
    /// themselves (`AppConfigTests` owns those).
    @Test func patchBranchPrefixDelegatesToModelValidation() throws {
        #expect(try DefaultsRPC.patchBranchPrefix(["branch_prefix": .string("feature/")]) == "feature/")
        // Empty is legal in the model and means "no prefix".
        #expect(try DefaultsRPC.patchBranchPrefix(["branch_prefix": .string("")]) == "")
        #expect(try DefaultsRPC.patchBranchPrefix([:]) == nil)

        for bad in ["bad..prefix", "has space/", "tilde~/", "trailing.", "at@{x}/", "star*/"] {
            #expect(throws: RPCError.self, "expected '\(bad)' to be rejected") {
                _ = try DefaultsRPC.patchBranchPrefix(["branch_prefix": .string(bad)])
            }
        }
    }

    /// Trim *before* validating. `isValidBranchPrefix` rejects any space, so
    /// without the trim a pasted `"feature/ "` would come back as a validation
    /// error rather than the obvious thing the caller meant. A tab or newline
    /// would instead sail through the predicate and produce a branch name git
    /// refuses at `worktree add` — long after the write looked successful.
    @Test func patchBranchPrefixTrimsSurroundingWhitespace() throws {
        #expect(try DefaultsRPC.patchBranchPrefix(["branch_prefix": .string("  feature/  ")]) == "feature/")
        #expect(try DefaultsRPC.patchBranchPrefix(["branch_prefix": .string("\tfeat/\n")]) == "feat/")
    }

    // MARK: - String-list patches

    @Test func patchStringListReturnsNilWhenNoKeyOfTheTrioIsPresent() throws {
        #expect(try DefaultsRPC.patchStringList([:], "exclude_review_repos") == nil)
        #expect(try DefaultsRPC.patchStringList([
            "add_exclude_review_repos": .null,
            "remove_exclude_review_repos": .null,
            "clear_exclude_review_repos": .null,
        ], "exclude_review_repos") == nil)
        // A neighbouring list's params must not make this one look touched.
        #expect(try DefaultsRPC.patchStringList([
            "add_ignore_review_labels": .array([.string("wip")]),
        ], "exclude_review_repos") == nil)
    }

    @Test func patchStringListDecodesTheTrio() throws {
        let patch = try DefaultsRPC.patchStringList([
            "add_exclude_review_repos": .array([.string("acme/docs")]),
            "remove_exclude_review_repos": .array([.string("acme/old")]),
        ], "exclude_review_repos")
        #expect(patch == DefaultsRPC.StringListPatch(add: ["acme/docs"], remove: ["acme/old"]))

        let cleared = try DefaultsRPC.patchStringList([
            "clear_exclude_ticket_repos": .bool(true),
        ], "exclude_ticket_repos")
        #expect(cleared == DefaultsRPC.StringListPatch(clear: true))

        // `clear: false` is a real key but not a real edit.
        #expect(try DefaultsRPC.patchStringList([
            "clear_exclude_ticket_repos": .bool(false),
        ], "exclude_ticket_repos") == nil)
    }

    @Test func patchStringListNormalizesAddValues() throws {
        let patch = try DefaultsRPC.patchStringList([
            "add_exclude_review_repos": .array([
                .string("  acme/docs  "), .string("acme/docs"), .string("ACME/DOCS"),
                .string("   "), .string("acme/api"),
            ]),
        ], "exclude_review_repos")
        // Trimmed, blanks dropped, deduped case-insensitively keeping first casing.
        #expect(patch?.add == ["acme/docs", "acme/api"])
    }

    @Test func patchStringListRejectsClearCombinedWithAddOrRemove() {
        for other in ["add_exclude_review_repos", "remove_exclude_review_repos"] {
            #expect(throws: RPCError.self, "expected clear + \(other) to be rejected") {
                _ = try DefaultsRPC.patchStringList([
                    "clear_exclude_review_repos": .bool(true),
                    other: .array([.string("acme/docs")]),
                ], "exclude_review_repos")
            }
        }
    }

    /// Strict element typing, per `AllowlistRPC.decodePatterns`: a bare
    /// `compactMap` would apply a *subset* of the request and still report
    /// success. An all-blank array is likewise a caller bug — "empty the list"
    /// has its own key.
    @Test func patchStringListRejectsMalformedArrays() {
        let bad: [JSONValue] = [
            .string("acme/docs"),                        // not an array
            .array([.string("ok"), .int(3)]),            // non-string element
            .array([]),                                  // no survivor
            .array([.string("  "), .string("")]),        // all blank
        ]
        for value in bad {
            #expect(throws: RPCError.self, "expected \(value) to be rejected") {
                _ = try DefaultsRPC.patchStringList([
                    "add_exclude_review_repos": value,
                ], "exclude_review_repos")
            }
        }
        #expect(throws: RPCError.self) {
            _ = try DefaultsRPC.patchStringList([
                "clear_exclude_review_repos": .string("yes"),
            ], "exclude_review_repos")
        }
    }

    // MARK: - StringListPatch.apply

    /// Case-insensitive, matching the *consumers* (`repoMatchesPatterns`
    /// lowercases both sides; `ignoreReviewLabels` is matched through a
    /// lowercased Set). An exact-match remove would report `saved: true` while
    /// the repo stayed excluded.
    @Test func applyRemovesCaseInsensitively() {
        let patch = DefaultsRPC.StringListPatch(remove: ["ACME/Scratch"])
        #expect(patch.apply(to: ["acme/scratch", "acme/keep"]) == ["acme/keep"])
    }

    @Test func applyIsANoOpWhenRemovingSomethingAbsent() {
        // Idempotent by design: `remove` is a set predicate, not an identified
        // entity, so a script need not pre-check with `get`.
        let patch = DefaultsRPC.StringListPatch(remove: ["acme/never-there"])
        #expect(patch.apply(to: ["acme/keep"]) == ["acme/keep"])
    }

    @Test func applyDedupesAddsAgainstStoredCasing() {
        let patch = DefaultsRPC.StringListPatch(add: ["ACME/Docs", "acme/new"])
        // Existing casing wins — the caller asked to add, not to re-case, and
        // rewriting churns config.json for no behavioural change.
        #expect(patch.apply(to: ["acme/docs"]) == ["acme/docs", "acme/new"])
    }

    /// Remove runs before add, so naming a value in both means "ensure it's
    /// there" rather than silently dropping it.
    @Test func applyRunsRemoveBeforeAdd() {
        let patch = DefaultsRPC.StringListPatch(add: ["acme/docs"], remove: ["acme/docs"])
        #expect(patch.apply(to: ["acme/docs", "acme/api"]) == ["acme/api", "acme/docs"])
    }

    @Test func applyClearBeatsEverything() {
        #expect(DefaultsRPC.StringListPatch(clear: true).apply(to: ["a", "b"]) == [])
        #expect(DefaultsRPC.StringListPatch(clear: true).apply(to: []) == [])
    }

    @Test func applyPreservesOrderAndAppends() {
        let patch = DefaultsRPC.StringListPatch(add: ["z"], remove: ["b"])
        #expect(patch.apply(to: ["a", "b", "c"]) == ["a", "c", "z"])
    }

    // MARK: - binaries

    @Test func patchBinariesDecodesNamesAndPaths() throws {
        let patch = try DefaultsRPC.patchBinaries([
            "binaries": .object([
                "corveil": .string("/opt/corveil/bin/corveil"),
                "codex": .string(""),
            ]),
        ])
        #expect(patch == ["corveil": "/opt/corveil/bin/corveil", "codex": ""])
        #expect(try DefaultsRPC.patchBinaries([:]) == nil)
        #expect(try DefaultsRPC.patchBinaries(["binaries": .null]) == nil)
    }

    /// A blank key is not cosmetic: `Scaffolder.installBinarySymlinks` builds
    /// `binDir.appendingPathComponent(name)`, which for `""` *is* `binDir` — and
    /// then `removeItem`s it and symlinks over it. A `/`-bearing name escapes the
    /// dir entirely, where the reap loop (which walks `contentsOfDirectory`)
    /// could never clean the orphan up.
    @Test func patchBinariesRejectsPathLikeAndBlankNames() {
        for name in ["", "   ", "/", "bin/corveil", "../escape", ".", "..", "a\\b"] {
            #expect(throws: RPCError.self, "expected name '\(name)' to be rejected") {
                _ = try DefaultsRPC.patchBinaries([
                    "binaries": .object([name: .string("/usr/bin/true")]),
                ])
            }
        }
    }

    /// `crow` is owned by `Scaffolder`: `managedBinarySymlinks` exempts it from
    /// reaping and `ensureCrowCLISymlink` overwrites it every launch, while
    /// `BinaryOverrides` never consults it (not an `AgentKind`). Accepting it
    /// would answer `saved: true, restart_required: true` for a write that cannot
    /// take effect.
    @Test func patchBinariesRejectsTheReservedCrowName() {
        #expect(throws: RPCError.self) {
            _ = try DefaultsRPC.patchBinaries([
                "binaries": .object(["crow": .string("/usr/local/bin/crow")]),
            ])
        }
        // Even to delete it — the key is not ours to manage either way.
        #expect(throws: RPCError.self) {
            _ = try DefaultsRPC.patchBinaries(["binaries": .object(["crow": .string("")])])
        }
    }

    /// `Scaffolder` resolves a target with `isExecutableFile(atPath:)`, which
    /// interprets a relative path against the *daemon's* cwd — not the caller's
    /// shell, and not stably.
    @Test func patchBinariesRequiresAbsolutePaths() {
        for path in ["bin/corveil", "./corveil", "~/bin/corveil", "corveil"] {
            #expect(throws: RPCError.self, "expected path '\(path)' to be rejected") {
                _ = try DefaultsRPC.patchBinaries(["binaries": .object(["corveil": .string(path)])])
            }
        }
    }

    @Test func patchBinariesRejectsMalformedObjects() {
        let bad: [JSONValue] = [
            .array([]),                                     // not an object
            .string("/opt/corveil"),                        // not an object
            .object([:]),                                   // inert write
            .object(["corveil": .int(1)]),                   // non-string value
            .object(["corveil": .null]),                     // non-string value
        ]
        for value in bad {
            #expect(throws: RPCError.self, "expected \(value) to be rejected") {
                _ = try DefaultsRPC.patchBinaries(["binaries": value])
            }
        }
    }

    /// The map is shared by `AgentKind`-keyed binary discovery and tool-name-keyed
    /// installers, so a *replace* would drop the other caller's keys. Merge.
    @Test func mergeBinariesSetsDeletesAndLeavesOthersAlone() {
        let stored = ["codex": "/opt/codex", "corveil": "/old/corveil"]
        let merged = DefaultsRPC.mergeBinaries(
            ["corveil": "/new/corveil", "cursor": "/opt/cursor"], into: stored)
        #expect(merged == ["codex": "/opt/codex", "corveil": "/new/corveil", "cursor": "/opt/cursor"])

        #expect(DefaultsRPC.mergeBinaries(["corveil": ""], into: stored) == ["codex": "/opt/codex"])
        // Deleting an absent key is a silent no-op, like removing an absent list value.
        #expect(DefaultsRPC.mergeBinaries(["nope": ""], into: stored) == stored)
        #expect(DefaultsRPC.mergeBinaries([:], into: stored) == stored)
    }

    // MARK: - Response encoding

    @Test func defaultsJSONEchoesAllNineFieldsSnakeCased() throws {
        var defaults = ConfigDefaults()
        defaults.excludeReviewRepos = ["acme/docs"]
        defaults.binaries = ["corveil": "/opt/corveil"]

        #expect(DefaultsRPC.defaultsJSON(defaults) == .object([
            "provider": .string("github"),
            "cli": .string("gh"),
            "branch_prefix": .string("feature/"),
            "exclude_dirs": .array(
                ["node_modules", ".git", "vendor", "dist", "build", "target"].map { .string($0) }),
            "exclude_review_repos": .array([.string("acme/docs")]),
            "exclude_ticket_repos": .array([]),
            "ignore_review_labels": .array([]),
            "binaries": .object(["corveil": .string("/opt/corveil")]),
            "mirror_claude_mcp_to_codex": .bool(true),
        ]))
    }

    /// `defaults` carries binary paths (already remotely visible through un-gated
    /// `get-config`, which `SettingsSecrets.strippedForTransport` does not touch)
    /// but must never grow a credential field. Pin it, because a future "just
    /// reuse the config encoder" refactor would quietly break it.
    @Test func defaultsResponseNeverContainsCredentialKeys() throws {
        let json = DefaultsRPC.defaultsJSON(ConfigDefaults())
        let text = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        for secret in ["tokenRef", "hashB64", "saltB64", "customHeaders",
                       "jiraCredential", "webAuth", "managerGateway"] {
            #expect(!text.contains(secret), "\(secret) leaked into \(text)")
        }
    }

    // MARK: - restart_required / advisories

    @Test func restartRequiredOnlyWhenBinariesActuallyChange() {
        var base = ConfigDefaults()
        base.binaries = ["corveil": "/opt/corveil"]

        var renamed = base
        renamed.binaries = ["corveil": "/opt/other/corveil"]
        #expect(DefaultsRPC.restartRequired(old: base, new: renamed))

        // A deletion counts: nothing re-scaffolds on a config change, so the
        // stale `.claude/bin` symlink keeps shadowing PATH until the next launch.
        var deleted = base
        deleted.binaries = [:]
        #expect(DefaultsRPC.restartRequired(old: base, new: deleted))

        // Re-setting a path to what it already was is a no-op; reporting a
        // restart for it would train users to ignore the flag.
        #expect(!DefaultsRPC.restartRequired(old: base, new: base))

        var liveOnly = base
        liveOnly.provider = "gitlab"
        liveOnly.cli = "glab"
        liveOnly.excludeReviewRepos = ["acme/docs"]
        liveOnly.branchPrefix = "feat/"
        #expect(!DefaultsRPC.restartRequired(old: base, new: liveOnly))
    }

    @Test func providerCLIMismatchFlagsCrossedPairsOnly() {
        #expect(DefaultsRPC.providerCLIMismatch(provider: "gitlab", cli: "gh"))
        #expect(DefaultsRPC.providerCLIMismatch(provider: "github", cli: "glab"))
        #expect(!DefaultsRPC.providerCLIMismatch(provider: "github", cli: "gh"))
        #expect(!DefaultsRPC.providerCLIMismatch(provider: "gitlab", cli: "glab"))
    }
}
