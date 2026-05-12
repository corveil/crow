import Foundation
import Testing
@testable import CrowCore

@Test func crowAttributionRepoURLIsCanonical() {
    #expect(CrowAttribution.repoURL == "https://github.com/radiusmethod/crow")
}

@Test func crowAttributionReviewLinkIsCanonical() {
    #expect(CrowAttribution.reviewMarkdownLink ==
            "[🤖 Reviewed by Crow via Claude Code](https://github.com/radiusmethod/crow)")
}

@Test func crowAttributionReviewLinkEmbedsRepoURL() {
    #expect(CrowAttribution.reviewMarkdownLink.contains(CrowAttribution.repoURL))
}

@Test func crowAttributionContainsNoForkReferences() {
    #expect(!CrowAttribution.reviewMarkdownLink.contains("nicholasgasior"))
    #expect(!CrowAttribution.reviewMarkdownLink.lowercased().contains("corveil"))
}
