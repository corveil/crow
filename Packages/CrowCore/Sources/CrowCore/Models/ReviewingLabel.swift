import Foundation

/// The single `crow:reviewing` label Crow puts on a PR while one of its review
/// sessions is in progress (CROW-1310).
///
/// One label, not one per user. Who is reviewing is the actor on the latest
/// `LabeledEvent` for this label — a later add (by hand, or by another
/// reviewer's Crow) wins, and only that actor's Crow removes it. That is what
/// stops reviewer A from clearing the label while reviewer B is still reviewing.
///
/// The decisions here are pure. The daemon applies them; the review clone never
/// writes to the PR.
public enum ReviewingLabel {
    public static let name = "crow:reviewing"

    /// One `LabeledEvent` from a PR timeline. `createdAt` nil means the host
    /// didn't send a timestamp; callers still order those by their position.
    public struct Event: Sendable, Equatable {
        public var label: String
        public var actor: String?
        public var createdAt: Date?

        public init(label: String, actor: String?, createdAt: Date? = nil) {
            self.label = label
            self.actor = actor
            self.createdAt = createdAt
        }
    }

    /// A PR that currently carries the label, plus whoever last added it.
    public struct Candidate: Sendable, Equatable {
        public var url: String
        public var latestActor: String?

        public init(url: String, latestActor: String?) {
            self.url = url
            self.latestActor = latestActor
        }
    }

    /// Why a review session is leaving the active set. `.reReviewHandoff` is
    /// the one end that keeps the label: the next round starts immediately.
    public enum SessionEnd: Sendable, Equatable {
        case completed
        case deleted
        case reaped
        case reReviewHandoff
    }

    /// Login of the latest event that added `label`. Other labels are ignored.
    /// Equal timestamps keep the later event, which is the timeline order
    /// GitHub returns (`last:` is chronological).
    public static func latestActor(in events: [Event], label: String = name) -> String? {
        let matches = events.enumerated().filter {
            $0.element.label.caseInsensitiveCompare(label) == .orderedSame
        }
        guard let best = matches.max(by: { a, b in
            let ad = a.element.createdAt ?? .distantPast
            let bd = b.element.createdAt ?? .distantPast
            if ad != bd { return ad < bd }
            return a.offset < b.offset
        }) else { return nil }
        let actor = best.element.actor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return actor.isEmpty ? nil : actor
    }

    /// Remove only when the viewer is the latest actor who added the label.
    /// An unknown actor or an unknown viewer keeps the label — clearing it
    /// would guess, and the guess can erase someone else's in-progress review.
    public static func shouldRemove(latestActor: String?, viewerLogin: String) -> Bool {
        let viewer = viewerLogin.trimmingCharacters(in: .whitespacesAndNewlines)
        let actor = latestActor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !viewer.isEmpty, !actor.isEmpty else { return false }
        return actor.caseInsensitiveCompare(viewer) == .orderedSame
    }

    /// Whether this end of a review session should take the label off, before
    /// the actor check. The toggle gates every end. A re-review handoff does
    /// not: the new round starts in the same call, and removing first would
    /// flash the label off between rounds.
    public static func shouldClear(on end: SessionEnd, enabled: Bool) -> Bool {
        guard enabled else { return false }
        switch end {
        case .reReviewHandoff: return false
        case .completed, .deleted, .reaped: return true
        }
    }

    /// PRs whose `crow:reviewing` label the viewer added and that have no live
    /// review session. The returned URLs are the originals (what `gh` was
    /// given); matching against live sessions is case-insensitive and ignores
    /// a trailing slash.
    public static func staleRemovals(
        candidates: [Candidate],
        liveReviewPRURLs: Set<String>,
        viewerLogin: String
    ) -> [String] {
        let live = Set(liveReviewPRURLs.map(canonicalPRURL))
        var seen = Set<String>()
        var out: [String] = []
        for candidate in candidates {
            let key = canonicalPRURL(candidate.url)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            guard !live.contains(key) else { continue }
            guard shouldRemove(latestActor: candidate.latestActor, viewerLogin: viewerLogin) else { continue }
            out.append(candidate.url)
        }
        return out
    }

    /// Comparison key for a PR URL. Not a canonical GitHub form — just stable
    /// enough that a trailing slash or a case difference doesn't look like a
    /// different PR to the sweep.
    public static func canonicalPRURL(_ url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.lowercased()
    }
}
