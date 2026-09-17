import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// CROW-1268: a `.pr` link registered on a stale GitHub owner alias (e.g. the
/// old org name after a rename, which GitHub 301-redirects) never correlates to
/// the polled PR, so the per-session PR-status chips stay blank even for a
/// healthy, approved PR. Every downstream matcher keys on the stored link URL
/// (`byURL[prLink.url]`, and the `PRRef` built from it in the stale-PR fetch),
/// and GitHub's GraphQL `repository(owner:name:)` does not follow renames — so
/// the fix canonicalizes the one stored URL, self-healing all of them at once.
@Suite("Aliased PR link canonicalization (CROW-1268)")
@MainActor
struct PRLinkCanonicalizeTests {

    // MARK: - Pure URL parsing

    @Test func parsesCanonicalGitHubPRURL() {
        let parsed = PRLinkReconciler.parseGitHubPRURL("https://github.com/corveil/corveil/pull/3466")
        #expect(parsed?.slug == "corveil/corveil")
        #expect(parsed?.number == 3466)
        #expect(parsed?.tail == "")
    }

    @Test func parsesAliasOwnerAndPreservesTrailingPath() {
        let parsed = PRLinkReconciler.parseGitHubPRURL("https://github.com/RadiusMethod/corveil/pull/3466/files")
        #expect(parsed?.slug == "RadiusMethod/corveil")
        #expect(parsed?.number == 3466)
        #expect(parsed?.tail == "/files")
    }

    @Test func rejectsNonPRAndNonGitHubURLs() {
        // Not a /pull/ URL.
        #expect(PRLinkReconciler.parseGitHubPRURL("https://github.com/corveil/corveil/issues/3466") == nil)
        // GitLab host — redirect canonicalization is github.com-scoped.
        #expect(PRLinkReconciler.parseGitHubPRURL("https://gitlab.com/group/sub/repo/-/merge_requests/12") == nil)
        // GitHub Enterprise host — out of scope; the REST redirect-follow is github.com.
        #expect(PRLinkReconciler.parseGitHubPRURL("https://github.example.com/corveil/corveil/pull/1") == nil)
        // No number.
        #expect(PRLinkReconciler.parseGitHubPRURL("https://github.com/corveil/corveil/pull/") == nil)
    }

    // MARK: - Pure canonicalization (redirect resolution mocked)

    /// The core repro: an alias-owner URL rewrites to the canonical owner, number
    /// and any tail preserved. This is the matcher the ticket asks to unit-test
    /// with an alias vs canonical owner, with the redirect resolution mocked.
    @Test func aliasOwnerRewritesToCanonical() {
        let resolve: (String) -> String? = { $0 == "radiusmethod/corveil" ? "corveil/corveil" : nil }
        #expect(PRLinkReconciler.canonicalizedPRURL(
            "https://github.com/RadiusMethod/corveil/pull/3466", resolveSlug: resolve)
            == "https://github.com/corveil/corveil/pull/3466")
        // Tail preserved.
        #expect(PRLinkReconciler.canonicalizedPRURL(
            "https://github.com/RadiusMethod/corveil/pull/3466/files", resolveSlug: resolve)
            == "https://github.com/corveil/corveil/pull/3466/files")
    }

    /// A canonical-owner link resolves to itself → no rewrite, so the steady-state
    /// path is a no-op (and, in the live pass, never even reaches resolution).
    @Test func canonicalOwnerIsNotRewritten() {
        let resolve: (String) -> String? = { $0 == "corveil/corveil" ? "corveil/corveil" : nil }
        #expect(PRLinkReconciler.canonicalizedPRURL(
            "https://github.com/corveil/corveil/pull/3466", resolveSlug: resolve) == nil)
    }

    /// A slug that doesn't resolve (unknown / 404) leaves the URL untouched.
    @Test func unresolvableSlugIsNotRewritten() {
        #expect(PRLinkReconciler.canonicalizedPRURL(
            "https://github.com/ghost/repo/pull/1", resolveSlug: { _ in nil }) == nil)
    }

    /// An owner that differs only in case is the same repo — not a rewrite.
    @Test func caseOnlyDifferenceIsNotRewritten() {
        let resolve: (String) -> String? = { _ in "Corveil/Corveil" }
        #expect(PRLinkReconciler.canonicalizedPRURL(
            "https://github.com/corveil/corveil/pull/3466", resolveSlug: resolve) == nil)
    }

    // MARK: - Live pass: correlation, payload gate, and per-repo cache

    /// Keyed, call-counting `ShellRunner`. Answers `gh api repos/<slug> --jq
    /// .full_name` from `canonicalBySlug`, 404s any slug it doesn't know, and
    /// records how many times each repo was queried. Thread-safe because the
    /// pass resolves off the main actor via `Task.detached`.
    private final class CanonicalizingShellRunner: ShellRunner, @unchecked Sendable {
        let canonicalBySlug: [String: String]
        private let lock = NSLock()
        private var callsBySlug: [String: Int] = [:]

        init(_ canonicalBySlug: [String: String]) { self.canonicalBySlug = canonicalBySlug }

        func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
            if args.count >= 3, args[0] == "gh", args[1] == "api", args[2].hasPrefix("repos/") {
                let slug = String(args[2].dropFirst("repos/".count))
                lock.withLock { callsBySlug[slug, default: 0] += 1 }
                if let canonical = canonicalBySlug[slug] { return canonical + "\n" }
                throw ShellRunnerError.nonZeroExit(exitCode: 1, output: "gh: Not Found (HTTP 404)")
            }
            return ""
        }

        func calls(for slug: String) -> Int { lock.withLock { callsBySlug[slug] ?? 0 } }
    }

    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-canonicalize-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private func makeTracker(
        prURL: String,
        shellRunner: ShellRunner
    ) -> (tracker: IssueTracker, sessionID: UUID, state: AppState) {
        let state = AppState()
        let session = Session(name: "feature/x", kind: .work)
        state.sessions = [session]
        state.links[session.id] = [
            SessionLink(sessionID: session.id, label: "PR #3466", url: prURL, linkType: .pr)
        ]
        let tracker = IssueTracker(
            appState: state,
            providerManager: ProviderManager(shellRunner: shellRunner),
            store: Self.tempStore())
        return (tracker, session.id, state)
    }

    private func approvedPR(url: String, number: Int, repo: String) -> PRRecord {
        PRRecord(
            number: number, url: url, state: "OPEN",
            mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: "APPROVED",
            headRefOid: "abc123", repoNameWithOwner: repo, checksState: "SUCCESS")
    }

    /// End-to-end: an alias-owner link is rewritten to canonical, after which the
    /// status pass correlates the canonical payload URL and the chip populates.
    @Test func aliasLinkIsCanonicalizedThenCorrelates() async {
        let aliasURL = "https://github.com/RadiusMethod/corveil/pull/3466"
        let canonicalURL = "https://github.com/corveil/corveil/pull/3466"
        let mock = CanonicalizingShellRunner(["RadiusMethod/corveil": "corveil/corveil"])
        let (tracker, sessionID, state) = makeTracker(prURL: aliasURL, shellRunner: mock)

        // Poll payload carries the PR under its canonical URL (viewer PRs).
        await tracker.reconciler.canonicalizeAliasedPRLinks(knownPRURLs: [canonicalURL])

        // The stored link is now canonical…
        #expect(state.links[sessionID]?.first?.url == canonicalURL)
        #expect(mock.calls(for: "RadiusMethod/corveil") == 1)

        // …so the next poll's status pass correlates it and populates the chip.
        tracker.applyPRStatuses(viewerPRs: [approvedPR(url: canonicalURL, number: 3466, repo: "corveil/corveil")])
        #expect(state.prStatus[sessionID]?.reviewStatus == .approved)
    }

    /// A healthy canonical link is already in the payload, so it is never a
    /// candidate — no redirect lookup happens on the steady-state path.
    @Test func canonicalLinkInPayloadTriggersNoRedirectLookup() async {
        let canonicalURL = "https://github.com/corveil/corveil/pull/3466"
        let mock = CanonicalizingShellRunner(["corveil/corveil": "corveil/corveil"])
        let (tracker, sessionID, state) = makeTracker(prURL: canonicalURL, shellRunner: mock)

        await tracker.reconciler.canonicalizeAliasedPRLinks(knownPRURLs: [canonicalURL])

        #expect(state.links[sessionID]?.first?.url == canonicalURL)
        #expect(mock.calls(for: "corveil/corveil") == 0)
    }

    /// The redirect lookup is resolved at most once per repo: a link whose PR is
    /// not in the payload (a payload miss) resolves its slug once and caches it,
    /// so a second poll makes no further API call.
    @Test func redirectLookupIsAtMostOncePerRepo() async {
        // Canonical owner, but the PR is absent from the payload — a candidate on
        // every poll, yet the slug resolves to itself and must be cached.
        let url = "https://github.com/corveil/corveil/pull/9999"
        let mock = CanonicalizingShellRunner(["corveil/corveil": "corveil/corveil"])
        let (tracker, sessionID, state) = makeTracker(prURL: url, shellRunner: mock)

        await tracker.reconciler.canonicalizeAliasedPRLinks(knownPRURLs: [])
        await tracker.reconciler.canonicalizeAliasedPRLinks(knownPRURLs: [])

        #expect(mock.calls(for: "corveil/corveil") == 1)
        #expect(state.links[sessionID]?.first?.url == url)  // unchanged (already canonical)
    }

    /// A 404 slug caches as unresolvable, so it doesn't re-query every poll and
    /// leaves the link untouched.
    @Test func unresolvableSlugCachesAndDoesNotLoop() async {
        let url = "https://github.com/ghost-org/repo/pull/7"
        let mock = CanonicalizingShellRunner([:])  // every slug 404s
        let (tracker, sessionID, state) = makeTracker(prURL: url, shellRunner: mock)

        await tracker.reconciler.canonicalizeAliasedPRLinks(knownPRURLs: [])
        await tracker.reconciler.canonicalizeAliasedPRLinks(knownPRURLs: [])

        #expect(mock.calls(for: "ghost-org/repo") == 1)
        #expect(state.links[sessionID]?.first?.url == url)  // unchanged
    }
}
