import Foundation
import CrowCore
import CrowPersistence
import CrowProvider

/// Daemon-side `crow:reviewing` label (CROW-1310).
///
/// The review clone runs untrusted PR code, so it never writes the label.
/// Every call here is best-effort: a missing triage/write permission is logged
/// and does not fail the review that triggered it. The toggle
/// (`reviewInProgressLabelEnabled`) defaults off; when it is off this service
/// does nothing.
///
/// `holds` covers the gap between retiring a round and the next round's
/// session existing — a re-review clone can take long enough for a board poll
/// to notice "no live session" and sweep the label the handoff just kept.
@MainActor
enum ReviewingLabelService {
    /// PR URLs whose label must survive a sweep because a review round is
    /// being created right now. Canonicalized.
    private static var holds: Set<String> = []

    static func hold(_ prURL: String) {
        holds.insert(ReviewingLabel.canonicalPRURL(prURL))
    }

    static func release(_ prURL: String) {
        holds.remove(ReviewingLabel.canonicalPRURL(prURL))
    }

    private static func isHeld(_ prURL: String) -> Bool {
        holds.contains(ReviewingLabel.canonicalPRURL(prURL))
    }

    /// Live review sessions plus in-flight creates. Completed and archived
    /// rounds are absent on purpose — those are what the sweep is for.
    static func protectedPRURLs(appState: AppState) -> Set<String> {
        var urls = holds
        for session in appState.sessions where session.kind == .review
            && (session.status == .active || session.status == .paused || session.status == .inReview) {
            if let url = appState.links(for: session.id).first(where: { $0.linkType == .pr })?.url {
                urls.insert(ReviewingLabel.canonicalPRURL(url))
            }
        }
        return urls
    }

    static func isEnabled() -> Bool {
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot) else { return false }
        return config.reviewInProgressLabelEnabled
    }

    /// Add the label after a review session exists. Never throws.
    static func addOnReviewStart(prURL: String, repo: String, backend: CodeBackend?, enabled: Bool? = nil) async {
        guard enabled ?? isEnabled() else { return }
        guard let backend, backend.capabilities.contains(.reviewInProgressLabel) else { return }
        do {
            try await backend.ensureReviewingLabel(repo: repo)
        } catch {
            // The label may already exist and `create` failed for another
            // reason. Still try the add; a real permission error fails there
            // too and is logged once.
            CrowLog.info("[ReviewingLabel] ensure \(ReviewingLabel.name) on \(repo): \(error.localizedDescription)")
        }
        do {
            try await backend.addReviewingLabel(prURL: prURL)
            CrowLog.info("[ReviewingLabel] added \(ReviewingLabel.name) to \(prURL)")
        } catch {
            CrowLog.info("[ReviewingLabel] could not add \(ReviewingLabel.name) to \(prURL): \(error.localizedDescription)")
        }
    }

    /// Remove the label when a review leaves the active set, and only if the
    /// viewer was the latest actor to add it. Never throws. `enabled` overrides
    /// the config read so tests don't need a dev root; callers that already
    /// checked `shouldClear` pass `true`.
    static func removeIfViewer(prURL: String, backend: CodeBackend?, enabled: Bool? = nil) async {
        guard enabled ?? isEnabled() else { return }
        guard let backend, backend.capabilities.contains(.reviewInProgressLabel) else { return }
        let actor: ReviewingLabelActor
        do {
            actor = try await backend.reviewingLabelActor(prURL: prURL)
        } catch {
            CrowLog.info("[ReviewingLabel] could not read who labeled \(prURL): \(error.localizedDescription)")
            return
        }
        guard actor.labelPresent else { return }
        guard ReviewingLabel.shouldRemove(latestActor: actor.latestActor, viewerLogin: actor.viewerLogin) else {
            CrowLog.info("[ReviewingLabel] keeping \(ReviewingLabel.name) on \(prURL); latest actor \(actor.latestActor ?? "none") is not \(actor.viewerLogin)")
            return
        }
        // A new round may have started while we were reading the timeline.
        // Removing now would clear the label that round is about to keep.
        guard !isHeld(prURL) else {
            CrowLog.info("[ReviewingLabel] keeping \(ReviewingLabel.name) on \(prURL); a review round is in flight")
            return
        }
        do {
            try await backend.removeReviewingLabel(prURL: prURL)
            CrowLog.info("[ReviewingLabel] removed \(ReviewingLabel.name) from \(prURL)")
        } catch {
            CrowLog.info("[ReviewingLabel] could not remove \(ReviewingLabel.name) from \(prURL): \(error.localizedDescription)")
        }
    }

    /// Drop labels the viewer added on PRs with no live review session.
    /// Never throws.
    static func sweep(livePRURLs: Set<String>, backend: CodeBackend?, enabled: Bool? = nil) async {
        guard enabled ?? isEnabled() else { return }
        guard let backend, backend.capabilities.contains(.reviewInProgressLabel) else { return }
        let listing: ReviewingLabelListing
        do {
            listing = try await backend.listOpenReviewingLabels()
        } catch {
            CrowLog.info("[ReviewingLabel] stale sweep failed: \(error.localizedDescription)")
            return
        }
        let stale = ReviewingLabel.staleRemovals(
            candidates: listing.candidates,
            liveReviewPRURLs: livePRURLs,
            viewerLogin: listing.viewerLogin
        )
        for url in stale {
            guard !isHeld(url) else { continue }
            do {
                try await backend.removeReviewingLabel(prURL: url)
                CrowLog.info("[ReviewingLabel] swept \(ReviewingLabel.name) from \(url)")
            } catch {
                CrowLog.info("[ReviewingLabel] could not sweep \(ReviewingLabel.name) from \(url): \(error.localizedDescription)")
            }
        }
    }
}
