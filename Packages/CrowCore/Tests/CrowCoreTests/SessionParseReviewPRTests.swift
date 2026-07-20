import Foundation
import Testing
@testable import CrowCore

@Test func parseReviewPRExtractsOwnerRepoAndNumber() {
    let parsed = Session.parseReviewPR(url: "https://github.com/corveil/crow/pull/406")
    #expect(parsed?.owner == "corveil")
    #expect(parsed?.repo == "crow")
    #expect(parsed?.number == 406)
}

@Test func parseReviewPRReturnsNilForNonIntegerTrailingSegment() {
    #expect(Session.parseReviewPR(url: "https://github.com/owner/repo/pull/abc") == nil)
}

@Test func parseReviewPRReturnsNilForTooFewPathComponents() {
    #expect(Session.parseReviewPR(url: "github.com/owner/123") == nil)
}

@Test func parseReviewPRReturnsNilForEmptyString() {
    #expect(Session.parseReviewPR(url: "") == nil)
}
