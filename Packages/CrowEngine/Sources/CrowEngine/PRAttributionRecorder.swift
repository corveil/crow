import Foundation
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider

/// PR→session attribution and the #694 rework/merge-rate signals, extracted
/// from `IssueTracker` (CROW-1094). Records the Crow-Session trailer mapping,
/// captures changed files for fresh merges, and stamps reverts / post-merge
/// fixes. Persists through the shared, injected `JSONStore` (ADR 0012 / #728)
/// and refreshes the read-only `appState.prAttributions` mirror after every
/// write. Pure decision helpers stay `nonisolated static` for unit testing.
@MainActor
final class PRAttributionRecorder {
    private unowned let owner: IssueTracker
    private var appState: AppState { owner.appState }
    private var providerManager: ProviderManager { owner.providerManager }
    private var store: JSONStore { owner.store }

    /// Local alias mirroring `IssueTracker.ViewerPR` (both are `PRRecord`).
    typealias ViewerPR = PRRecord

    /// Last time the default-branch revert scan ran (#694). In-memory: a
    /// restart re-scans, which the per-target dedupe makes harmless.
    var lastRevertScanAt: Date?

    /// PR URLs whose changed-files fetch has been attempted this process
    /// (#694). Guards against re-hitting the API every poll when the fetch
    /// fails; a restart retries, which is the desired recovery path.
    var changedFilesFetchAttempted: Set<String> = []

    init(owner: IssueTracker) { self.owner = owner }

    /// Merge freshly parsed trailer UUIDs into the PR's attribution record
    /// (#693). Returns the record to persist, or nil when no write is
    /// needed: no trailers and no existing record, or nothing material
    /// changed since the last capture. `sessionIDs` is a monotonic ordered
    /// union — IDs observed once are never dropped, even if a rebase removes
    /// the commit that carried them. All parsed UUIDs are kept, known
    /// session or not; the auto-merge gate's known-session filter is a
    /// separate concern (`crowAuthored`). Pure so unit tests can exercise
    /// the merge without spinning up an `IssueTracker`.
    ///
    /// #694 additions: `parsedCommitSHAs` (branch commit SHAs from the same
    /// fetch that produced the trailers) union into `commitSHAs` — same
    /// monotonic semantics as `sessionIDs`, capped at `maxStoredCommitSHAs`;
    /// `mergeCommitSHA` and `closedAt` are stamped once, at the first
    /// MERGED/CLOSED observation, mirroring `mergedAt`.
    nonisolated static func capturedAttribution(
        existing: PRSessionAttribution?,
        pr: ViewerPR,
        parsedSessionIDs: [UUID],
        parsedCommitSHAs: [String] = [],
        now: Date
    ) -> PRSessionAttribution? {
        guard var attribution = existing else {
            guard !parsedSessionIDs.isEmpty else { return nil }
            var deduped: [UUID] = []
            for id in parsedSessionIDs where !deduped.contains(id) { deduped.append(id) }
            var dedupedSHAs: [String] = []
            for sha in parsedCommitSHAs where !sha.isEmpty && !dedupedSHAs.contains(sha) {
                guard dedupedSHAs.count < maxStoredCommitSHAs else { break }
                dedupedSHAs.append(sha)
            }
            return PRSessionAttribution(
                prURL: pr.url,
                repoNameWithOwner: pr.repoNameWithOwner,
                prNumber: pr.number,
                sessionIDs: deduped,
                state: pr.state,
                mergedAt: pr.state == "MERGED" ? now : nil,
                firstSeenAt: now,
                updatedAt: now,
                commitSHAs: dedupedSHAs.isEmpty ? nil : dedupedSHAs,
                mergeCommitSHA: pr.state == "MERGED" ? pr.mergeCommitOid : nil,
                closedAt: pr.state == "CLOSED" ? now : nil
            )
        }
        for id in parsedSessionIDs where !attribution.sessionIDs.contains(id) {
            attribution.sessionIDs.append(id)
        }
        var shas = attribution.commitSHAs ?? []
        for sha in parsedCommitSHAs where !sha.isEmpty && !shas.contains(sha) {
            guard shas.count < maxStoredCommitSHAs else { break }
            shas.append(sha)
        }
        attribution.commitSHAs = shas.isEmpty ? nil : shas
        attribution.state = pr.state
        if pr.state == "MERGED" && attribution.mergedAt == nil {
            attribution.mergedAt = now
        }
        if pr.state == "MERGED" && attribution.mergeCommitSHA == nil {
            attribution.mergeCommitSHA = pr.mergeCommitOid
        }
        if pr.state == "CLOSED" && attribution.closedAt == nil {
            attribution.closedAt = now
        }
        guard attribution.sessionIDs != existing?.sessionIDs
            || attribution.state != existing?.state
            || attribution.mergedAt != existing?.mergedAt
            || attribution.commitSHAs != existing?.commitSHAs
            || attribution.mergeCommitSHA != existing?.mergeCommitSHA
            || attribution.closedAt != existing?.closedAt else { return nil }
        attribution.updatedAt = now
        return attribution
    }

    /// Refresh the state of already-attributed PRs from a polled PR list
    /// (#693). Returns only the entries that changed; `mergedAt` is stamped
    /// once, at the first MERGED observation, and never moved. Never creates
    /// entries — attribution requires a trailer parse, which happens in
    /// `recordPRAttribution`. Pure for testability.
    nonisolated static func attributionStateUpdates(
        existing: [String: PRSessionAttribution],
        prs: [ViewerPR],
        now: Date
    ) -> [String: PRSessionAttribution] {
        var updates: [String: PRSessionAttribution] = [:]
        for pr in prs {
            guard let updated = capturedAttribution(
                existing: existing[pr.url], pr: pr, parsedSessionIDs: [], now: now
            ) else { continue }
            updates[pr.url] = updated
        }
        return updates
    }

    /// Resync the read-only AppState mirror after a `prAttributions`
    /// mutation, so the scorecard's v2 combined score (#699) sees the write.
    private func syncPRAttributionMirror() {
        appState.prAttributions = store.data.prAttributions ?? [:]
    }

    /// Persist the PR→session mapping parsed from the PR's commits (#693).
    /// Called from `prHasCrowAuthoredCommit` so attribution rides along with
    /// the existing trailer parse; the gate's boolean result is unaffected.
    /// #694: also unions the commit SHAs into the record (revert-detection
    /// targets) and scans the same commit messages for reverts of *other*
    /// attributed PRs in the same repo — a revert PR entering the auto-merge
    /// flow is the cheapest place to observe one.
    func recordPRAttribution(pr: ViewerPR, commits: [CommitInfo], now: Date = Date()) {
        let parsed = commits.flatMap { IssueTracker.extractCrowSessionUUIDs(from: $0.message) }
        let existingAll = store.data.prAttributions ?? [:]
        let attribution = Self.capturedAttribution(
            existing: existingAll[pr.url],
            pr: pr,
            parsedSessionIDs: parsed,
            parsedCommitSHAs: commits.map(\.sha),
            now: now
        )
        let revertUpdates = Self.revertDetections(
            commits: commits,
            attributions: existingAll,
            repo: pr.repoNameWithOwner,
            excludingPRURL: pr.url,
            sourcePRURL: pr.url,
            now: now
        )
        guard attribution != nil || !revertUpdates.isEmpty else { return }
        store.mutate { data in
            var attributions = data.prAttributions ?? [:]
            if let attribution { attributions[pr.url] = attribution }
            for (url, records) in revertUpdates {
                guard var target = attributions[url] else { continue }
                target.reverts = (target.reverts ?? []) + records
                target.updatedAt = now
                attributions[url] = target
            }
            data.prAttributions = attributions
        }
        syncPRAttributionMirror()
    }

    /// Update stored attribution state from a refresh cycle's PR list
    /// (#693). Once merged, a PR leaves the auto-merge/rebase flow (the
    /// only place commits are fetched), so state transitions — and the
    /// observed merge timestamp — are recorded here instead.
    func updatePRAttributions(viewerPRs: [ViewerPR], now: Date = Date()) {
        let existing = store.data.prAttributions ?? [:]
        guard !existing.isEmpty else { return }
        let updates = Self.attributionStateUpdates(existing: existing, prs: viewerPRs, now: now)
        guard !updates.isEmpty else { return }
        store.mutate { data in
            var attributions = data.prAttributions ?? [:]
            for (url, attribution) in updates { attributions[url] = attribution }
            data.prAttributions = attributions
        }
        syncPRAttributionMirror()
    }

    // MARK: - Rework / merge-rate metrics (#694, ADR 0008 follow-up 6)

    /// Max age of a fix PR's merge relative to the fixed PR's merge for the
    /// fix to count as post-merge rework. 48h: long enough to catch the
    /// "shipped Friday, hotfixed Monday" pattern the signal exists for,
    /// short enough that routine follow-on work in a hot file doesn't read
    /// as rework. Tunable prior per the ADR's calibration rule.
    nonisolated static let postMergeFixWindow: TimeInterval = 48 * 3600

    /// Minimum gap between default-branch revert scans. The scan is one
    /// REST call per repo with recent attributed merges; 30 min keeps that
    /// negligible next to the 60s poll while still surfacing reverts the
    /// same half-hour they land.
    nonisolated static let revertScanInterval: TimeInterval = 30 * 60

    /// How far back a merged attribution keeps its repo in the revert scan,
    /// and the `since` horizon of each scan. Reverts of two-week-old merges
    /// are vanishingly rare, and the scan is single-page — a longer horizon
    /// would silently truncate on busy repos rather than see more.
    nonisolated static let revertScanLookback: TimeInterval = 14 * 24 * 3600

    /// Cap on stored branch commit SHAs per attribution (`commitSHAs`).
    nonisolated static let maxStoredCommitSHAs = 100

    /// Cap on stored changed-file paths per attribution (`changedFiles`).
    nonisolated static let maxStoredChangedFiles = 200

    /// Shortest SHA prefix accepted by `shaMatches` — git's abbreviated-SHA
    /// convention. Anything shorter is too collision-prone to stamp rework on.
    nonisolated static let revertSHAMinPrefixLength = 7

    /// Pattern matching git's conventional revert body line. Anchored to
    /// line start (multiline) like the Crow-Session trailer pattern; the
    /// captured group is the reverted commit's (possibly abbreviated) SHA.
    /// GitHub's Revert button and `git revert` both emit this line; the
    /// trailing `\b` tolerates GitHub's closing period.
    nonisolated private static let revertLinePattern = #"^This reverts commit ([0-9A-Fa-f]{7,40})\b"#

    /// Extract every reverted-commit SHA from a commit message. Returns an
    /// empty array when no revert lines match. Pure for testability;
    /// compiles per call for the same Sendable reason as
    /// `extractCrowSessionUUIDs`.
    nonisolated static func extractRevertedCommitSHAs(from message: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: revertLinePattern,
            options: [.anchorsMatchLines]
        ) else { return [] }
        let range = NSRange(message.startIndex..., in: message)
        var result: [String] = []
        regex.enumerateMatches(in: message, range: range) { match, _, _ in
            guard let m = match,
                  let shaRange = Range(m.range(at: 1), in: message) else { return }
            result.append(String(message[shaRange]))
        }
        return result
    }

    /// Case-insensitive abbreviated-SHA comparison: true when either value
    /// is a prefix of the other and the shorter is at least
    /// `revertSHAMinPrefixLength` chars. Revert messages may carry either
    /// the full or an abbreviated SHA depending on how they were authored.
    nonisolated static func shaMatches(_ a: String, _ b: String) -> Bool {
        guard min(a.count, b.count) >= revertSHAMinPrefixLength else { return false }
        let la = a.lowercased(), lb = b.lowercased()
        return la.hasPrefix(lb) || lb.hasPrefix(la)
    }

    /// All SHAs a revert of `attribution` could name: the merge/squash
    /// commit (Crow's own merges are squashes, so this is the primary
    /// target) plus the branch commits (merge-commit/rebase strategies).
    nonisolated private static func revertTargets(of attribution: PRSessionAttribution) -> [String] {
        var targets = attribution.commitSHAs ?? []
        if let mergeSHA = attribution.mergeCommitSHA { targets.append(mergeSHA) }
        return targets
    }

    /// Scan `commits` for conventional revert lines naming a stored SHA of
    /// a same-repo attribution, and return the new `PRRevertRecord`s to
    /// append, keyed by the reverted attribution's PR URL. Pure; callers
    /// persist. Dedupe: a target attribution gains at most one record per
    /// `revertedCommitSHA` (prefix-tolerant), across both its existing
    /// records and this batch — so a revert observed first via its PR's
    /// commit fetch and again via the default-branch scan stamps once.
    /// Skips:
    /// - `excludingPRURL` (a PR's own commit fetch never reverts itself);
    /// - self-reverts: the reverting commit is one of the target's own SHAs
    ///   (an in-PR revert of an in-PR commit is internal churn, not rework).
    nonisolated static func revertDetections(
        commits: [CommitInfo],
        attributions: [String: PRSessionAttribution],
        repo: String,
        excludingPRURL: String?,
        sourcePRURL: String?,
        now: Date
    ) -> [String: [PRRevertRecord]] {
        var updates: [String: [PRRevertRecord]] = [:]
        for commit in commits {
            let targets = extractRevertedCommitSHAs(from: commit.message)
            guard !targets.isEmpty else { continue }
            for (url, attribution) in attributions {
                guard attribution.repoNameWithOwner == repo, url != excludingPRURL else { continue }
                let ownSHAs = revertTargets(of: attribution)
                // Self-revert guard: the reverting commit belongs to the
                // attribution it would be stamped on.
                guard !commit.sha.isEmpty,
                      !ownSHAs.contains(where: { shaMatches($0, commit.sha) }) else { continue }
                for target in targets {
                    guard ownSHAs.contains(where: { shaMatches($0, target) }) else { continue }
                    let already = (attribution.reverts ?? []) + (updates[url] ?? [])
                    guard !already.contains(where: { shaMatches($0.revertedCommitSHA, target) }) else { continue }
                    updates[url, default: []].append(PRRevertRecord(
                        revertedCommitSHA: target,
                        revertCommitSHA: commit.sha,
                        sourcePRURL: sourcePRURL,
                        detectedAt: now
                    ))
                }
            }
        }
        return updates
    }

    /// Detect post-merge fixes across the attribution store and return the
    /// new `PostMergeFixRecord`s to append, keyed by the *fixed* PR's URL.
    /// Pure; callers persist. The heuristic is documented on
    /// `PostMergeFixRecord`; in short — fix PR B stamps merged PR A when B
    /// is same-repo, first seen after A merged, itself merged within
    /// `postMergeFixWindow`, shares a changed file with A, and is not A's
    /// revert. Records dedupe by `fixPRURL`.
    nonisolated static func postMergeFixDetections(
        attributions: [String: PRSessionAttribution],
        now: Date
    ) -> [String: [PostMergeFixRecord]] {
        var updates: [String: [PostMergeFixRecord]] = [:]
        for (urlA, a) in attributions {
            guard a.state == "MERGED", let aMergedAt = a.mergedAt,
                  let aFiles = a.changedFiles, !aFiles.isEmpty else { continue }
            let aFileSet = Set(aFiles)
            let aRevertSHAs = (a.reverts ?? []).map(\.revertCommitSHA)
            for (urlB, b) in attributions {
                guard urlB != urlA, b.repoNameWithOwner == a.repoNameWithOwner else { continue }
                guard b.firstSeenAt > aMergedAt else { continue }
                guard let bMergedAt = b.mergedAt,
                      bMergedAt.timeIntervalSince(aMergedAt) <= postMergeFixWindow else { continue }
                guard let bFiles = b.changedFiles else { continue }
                let overlap = aFileSet.intersection(bFiles).count
                guard overlap > 0 else { continue }
                // A revert counts exactly once, as a revert — never also as
                // a post-merge fix. Revert stamping runs before this pass.
                let isRevertOfA = (a.reverts ?? []).contains { $0.sourcePRURL == urlB }
                    || revertTargets(of: b).contains { bSHA in
                        aRevertSHAs.contains { shaMatches($0, bSHA) }
                    }
                guard !isRevertOfA else { continue }
                guard !(a.postMergeFixes ?? []).contains(where: { $0.fixPRURL == urlB }) else { continue }
                updates[urlA, default: []].append(PostMergeFixRecord(
                    fixPRURL: urlB,
                    overlappingFileCount: overlap,
                    detectedAt: now
                ))
            }
        }
        return updates
    }

    /// Fetch and store changed-file paths for attributed PRs newly observed
    /// as MERGED (#694). One REST call per PR, once per process (the
    /// `changedFilesFetchAttempted` guard) — a merge is a rare event, and a
    /// failed fetch retries on the next launch rather than every poll.
    /// GitHub-hosted PRs only; other providers' backends return `[]` and
    /// aren't worth the call. Merges older than `revertScanLookback` are
    /// skipped: backfilling files for ancient merges would let the fix
    /// detector stamp long-settled PR pairs with a fresh `detectedAt`,
    /// polluting the current window.
    func captureChangedFilesForNewMerges(now: Date = Date()) async {
        let attributions = store.data.prAttributions ?? [:]
        let cutoff = now.addingTimeInterval(-Self.revertScanLookback)
        let pending = attributions.values.filter { attribution in
            attribution.state == "MERGED"
                && attribution.changedFiles == nil
                && (attribution.mergedAt ?? .distantPast) >= cutoff
                && !changedFilesFetchAttempted.contains(attribution.prURL)
                && URL(string: attribution.prURL)?.host == "github.com"
        }
        guard !pending.isEmpty,
              let backend = providerManager.codeBackend(for: .github) else { return }
        for attribution in pending {
            changedFilesFetchAttempted.insert(attribution.prURL)
            let files: [String]
            do {
                files = try await backend.fetchPRChangedFiles(
                    repoSlug: attribution.repoNameWithOwner,
                    prNumber: attribution.prNumber
                )
            } catch {
                CrowLog.info("[Crow] fetchPRChangedFiles failed for \(attribution.prURL): \(error.localizedDescription)")
                continue
            }
            guard !files.isEmpty else { continue }
            let capped = Array(files.prefix(Self.maxStoredChangedFiles))
            let now = Date()
            store.mutate { data in
                var attributions = data.prAttributions ?? [:]
                guard var target = attributions[attribution.prURL],
                      target.changedFiles == nil else { return }
                target.changedFiles = capped
                target.updatedAt = now
                attributions[attribution.prURL] = target
                data.prAttributions = attributions
            }
            syncPRAttributionMirror()
        }
    }

    /// Scan the default branch of every repo with a recently merged
    /// attribution for revert commits (#694). Catches reverts that never
    /// pass through Crow's PR flow — direct pushes and reverts merged by
    /// others. Throttled to `revertScanInterval`; single page of recent
    /// commits per repo, idempotent via the detections dedupe.
    func scanDefaultBranchesForReverts(now: Date = Date()) async {
        if let last = lastRevertScanAt, now.timeIntervalSince(last) < Self.revertScanInterval { return }
        lastRevertScanAt = now
        let attributions = store.data.prAttributions ?? [:]
        let since = now.addingTimeInterval(-Self.revertScanLookback)
        let repos = Set(attributions.values
            .filter { attribution in
                guard let mergedAt = attribution.mergedAt, mergedAt >= since else { return false }
                return URL(string: attribution.prURL)?.host == "github.com"
            }
            .map(\.repoNameWithOwner))
        guard !repos.isEmpty,
              let backend = providerManager.codeBackend(for: .github) else { return }
        for repo in repos.sorted() {
            let commits: [CommitInfo]
            do {
                commits = try await backend.fetchRecentDefaultBranchCommits(repoSlug: repo, since: since)
            } catch {
                CrowLog.info("[Crow] fetchRecentDefaultBranchCommits failed for \(repo): \(error.localizedDescription)")
                continue
            }
            // Re-read inside the loop so a prior repo's writes are visible.
            let current = store.data.prAttributions ?? [:]
            let updates = Self.revertDetections(
                commits: commits,
                attributions: current,
                repo: repo,
                excludingPRURL: nil,
                sourcePRURL: nil,
                now: now
            )
            guard !updates.isEmpty else { continue }
            store.mutate { data in
                var attributions = data.prAttributions ?? [:]
                for (url, records) in updates {
                    guard var target = attributions[url] else { continue }
                    target.reverts = (target.reverts ?? []) + records
                    target.updatedAt = now
                    attributions[url] = target
                }
                data.prAttributions = attributions
            }
            syncPRAttributionMirror()
        }
    }

    /// Run post-merge-fix detection over the attribution store and persist
    /// new records (#694). Pure store pass — no API calls; runs after
    /// revert stamping each refresh so rule 4 (a revert is never also a
    /// fix) sees the freshest revert records.
    func detectPostMergeFixes(now: Date = Date()) {
        let attributions = store.data.prAttributions ?? [:]
        guard !attributions.isEmpty else { return }
        let updates = Self.postMergeFixDetections(attributions: attributions, now: now)
        guard !updates.isEmpty else { return }
        store.mutate { data in
            var attributions = data.prAttributions ?? [:]
            for (url, records) in updates {
                guard var target = attributions[url] else { continue }
                target.postMergeFixes = (target.postMergeFixes ?? []) + records
                target.updatedAt = now
                attributions[url] = target
            }
            data.prAttributions = attributions
        }
        syncPRAttributionMirror()
    }
}
