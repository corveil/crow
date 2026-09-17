import Foundation
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider

/// Session ↔ PR link detection and reconciliation, extracted from
/// `IssueTracker` (CROW-1094). The reactive `applySessionPRLinks` pass attaches
/// links from the viewer-PR payload; `reconcileMissingPRLinks` queries providers
/// directly by (repoSlug, branch), Jira ticket key, or GitHub `Closes #N`
/// (CROW-1221) for sessions still missing a `.pr` link. Writes links through
/// the shared, injected `JSONStore` (ADR 0012 / #728) and `appState` via an
/// unowned back-reference. Pure decision helpers stay `nonisolated static` for
/// unit testing. `public` because the session-capability predicates
/// `canAddMergeLabel` / `canSetProjectStatus` are cross-module API (re-exposed
/// under the old `IssueTracker.` spelling).
@MainActor
public final class PRLinkReconciler {
    private unowned let owner: IssueTracker
    private var appState: AppState { owner.appState }
    private var providerManager: ProviderManager { owner.providerManager }
    private var store: JSONStore { owner.store }

    /// Local alias mirroring `IssueTracker.ViewerPR` (both are `PRRecord`).
    typealias ViewerPR = PRRecord

    init(owner: IssueTracker) { self.owner = owner }

    /// Canonical-slug resolutions for `canonicalizeAliasedPRLinks`, keyed by the
    /// lowercased alias slug ("radiusmethod/corveil" → "corveil/corveil"). A
    /// canonical or definitively-missing repo caches to itself, so each distinct
    /// repo triggers at most one redirect lookup for the daemon's lifetime — the
    /// redirect resolution is per-repo, never per-poll (CROW-1268). Transient
    /// failures are not cached, so they retry on a later poll.
    /// Internal (not private) so `@testable` tests can seed it.
    var canonicalRepoSlugCache: [String: String] = [:]

    // MARK: - Session PR Link Detection (piggyback)

    /// Build an index of viewer PRs keyed by `(repoSlug, branch)` and `url`, then
    /// attach PR links to sessions whose primary worktree branch matches.
    func applySessionPRLinks(viewerPRs: [ViewerPR]) {
        guard !viewerPRs.isEmpty else { return }

        // Prefer OPEN PRs over closed ones when a branch has multiple.
        var byBranch: [String: ViewerPR] = [:]  // key = "repo/slug#branch"
        for pr in viewerPRs {
            let key = "\(pr.repoNameWithOwner)#\(pr.headRefName)"
            if let existing = byBranch[key] {
                if pr.state == "OPEN" && existing.state != "OPEN" {
                    byBranch[key] = pr
                }
            } else {
                byBranch[key] = pr
            }
        }

        // Accumulate new links and persist them in a single store write below.
        // Writing per-session inside the loop meant N full-store encode + atomic
        // disk writes when a burst of PRs got linked at once — the dominant
        // main-thread stall behind the concurrent-review freeze (#304).
        var newLinks: [SessionLink] = []

        for session in appState.sessions {
            guard !session.isManager else { continue }
            let wts = appState.worktrees(for: session.id)
            let links = appState.links(for: session.id)

            guard !links.contains(where: { $0.linkType == .pr }) else { continue }
            guard let primaryWt = wts.first(where: { $0.isPrimary }) ?? wts.first else { continue }

            let branch = primaryWt.branch
            guard !branch.isEmpty else { continue }

            let repoSlug = resolveRepoSlug(worktree: primaryWt)
            guard !repoSlug.isEmpty else { continue }

            guard let pr = byBranch["\(repoSlug)#\(branch)"] else { continue }

            let link = SessionLink(
                sessionID: session.id,
                label: "PR #\(pr.number)",
                url: pr.url,
                linkType: .pr
            )
            appState.links[session.id, default: []].append(link)
            newLinks.append(link)
        }

        guard !newLinks.isEmpty else { return }
        // Route through the shared, injected `store` — never a throwaway
        // `JSONStore()`. A fresh instance reads its own (possibly stale) disk
        // snapshot and its full-store write can silently clobber a session
        // another writer just added (#728).
        store.mutate { data in
            data.links.append(contentsOf: newLinks)
        }
    }

    // MARK: - Session PR Link Reconciliation

    /// A session that the reconcile pass should query a provider for. Built from
    /// non-archived, non-review sessions that have a primary worktree branch
    /// but no `.pr` link yet.
    struct ReconcileCandidate: Sendable, Equatable {
        let sessionID: UUID
        let provider: Provider
        let repoSlug: String       // "corveil/crow"
        let branch: String
        let gitlabHost: String?    // nil for github.com
    }

    /// A Jira-tasked session whose PR should be found by the *ticket key* it
    /// references (e.g. `MAXX-6859`) rather than by branch. Jira PR branches
    /// are renamed by the working agent and rarely match the session's
    /// registered worktree branch, so branch matching can't find them.
    struct ReconcileKeyCandidate: Sendable, Equatable {
        let sessionID: UUID
        let provider: Provider     // code provider (.github today)
        let repoSlug: String
        let key: String            // "MAXX-6859"
        let gitlabHost: String?
    }

    /// A branch match returned by the provider. `state` follows GitHub's
    /// `PullRequestState` for GitHub and a normalized "OPEN"/"MERGED"/"CLOSED"
    /// for GitLab (mapping `opened|merged|closed`). `updatedAt` drives
    /// tie-breaking when a branch has multiple non-OPEN PRs.
    struct ReconcileBranchMatch: Sendable, Equatable {
        let sessionID: UUID
        let number: Int
        let url: String
        let state: String
        let updatedAt: Date?
    }

    /// Given a set of matches per session, decide which link to create for
    /// each session. Prefers OPEN over non-OPEN; falls back to most-recent
    /// `updatedAt`. Deterministic when timestamps are absent (highest `number`
    /// wins as a stable tie-breaker). Pure — no appState, no I/O.
    nonisolated static func decideReconcileLinks(
        matches: [ReconcileBranchMatch]
    ) -> [ReconcileBranchMatch] {
        let bySession = Dictionary(grouping: matches, by: { $0.sessionID })
        var picks: [ReconcileBranchMatch] = []
        for (_, group) in bySession {
            guard let pick = group.max(by: { lhs, rhs in
                // Returns true when lhs should sort BEFORE rhs (i.e. rhs wins).
                let lhsOpen = lhs.state == "OPEN"
                let rhsOpen = rhs.state == "OPEN"
                if lhsOpen != rhsOpen { return !lhsOpen }  // rhs open → rhs wins
                switch (lhs.updatedAt, rhs.updatedAt) {
                case let (l?, r?):
                    if l != r { return l < r }  // newer wins
                case (nil, _?):
                    return true                  // rhs has date → rhs wins
                case (_?, nil):
                    return false                 // lhs has date → lhs wins
                case (nil, nil):
                    break
                }
                return lhs.number < rhs.number   // tie-break on number
            }) else { continue }
            picks.append(pick)
        }
        return picks
    }

    /// Enforce that a single PR attaches to at most one work item. Groups the
    /// final per-session picks by PR URL; if a URL is claimed by sessions with
    /// more than one distinct work-item identity (ticket key, else branch), the
    /// PR can't be attributed to one of them with confidence, so it is dropped
    /// from all of them — never guess (#520). Duplicate sessions sharing one
    /// identity (same key/branch) keep the link. Pure — no appState, no I/O.
    nonisolated static func dedupeContestedPRs(
        _ picks: [ReconcileBranchMatch],
        identityBySession: [UUID: String]
    ) -> [ReconcileBranchMatch] {
        let byURL = Dictionary(grouping: picks, by: { $0.url })
        var out: [ReconcileBranchMatch] = []
        for (_, group) in byURL {
            let identities = Set(group.compactMap { identityBySession[$0.sessionID] })
            if identities.count > 1 { continue }   // contested across tickets → none
            out.append(contentsOf: group)
        }
        return out
    }

    /// Route a reconcile candidate to a *code* backend. A task-only provider
    /// (`.jira`) has no code surface, so a session tracked by one resolves PRs
    /// through its `codeProvider` — mirroring the
    /// `codeProvider ?? provider` convention in `SessionService.findPRLink` and
    /// `AutoRespondCoordinator`. Falls back to host sniffing when no
    /// code-bearing provider is recorded (e.g. sessions predating the field).
    /// Pure — no appState, no I/O.
    nonisolated static func resolveReconcileProvider(
        codeProvider: Provider?, provider: Provider?, host: String
    ) -> (provider: Provider, gitlabHost: String?) {
        if let p = codeProvider ?? provider, !p.isTaskOnly {
            return (p, p == .gitlab ? (host.isEmpty ? nil : host) : nil)
        }
        if host == "github.com" || host.isEmpty { return (.github, nil) }
        return (.gitlab, host)
    }

    /// Whether `session` may add the `crow:merge` label to its PR — i.e. its
    /// **code** backend declares `.autoMergeLabel`. Resolves the code provider
    /// via the `codeProvider ?? provider ?? .github` convention (ADR 0005) so a
    /// Jira/Corveil-tasked GitHub-code session is gated on GitHub, not on its
    /// task provider (CROW-532). Pure — easily unit-tested.
    public nonisolated static func canAddMergeLabel(session: Session, providerManager: ProviderManager) -> Bool {
        let provider = session.codeProvider ?? session.provider ?? .github
        return providerManager.codeBackend(for: provider)?.capabilities.contains(.autoMergeLabel) ?? false
    }

    /// Whether `session` may be moved to a project-board "In Review" status —
    /// i.e. its **task** backend declares `.projectBoardStatus`. Mirrors the
    /// retired native `AppState.canSetProjectStatus(for:)` (GitHub Projects v2 /
    /// Jira: yes; GitLab: no — ADR 0005), which gated the "In Review" button.
    /// Restores that gate for the web UI (CROW-749). Pure — unit-tested like
    /// `canAddMergeLabel`.
    public nonisolated static func canSetProjectStatus(session: Session, providerManager: ProviderManager) -> Bool {
        guard let provider = session.provider else { return false }
        return providerManager.taskBackend(for: provider).capabilities.contains(.projectBoardStatus)
    }

    /// Instance convenience over ``canSetProjectStatus(session:providerManager:)``
    /// using this tracker's provider manager — the daemon's `list-sessions` gate.
    /// Infers `provider` from the session's ticket URL or first `.ticket` link
    /// when `set-ticket` never wrote it (CROW-1244).
    public func canSetProjectStatus(for session: Session) -> Bool {
        var resolved = session
        if resolved.provider == nil,
           let url = resolved.effectiveTicketURL(from: appState.links(for: resolved.id)) {
            resolved.provider = Validation.detectProviderFromURL(url)
        }
        return Self.canSetProjectStatus(session: resolved, providerManager: providerManager)
    }

    /// For each non-archived, non-review session missing a `.pr` link with a
    /// resolvable (repoSlug, branch), query the provider directly and upsert
    /// a link when a PR exists on that branch. Runs once per refresh cycle
    /// after the reactive `applySessionPRLinks` pass.
    func reconcileMissingPRLinks() async {
        let candidates = buildReconcileCandidates()
        let keyCandidates = buildReconcileKeyCandidates()
        guard !candidates.isEmpty || !keyCandidates.isEmpty else { return }

        var matches: [ReconcileBranchMatch] = []

        let github = candidates.filter { $0.provider == .github }
        if !github.isEmpty, let hits = await fetchPRsForReconcile(candidates: github) {
            matches.append(contentsOf: hits)
        }

        let gitlab = candidates.filter { $0.provider == .gitlab }
        let hostsSeen = Set(gitlab.compactMap { $0.gitlabHost })
        for host in hostsSeen {
            let forHost = gitlab.filter { $0.gitlabHost == host }
            matches.append(contentsOf: await fetchGitLabMRsForReconcile(candidates: forHost, host: host))
        }

        // Jira-tasked sessions: find the PR by the ticket key it references,
        // since the PR branch won't match the worktree branch. GitHub-tasked
        // sessions: find the PR by `Closes #N` when the registered branch is
        // missing, empty, or renamed (CROW-1221). Feeds the same
        // `decideReconcileLinks` so a key-found and branch-found PR for one
        // session resolve to a single best pick.
        matches.append(contentsOf: await fetchPRsByKeyForReconcile(candidates: keyCandidates))

        // Each session's work-item identity (key preferred, else branch) so the
        // de-dup pass can tell a legitimate duplicate-session match from one PR
        // being claimed by two different tickets.
        var identityBySession: [UUID: String] = [:]
        for c in candidates { identityBySession[c.sessionID] = c.branch }
        for c in keyCandidates { identityBySession[c.sessionID] = c.key }

        let decided = Self.decideReconcileLinks(matches: matches)
        applyReconciledPRLinks(Self.dedupeContestedPRs(decided, identityBySession: identityBySession))
    }

    // MARK: - Aliased PR Link Canonicalization (CROW-1268)

    /// Self-heal `.pr` links registered on a stale GitHub owner alias.
    ///
    /// A GitHub org/repo rename leaves the old `owner/repo` as a 301 redirect;
    /// a coder (or a clone whose `origin` remote still uses the old org name)
    /// can register a `.pr` link on that alias owner. Every downstream matcher
    /// keys on the stored link URL — the exact-URL `byURL[prLink.url]` join in
    /// `applyPRStatuses` and the three auto-* controllers, and the `PRRef` built
    /// from the link URL in `BoardPoller.fetchStalePRStates` — and GitHub's
    /// GraphQL `repository(owner:name:)` does NOT follow renames, so an aliased
    /// owner leaves every PR-status chip (CI / review / auto-merge /
    /// mergeability) blank even for a healthy, approved PR.
    ///
    /// This rewrites such a link's stored URL to the canonical `owner/repo`,
    /// after which all of the above match with no per-matcher change. Robustness
    /// belongs here, not only at `add-link` time, so the poller doesn't depend on
    /// every coder registering the canonical URL.
    ///
    /// Cost: gated on `knownPRURLs` — a healthy canonical link is already in the
    /// poll payload, so it is never a candidate and never triggers a lookup —
    /// and `canonicalRepoSlugCache` bounds resolution to at most once per repo
    /// for the daemon's lifetime. The rewrite is persisted, so the chips
    /// populate on the *next* poll's status pass (a one-poll, self-healing lag
    /// for a rare correction).
    ///
    /// - Parameter knownPRURLs: canonical PR URLs seen in this poll's payload
    ///   (viewer PRs ∪ stale follow-up), used only as the payload-miss gate.
    func canonicalizeAliasedPRLinks(knownPRURLs: Set<String>) async {
        guard let backend = providerManager.codeBackend(for: .github) else { return }

        struct Candidate { let sessionID: UUID; let linkID: UUID; let url: String; let slug: String }
        var candidates: [Candidate] = []
        for session in appState.sessions where !session.isManager {
            for link in appState.links(for: session.id) where link.linkType == .pr {
                // A canonical link is already in the payload — skip it, so the
                // steady-state path never resolves a redirect.
                guard !knownPRURLs.contains(link.url) else { continue }
                guard let parsed = Self.parseGitHubPRURL(link.url) else { continue }
                candidates.append(Candidate(
                    sessionID: session.id, linkID: link.id, url: link.url, slug: parsed.slug))
            }
        }
        guard !candidates.isEmpty else { return }

        // Resolve each distinct, not-yet-cached slug once, off MainActor.
        let slugsToResolve = Set(candidates.map { $0.slug })
            .filter { canonicalRepoSlugCache[$0.lowercased()] == nil }
        for slug in slugsToResolve {
            do {
                let canonical = try await Task.detached {
                    try await backend.resolveCanonicalRepoSlug(slug)
                }.value
                // Cache the canonical, or the slug itself when unresolvable, so a
                // definitive miss stops re-querying. A thrown (transient) error is
                // NOT cached — a later poll retries.
                canonicalRepoSlugCache[slug.lowercased()] = canonical ?? slug
            } catch {
                owner.handleGitHubBackendError(error, operation: "resolveCanonicalRepoSlug(\(slug))")
            }
        }

        // Build rewrites, then persist in a single store write (see
        // `applySessionPRLinks` / #304 for why the write is batched).
        var rewriteByLinkID: [UUID: String] = [:]
        for c in candidates {
            guard let newURL = Self.canonicalizedPRURL(
                c.url, resolveSlug: { canonicalRepoSlugCache[$0] }
            ), newURL != c.url else { continue }
            // Don't create a duplicate PR row if both the alias and canonical
            // URLs were registered on the same session.
            if appState.links(for: c.sessionID).contains(where: { $0.url == newURL }) { continue }
            rewriteByLinkID[c.linkID] = newURL
        }
        guard !rewriteByLinkID.isEmpty else { return }

        for c in candidates {
            guard let newURL = rewriteByLinkID[c.linkID],
                  var links = appState.links[c.sessionID],
                  let i = links.firstIndex(where: { $0.id == c.linkID }) else { continue }
            let old = links[i].url
            links[i].url = newURL
            appState.links[c.sessionID] = links
            CrowLog.automation(
                "pr-link canonicalize: session=\(c.sessionID.uuidString) "
                + "rewrote aliased PR link \(old) → \(newURL)")
        }
        // Route through the shared, injected `store` — never a throwaway
        // `JSONStore()` (#728). Mirrors `edit-link`'s in-place URL rewrite.
        store.mutate { data in
            for i in data.links.indices {
                if let newURL = rewriteByLinkID[data.links[i].id] {
                    data.links[i].url = newURL
                }
            }
        }
    }

    /// Walk appState and build the set of sessions needing a reconcile pass.
    /// Runs on MainActor; safe to read appState directly.
    private func buildReconcileCandidates() -> [ReconcileCandidate] {
        var out: [ReconcileCandidate] = []
        for session in appState.sessions {
            guard !session.isManager else { continue }
            guard session.status != .archived else { continue }
            guard session.kind == .work else { continue }  // review sessions get PR links at creation
            let links = appState.links(for: session.id)
            guard !links.contains(where: { $0.linkType == .pr }) else { continue }

            let wts = appState.worktrees(for: session.id)
            guard let primaryWt = wts.first(where: { $0.isPrimary }) ?? wts.first else { continue }
            guard !primaryWt.branch.isEmpty else { continue }

            let info = resolveRepoInfo(worktree: primaryWt)
            guard !info.slug.isEmpty else { continue }

            // Route by the *code* provider: a Jira/Corveil task-only session
            // codes against GitHub/GitLab via `codeProvider`, so resolving on
            // `session.provider` alone (→ `.jira`) would drop the candidate.
            // Falls back to host sniffing when no code-bearing provider exists.
            let (provider, gitlabHost) = Self.resolveReconcileProvider(
                codeProvider: session.codeProvider,
                provider: session.provider,
                host: info.host
            )

            // GitLab candidates require a known host — GITLAB_HOST env var is
            // how the glab wrapper picks an auth token. Skip silently rather
            // than fall through to a wrong-host call.
            if provider == .gitlab, gitlabHost == nil { continue }

            out.append(ReconcileCandidate(
                sessionID: session.id,
                provider: provider,
                repoSlug: info.slug,
                branch: primaryWt.branch,
                gitlabHost: gitlabHost
            ))
        }
        return out
    }

    /// Build key-based reconcile candidates for sessions missing a `.pr` link.
    ///
    /// - **Jira:** ticket key (`MAXX-6859`) from the browse URL or, for
    ///   task-only trackers, from the worktree branch. Still needs a worktree
    ///   to resolve `repoSlug` from the git remote — Jira URLs have no GitHub
    ///   slug.
    /// - **GitHub:** issue number (`#473`) from `ticketNumber` / `ticketURL`.
    ///   `owner/repo` comes from the issue URL when present, so a missing
    ///   worktree no longer drops the session (CROW-1221). GitLab stays on
    ///   branch matching.
    ///
    /// Runs on MainActor; safe to read appState directly.
    private func buildReconcileKeyCandidates() -> [ReconcileKeyCandidate] {
        var out: [ReconcileKeyCandidate] = []
        for session in appState.sessions {
            guard !session.isManager else { continue }
            guard session.status != .archived else { continue }
            guard session.kind == .work else { continue }
            let links = appState.links(for: session.id)
            guard !links.contains(where: { $0.linkType == .pr }) else { continue }

            let wts = appState.worktrees(for: session.id)
            let primaryWt = wts.first(where: { $0.isPrimary }) ?? wts.first

            // Resolve the ticket key: prefer a Jira ticket URL, else derive it
            // from the worktree branch (e.g. `feature/max-monorepo-maxx-7035-…`
            // → `MAXX-7035`). The branch fallback covers the prefix-drop case
            // where the PR head loses the repo prefix the worktree carries (#520).
            //
            // The branch fallback is gated to task-only trackers (Jira/Corveil):
            // a lowercased branch can't distinguish a real Jira project ("maxx")
            // from an ordinary word/repo segment ("api"), so a GitHub/GitLab
            // issue branch like `feature/acme-api-197-fix` would yield a bogus
            // "API-197" key. Those sessions resolve via the GitHub issue-number
            // path (below) or the branch path.
            let urlKey = session.ticketURL.flatMap {
                Validation.isJiraSpec($0) ? Validation.jiraKey(from: $0) : nil
            }
            let branchKey = (session.provider?.isTaskOnly == true)
                ? primaryWt.flatMap { Validation.ticketKey(fromBranch: $0.branch) } : nil
            if let key = urlKey ?? branchKey {
                // Jira still needs a worktree: the browse URL has no GitHub slug.
                guard let primaryWt else { continue }
                let info = resolveRepoInfo(worktree: primaryWt)
                guard !info.slug.isEmpty else { continue }

                let (provider, gitlabHost) = Self.resolveReconcileProvider(
                    codeProvider: session.codeProvider,
                    provider: session.provider,
                    host: info.host
                )
                if provider == .gitlab, gitlabHost == nil { continue }

                out.append(ReconcileKeyCandidate(
                    sessionID: session.id,
                    provider: provider,
                    repoSlug: info.slug,
                    key: key,
                    gitlabHost: gitlabHost
                ))
                continue
            }

            // GitHub issue-number path — worktree optional when ticketURL
            // already encodes owner/repo (CROW-1221).
            let info = primaryWt.map { resolveRepoInfo(worktree: $0) }
            if let cand = Self.githubIssueKeyCandidate(
                sessionID: session.id,
                ticketURL: session.ticketURL,
                ticketNumber: session.ticketNumber,
                provider: session.provider,
                codeProvider: session.codeProvider,
                worktreeSlug: info?.slug ?? "",
                worktreeHost: info?.host ?? ""
            ) {
                out.append(cand)
            }
        }
        return out
    }

    /// Pure builder for a GitHub-tasked `#<ticketNumber>` reconcile candidate.
    /// Returns nil for Jira (task-only), GitLab, missing number, or when neither
    /// the issue URL nor a worktree can supply `owner/repo`. Prefers the slug
    /// parsed from `ticketURL` so a session with no registered worktree still
    /// reconciles (CROW-1221 / #1218).
    nonisolated static func githubIssueKeyCandidate(
        sessionID: UUID,
        ticketURL: String?,
        ticketNumber: Int?,
        provider: Provider?,
        codeProvider: Provider?,
        worktreeSlug: String,
        worktreeHost: String
    ) -> ReconcileKeyCandidate? {
        if provider?.isTaskOnly == true || provider == .gitlab { return nil }
        if let url = ticketURL, !url.contains("github.com") { return nil }

        guard let number = githubIssueNumber(ticketURL: ticketURL, ticketNumber: ticketNumber) else {
            return nil
        }

        let urlSlug = repoSlug(fromTicketURL: ticketURL ?? "")
        let slug = urlSlug.isEmpty ? worktreeSlug : urlSlug
        guard !slug.isEmpty else { return nil }
        let host = urlSlug.isEmpty ? worktreeHost : "github.com"

        let (resolved, gitlabHost) = resolveReconcileProvider(
            codeProvider: codeProvider, provider: provider, host: host)
        guard resolved == .github else { return nil }

        return ReconcileKeyCandidate(
            sessionID: sessionID,
            provider: .github,
            repoSlug: slug,
            key: "#\(number)",
            gitlabHost: gitlabHost
        )
    }

    /// Issue number for GitHub-tasked reconcile: `ticketNumber` when set,
    /// otherwise the `/issues/<n>` tail of a github.com ticket URL (query and
    /// fragment stripped). Ignores `/pull/<n>` URLs — those are PRs, not tickets.
    nonisolated static func githubIssueNumber(ticketURL: String?, ticketNumber: Int?) -> Int? {
        if let ticketNumber, ticketNumber > 0 { return ticketNumber }
        guard let url = ticketURL, url.contains("github.com") else { return nil }
        guard let range = url.range(of: "/issues/", options: .caseInsensitive) else { return nil }
        let rest = url[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        guard let n = Int(digits), n > 0 else { return nil }
        return n
    }

    /// Resolve PR links by searching the code repo for a ticket key (`MAXX-6859`)
    /// or GitHub issue number (`#473`). GitHub only today (the `CodeBackend`
    /// default returns no matches for providers without text PR search).
    /// Best-effort: a backend error skips the cycle rather than dropping links.
    private func fetchPRsByKeyForReconcile(candidates: [ReconcileKeyCandidate]) async -> [ReconcileBranchMatch] {
        let github = candidates.filter { $0.provider == .github }
        guard !github.isEmpty, let backend = providerManager.codeBackend(for: .github) else { return [] }
        do {
            let matches = try await Task.detached {
                try await backend.findPRsMatchingKeys(Self.dedupedKeyCandidates(github))
            }.value
            return Self.fanOutKeyMatches(matches, across: github)
        } catch {
            owner.handleGitHubBackendError(error, operation: "findPRsMatchingKeys(github)")
            return []
        }
    }

    /// Project `ReconcileKeyCandidate`s onto de-duplicated `(repoSlug, key)`
    /// pairs for the backend. Mirrors `dedupedBranchCandidates`.
    nonisolated static func dedupedKeyCandidates(_ candidates: [ReconcileKeyCandidate]) -> [KeyCandidate] {
        var seen: Set<KeyCandidate> = []
        var out: [KeyCandidate] = []
        for c in candidates {
            let kc = KeyCandidate(repoSlug: c.repoSlug, key: c.key)
            if seen.insert(kc).inserted { out.append(kc) }
        }
        return out
    }

    /// Fan each `KeyPRMatch` back to every session sharing its `(repoSlug, key)`.
    /// Mirrors `fanOutMatches` for the branch path.
    nonisolated static func fanOutKeyMatches(
        _ matches: [KeyPRMatch],
        across candidates: [ReconcileKeyCandidate]
    ) -> [ReconcileBranchMatch] {
        var sessionsByKey: [KeyCandidate: [UUID]] = [:]
        for c in candidates {
            sessionsByKey[KeyCandidate(repoSlug: c.repoSlug, key: c.key), default: []].append(c.sessionID)
        }
        var out: [ReconcileBranchMatch] = []
        for match in matches {
            guard let sids = sessionsByKey[match.candidate] else { continue }
            for sid in sids {
                out.append(ReconcileBranchMatch(
                    sessionID: sid,
                    number: match.number,
                    url: match.url,
                    state: match.state,
                    updatedAt: match.updatedAt
                ))
            }
        }
        return out
    }

    /// One batched call per backend: GitHub issues a single aliased GraphQL
    /// query covering every candidate; GitLab issues one REST call per
    /// (host, candidate) tuple. Returns `nil` on backend error so the
    /// reconcile pass can skip the cycle without treating a degraded
    /// response as "no PRs found".
    private func fetchPRsForReconcile(candidates: [ReconcileCandidate]) async -> [ReconcileBranchMatch]? {
        guard !candidates.isEmpty else { return [] }
        let backend = providerManager.codeBackend(for: .github)!
        do {
            let matches = try await Task.detached {
                try await backend.findRecentPRsForBranches(
                    Self.dedupedBranchCandidates(candidates)
                )
            }.value
            return Self.fanOutMatches(matches, across: candidates)
        } catch {
            owner.handleGitHubBackendError(error, operation: "findRecentPRsForBranches(github)")
            return nil
        }
    }

    /// GitLab equivalent: route through the GitLab `CodeBackend` for the given host.
    private func fetchGitLabMRsForReconcile(
        candidates: [ReconcileCandidate],
        host: String
    ) async -> [ReconcileBranchMatch] {
        guard !candidates.isEmpty else { return [] }
        let backend = providerManager.codeBackend(for: .gitlab, host: host)!
        do {
            let matches = try await Task.detached {
                try await backend.findRecentPRsForBranches(
                    Self.dedupedBranchCandidates(candidates)
                )
            }.value
            return Self.fanOutMatches(matches, across: candidates)
        } catch {
            print("[IssueTracker] Reconcile via backend failed for host \(host): \(error.localizedDescription.prefix(200))")
            return []
        }
    }

    /// Project `ReconcileCandidate`s onto the de-duplicated `(repoSlug, branch)`
    /// pairs the backend needs. Two sessions on the same branch (a duplicated
    /// session, or reconcile firing before the first session's PR link lands)
    /// produce a single backend query — we fan the matches back out per
    /// session in `fanOutMatches`.
    nonisolated static func dedupedBranchCandidates(_ candidates: [ReconcileCandidate]) -> [BranchCandidate] {
        var seen: Set<BranchCandidate> = []
        var out: [BranchCandidate] = []
        for c in candidates {
            let bc = BranchCandidate(repoSlug: c.repoSlug, branch: c.branch)
            if seen.insert(bc).inserted { out.append(bc) }
        }
        return out
    }

    /// Each backend `BranchPRMatch` is duplicated for every `ReconcileCandidate`
    /// that shares its `(repoSlug, branch)`. This preserves the prior
    /// per-session sessionID-threading even when two sessions point at the
    /// same branch — collapsing them via `Dictionary(uniqueKeysWithValues:)`
    /// would either trap or silently drop one session's PR link.
    nonisolated static func fanOutMatches(
        _ matches: [BranchPRMatch],
        across candidates: [ReconcileCandidate]
    ) -> [ReconcileBranchMatch] {
        // Group sessions by their (repoSlug, branch) so a single match maps
        // to every session that owns that key.
        var sessionsByBranch: [BranchCandidate: [UUID]] = [:]
        for c in candidates {
            let bc = BranchCandidate(repoSlug: c.repoSlug, branch: c.branch)
            sessionsByBranch[bc, default: []].append(c.sessionID)
        }
        var out: [ReconcileBranchMatch] = []
        for match in matches {
            guard let sids = sessionsByBranch[match.candidate] else { continue }
            for sid in sids {
                out.append(ReconcileBranchMatch(
                    sessionID: sid,
                    number: match.number,
                    url: match.url,
                    state: match.state,
                    updatedAt: match.updatedAt
                ))
            }
        }
        return out
    }

    /// Persist the reconciliation decisions. Re-checks `appState.links` at
    /// write time so a concurrent `applySessionPRLinks` or hand-added PR link
    /// (identified by URL match) wins without leaving a duplicate row.
    private func applyReconciledPRLinks(_ picks: [ReconcileBranchMatch]) {
        guard !picks.isEmpty else { return }
        // Accumulate then persist once — see `applySessionPRLinks` (#304).
        var newLinks: [SessionLink] = []
        for pick in picks {
            let existing = appState.links(for: pick.sessionID)
            if existing.contains(where: { $0.linkType == .pr || $0.url == pick.url }) { continue }
            let link = SessionLink(
                sessionID: pick.sessionID,
                label: "PR #\(pick.number)",
                url: pick.url,
                linkType: .pr
            )
            appState.links[pick.sessionID, default: []].append(link)
            newLinks.append(link)
        }

        guard !newLinks.isEmpty else { return }
        // Route through the shared, injected `store` — never a throwaway
        // `JSONStore()`. A fresh instance reads its own (possibly stale) disk
        // snapshot and its full-store write can silently clobber a session
        // another writer just added (#728).
        store.mutate { data in
            data.links.append(contentsOf: newLinks)
        }
    }

    /// Resolve the org/repo slug (e.g. "corveil/citadel") from a worktree's git remote.
    private func resolveRepoSlug(worktree: SessionWorktree) -> String {
        return resolveRepoInfo(worktree: worktree).slug
    }

    /// Info derived from a worktree's git remote URL: org/repo slug and (for
    /// GitLab) the host name. Host is empty for github.com remotes.
    struct RepoInfo: Sendable, Equatable {
        let slug: String
        let host: String
    }

    private func resolveRepoInfo(worktree: SessionWorktree) -> RepoInfo {
        if let output = try? shellSync(
            "git", "-C", worktree.repoPath, "remote", "get-url", "origin"
        ) {
            var url = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
            let host = Self.extractHost(fromRemote: url)
            let slug = Self.extractSlug(fromRemote: url)
            if !slug.isEmpty {
                return RepoInfo(slug: slug, host: host)
            }
        }
        if worktree.repoName.contains("/") {
            return RepoInfo(slug: worktree.repoName, host: "")
        }
        return RepoInfo(slug: "", host: "")
    }

    /// Extract the host ("github.com", "gitlab.example.com") from a git remote URL.
    /// Handles both SSH (`git@host:org/repo`) and HTTPS (`https://host/org/repo`).
    /// Returns "" when the URL can't be parsed.
    nonisolated static func extractHost(fromRemote url: String) -> String {
        // SSH: git@host:org/repo
        if let range = url.range(of: #"^[^@]+@([^:]+):"#, options: .regularExpression) {
            let match = String(url[range])
            if let at = match.firstIndex(of: "@"), let colon = match.lastIndex(of: ":") {
                return String(match[match.index(after: at)..<colon])
            }
        }
        // HTTPS: https://host/...
        if let range = url.range(of: #"^https?://([^/]+)/"#, options: .regularExpression) {
            let match = String(url[range])
            let trimmed = match
                .replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return ""
    }

    /// Extract the project slug ("org/repo", "group/sub/repo", ...) from a git
    /// remote URL. Handles both SSH (`git@host:path`) and HTTPS
    /// (`https://host/path`), and preserves nested-group paths so that GitLab
    /// projects under nested groups (e.g.
    /// `big-bang/product/packages/elasticsearch-kibana`) keep their full path.
    /// Strips a trailing `.git` if present. Returns "" when the URL can't be
    /// parsed.
    nonisolated static func extractSlug(fromRemote url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".git") { trimmed = String(trimmed.dropLast(4)) }

        // SSH: git@host:org/repo or user@host:group/sub/repo
        if let range = trimmed.range(of: #"^[^@/\s]+@[^:/\s]+:"#, options: .regularExpression) {
            let path = String(trimmed[range.upperBound...])
            return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        // HTTPS: https://host/org/repo
        if let range = trimmed.range(of: #"^https?://[^/]+/"#, options: .regularExpression) {
            let path = String(trimmed[range.upperBound...])
            return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return ""
    }

    /// Parse the `owner/repo` (or `group/sub/repo`) slug from a PR/MR *web* URL
    /// such as `https://github.com/owner/repo/pull/123` or
    /// `https://gitlab.com/group/sub/repo/-/merge_requests/12`. Returns the path
    /// segments before the `pull` / `merge_requests` / `-` marker, or "" when the
    /// URL can't be parsed. Distinct from `extractSlug(fromRemote:)`, which
    /// parses git *remote* URLs (no `/pull/...` suffix).
    nonisolated static func repoSlug(fromPRURL url: String) -> String {
        repoSlug(fromWebURL: url, stoppingAt: ["pull", "merge_requests", "-"])
    }

    /// Parse a **github.com** PR web URL into its `owner/repo` slug, PR number,
    /// and any trailing path/query/fragment. Returns nil for a non-github.com
    /// host or a URL that isn't `.../owner/repo/pull/<number>` — enterprise and
    /// GitLab hosts are out of scope for redirect canonicalization (CROW-1268),
    /// whose REST redirect-follow is github.com-specific. Pure; unit-tested.
    nonisolated static func parseGitHubPRURL(_ url: String) -> (slug: String, number: Int, tail: String)? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(
            of: #"^https?://github\.com/"#, options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let path = String(trimmed[range.upperBound...])
        let segs = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segs.count >= 4, segs[2].lowercased() == "pull" else { return nil }
        let owner = segs[0], repo = segs[1]
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        // segs[3] is "<number>" possibly with a trailing "?query"/"#fragment".
        let digits = segs[3].prefix { $0.isNumber }
        guard let number = Int(digits), number > 0 else { return nil }
        var tail = String(segs[3].dropFirst(digits.count))
        let rest = segs.dropFirst(4)
        if !rest.isEmpty { tail += "/" + rest.joined(separator: "/") }
        return (slug: "\(owner)/\(repo)", number: number, tail: tail)
    }

    /// Rewrite a github.com PR URL to its canonical `owner/repo`, or nil when no
    /// rewrite is warranted — the URL isn't a github.com PR URL, its slug can't
    /// be resolved, or it is already canonical (case-insensitively). `resolveSlug`
    /// maps a **lowercased** "owner/repo" to its canonical "owner/repo" (the
    /// redirect resolution, supplied by the caller so this stays pure and
    /// network-free for tests). The PR number and any trailing path are
    /// preserved (CROW-1268).
    nonisolated static func canonicalizedPRURL(
        _ url: String, resolveSlug: (String) -> String?
    ) -> String? {
        guard let parsed = parseGitHubPRURL(url) else { return nil }
        guard let canonical = resolveSlug(parsed.slug.lowercased()),
              !canonical.isEmpty,
              canonical.split(separator: "/").count == 2,
              canonical.caseInsensitiveCompare(parsed.slug) != .orderedSame else { return nil }
        return "https://github.com/\(canonical)/pull/\(parsed.number)\(parsed.tail)"
    }

    /// Same as `repoSlug(fromPRURL:)` but also stops at `issues`, so a GitHub
    /// ticket URL (`https://github.com/owner/repo/issues/473`) yields `owner/repo`
    /// without needing a worktree remote (CROW-1221).
    nonisolated static func repoSlug(fromTicketURL url: String) -> String {
        repoSlug(fromWebURL: url, stoppingAt: ["pull", "merge_requests", "-", "issues"])
    }

    private nonisolated static func repoSlug(fromWebURL url: String, stoppingAt markers: Set<String>) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: #"^https?://[^/]+/"#, options: .regularExpression) else {
            return ""
        }
        let path = String(trimmed[range.upperBound...])
        var segments: [String] = []
        for segment in path.split(separator: "/").map(String.init) {
            if markers.contains(segment) { break }
            segments.append(segment)
        }
        return segments.joined(separator: "/")
    }

    private func shellSync(_ args: String...) throws -> String {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = ShellEnvironment.shared.env
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let stderr = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cmd = args.joined(separator: " ")
            let desc = "`\(cmd)` exited \(process.terminationStatus)"
                + (stderr.isEmpty ? "" : ": \(stderr)")
            throw NSError(
                domain: "IssueTracker",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: desc]
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

// MARK: - IssueTracker compatibility surface (CROW-1094)
//
// Preserves the `IssueTracker.<symbol>` spelling used by existing tests and
// cross-module callers (AppState capability resolvers, RPCHandlers,
// `addMergeLabel`'s repoSlug parse). All logic lives on `PRLinkReconciler`.
extension IssueTracker {
    typealias ReconcileCandidate = PRLinkReconciler.ReconcileCandidate
    typealias ReconcileKeyCandidate = PRLinkReconciler.ReconcileKeyCandidate
    typealias ReconcileBranchMatch = PRLinkReconciler.ReconcileBranchMatch

    nonisolated static func decideReconcileLinks(
        matches: [ReconcileBranchMatch]
    ) -> [ReconcileBranchMatch] {
        PRLinkReconciler.decideReconcileLinks(matches: matches)
    }

    nonisolated static func dedupeContestedPRs(
        _ picks: [ReconcileBranchMatch],
        identityBySession: [UUID: String]
    ) -> [ReconcileBranchMatch] {
        PRLinkReconciler.dedupeContestedPRs(picks, identityBySession: identityBySession)
    }

    nonisolated static func resolveReconcileProvider(
        codeProvider: Provider?, provider: Provider?, host: String
    ) -> (provider: Provider, gitlabHost: String?) {
        PRLinkReconciler.resolveReconcileProvider(
            codeProvider: codeProvider, provider: provider, host: host)
    }

    nonisolated static func dedupedKeyCandidates(_ candidates: [ReconcileKeyCandidate]) -> [KeyCandidate] {
        PRLinkReconciler.dedupedKeyCandidates(candidates)
    }

    nonisolated static func fanOutKeyMatches(
        _ matches: [KeyPRMatch],
        across candidates: [ReconcileKeyCandidate]
    ) -> [ReconcileBranchMatch] {
        PRLinkReconciler.fanOutKeyMatches(matches, across: candidates)
    }

    nonisolated static func dedupedBranchCandidates(_ candidates: [ReconcileCandidate]) -> [BranchCandidate] {
        PRLinkReconciler.dedupedBranchCandidates(candidates)
    }

    nonisolated static func fanOutMatches(
        _ matches: [BranchPRMatch],
        across candidates: [ReconcileCandidate]
    ) -> [ReconcileBranchMatch] {
        PRLinkReconciler.fanOutMatches(matches, across: candidates)
    }

    nonisolated static func extractHost(fromRemote url: String) -> String {
        PRLinkReconciler.extractHost(fromRemote: url)
    }

    nonisolated static func extractSlug(fromRemote url: String) -> String {
        PRLinkReconciler.extractSlug(fromRemote: url)
    }

    nonisolated static func repoSlug(fromPRURL url: String) -> String {
        PRLinkReconciler.repoSlug(fromPRURL: url)
    }

    nonisolated static func repoSlug(fromTicketURL url: String) -> String {
        PRLinkReconciler.repoSlug(fromTicketURL: url)
    }

    nonisolated static func githubIssueKeyCandidate(
        sessionID: UUID,
        ticketURL: String?,
        ticketNumber: Int?,
        provider: Provider?,
        codeProvider: Provider?,
        worktreeSlug: String,
        worktreeHost: String
    ) -> ReconcileKeyCandidate? {
        PRLinkReconciler.githubIssueKeyCandidate(
            sessionID: sessionID,
            ticketURL: ticketURL,
            ticketNumber: ticketNumber,
            provider: provider,
            codeProvider: codeProvider,
            worktreeSlug: worktreeSlug,
            worktreeHost: worktreeHost
        )
    }

    nonisolated static func githubIssueNumber(ticketURL: String?, ticketNumber: Int?) -> Int? {
        PRLinkReconciler.githubIssueNumber(ticketURL: ticketURL, ticketNumber: ticketNumber)
    }

    public nonisolated static func canAddMergeLabel(session: Session, providerManager: ProviderManager) -> Bool {
        PRLinkReconciler.canAddMergeLabel(session: session, providerManager: providerManager)
    }

    public nonisolated static func canSetProjectStatus(session: Session, providerManager: ProviderManager) -> Bool {
        PRLinkReconciler.canSetProjectStatus(session: session, providerManager: providerManager)
    }

    public func canSetProjectStatus(for session: Session) -> Bool {
        reconciler.canSetProjectStatus(for: session)
    }
}
