import Foundation
import Testing
@testable import CrowCore

@Suite("ReviewingLabel")
struct ReviewingLabelTests {
    private let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_000_100)

    @Test func latestActorIgnoresOtherLabelsAndKeepsTheNewestAdd() {
        let events = [
            ReviewingLabel.Event(label: "crow:reviewing", actor: "ada", createdAt: earlier),
            ReviewingLabel.Event(label: "bug", actor: "ada", createdAt: later),
            ReviewingLabel.Event(label: "crow:reviewing", actor: "bob", createdAt: later),
        ]
        #expect(ReviewingLabel.latestActor(in: events) == "bob")
    }

    @Test func latestActorIsCaseInsensitiveOnTheLabelName() {
        let events = [
            ReviewingLabel.Event(label: "Crow:Reviewing", actor: "Ada", createdAt: earlier),
        ]
        #expect(ReviewingLabel.latestActor(in: events) == "Ada")
    }

    @Test func equalTimestampsKeepTheLaterTimelineEvent() {
        let events = [
            ReviewingLabel.Event(label: "crow:reviewing", actor: "ada", createdAt: earlier),
            ReviewingLabel.Event(label: "crow:reviewing", actor: "bob", createdAt: earlier),
        ]
        #expect(ReviewingLabel.latestActor(in: events) == "bob")
    }

    @Test func missingActorIsNotALogin() {
        let events = [
            ReviewingLabel.Event(label: "crow:reviewing", actor: "  ", createdAt: earlier),
        ]
        #expect(ReviewingLabel.latestActor(in: events) == nil)
    }

    @Test func shouldRemoveOnlyWhenTheViewerIsTheLatestActor() {
        #expect(ReviewingLabel.shouldRemove(latestActor: "ada", viewerLogin: "ada"))
        #expect(ReviewingLabel.shouldRemove(latestActor: "Ada", viewerLogin: "ada"))
        #expect(!ReviewingLabel.shouldRemove(latestActor: "bob", viewerLogin: "ada"))
        #expect(!ReviewingLabel.shouldRemove(latestActor: nil, viewerLogin: "ada"))
        #expect(!ReviewingLabel.shouldRemove(latestActor: "ada", viewerLogin: ""))
        #expect(!ReviewingLabel.shouldRemove(latestActor: "ada", viewerLogin: "  "))
    }

    @Test func reReviewHandoffKeepsTheLabel() {
        #expect(!ReviewingLabel.shouldClear(on: .reReviewHandoff, enabled: true))
        #expect(ReviewingLabel.shouldClear(on: .completed, enabled: true))
        #expect(ReviewingLabel.shouldClear(on: .deleted, enabled: true))
        #expect(ReviewingLabel.shouldClear(on: .reaped, enabled: true))
        #expect(!ReviewingLabel.shouldClear(on: .completed, enabled: false))
        #expect(!ReviewingLabel.shouldClear(on: .deleted, enabled: false))
        #expect(!ReviewingLabel.shouldClear(on: .reaped, enabled: false))
    }

    @Test func staleSweepRemovesOnlyTheViewersLabelsWithNoLiveSession() {
        let live = "https://github.com/acme/app/pull/1"
        let mine = "https://github.com/acme/app/pull/2"
        let theirs = "https://github.com/acme/app/pull/3"
        let held = "https://github.com/acme/app/pull/4/"
        let removed = ReviewingLabel.staleRemovals(
            candidates: [
                ReviewingLabel.Candidate(url: live, latestActor: "ada"),
                ReviewingLabel.Candidate(url: mine, latestActor: "ada"),
                ReviewingLabel.Candidate(url: theirs, latestActor: "bob"),
                ReviewingLabel.Candidate(url: held, latestActor: "ADA"),
                ReviewingLabel.Candidate(url: mine, latestActor: "ada"),
            ],
            liveReviewPRURLs: [live, "https://github.com/acme/app/pull/4"],
            viewerLogin: "ada"
        )
        #expect(removed == [mine])
    }

    @Test func staleSweepRemovesNothingWhenTheViewerIsUnknown() {
        let removed = ReviewingLabel.staleRemovals(
            candidates: [ReviewingLabel.Candidate(url: "https://github.com/a/b/pull/1", latestActor: "ada")],
            liveReviewPRURLs: [],
            viewerLogin: ""
        )
        #expect(removed.isEmpty)
    }
}
