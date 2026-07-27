import Foundation
import Testing
import ArgumentParser
@testable import CrowCLILib

// MARK: - Board & workflow command parsing (CROW-817)

private let sessionUUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
private let issueURL = "https://github.com/corveil/crow/issues/817"
private let prURL = "https://github.com/corveil/crow/pull/842"

// MARK: work-on-issue

@Test func workOnIssueParsesURL() throws {
    let cmd = try WorkOnIssue.parse(["--url", issueURL])
    #expect(cmd.url == issueURL)
}

@Test func workOnIssueRejectsUnsafeURLs() {
    // Mirrors the daemon's `isSafeIssueURL`: the URL is typed into the Manager
    // terminal, so whitespace/control characters would split the prompt.
    for bad in ["", "not-a-url", "ftp://example.com/x", "https://ex.com/a b",
                "https://ex.com/a\nrm -rf /", "https://ex.com/a\u{7F}"] {
        #expect(throws: (any Error).self) {
            _ = try WorkOnIssue.parse(["--url", bad])
        }
    }
}

// MARK: batch-work-on-issues

@Test func batchWorkOnIssuesCollectsRepeatedURLsInOrder() throws {
    let cmd = try BatchWorkOnIssues.parse([
        "--url", issueURL, "--url", "https://github.com/corveil/crow/issues/818",
    ])
    #expect(cmd.url == [issueURL, "https://github.com/corveil/crow/issues/818"])
    #expect(cmd.urlsFile == nil)
}

@Test func batchWorkOnIssuesParsesURLsFile() throws {
    let cmd = try BatchWorkOnIssues.parse(["--urls-file", "-"])
    #expect(cmd.url.isEmpty)
    #expect(cmd.urlsFile == "-")
}

@Test func batchWorkOnIssuesRequiresAtLeastOneSource() {
    #expect(throws: (any Error).self) {
        _ = try BatchWorkOnIssues.parse([])
    }
}

@Test func batchWorkOnIssuesRejectsBlankInlineURL() {
    #expect(throws: (any Error).self) {
        _ = try BatchWorkOnIssues.parse(["--url", "   "])
    }
}

@Test func batchWorkOnIssuesAcceptsMalformedURLs() throws {
    // Deliberate: the daemon drops unsafe URLs into `rejected` and starts the
    // rest, so one bad ticket can't block the batch. Rejecting locally would
    // destroy that behavior.
    let cmd = try BatchWorkOnIssues.parse(["--url", "not-a-url", "--url", issueURL])
    #expect(cmd.url == ["not-a-url", issueURL])
}

// MARK: start-review

@Test func startReviewParsesURL() throws {
    let cmd = try StartReview.parse(["--url", prURL])
    #expect(cmd.url == prURL)
}

@Test func startReviewAcceptsURLWorkOnIssueWouldReject() throws {
    // Intentional asymmetry: start-review's URL goes to git clone /
    // SessionService, not terminal keystrokes, so the daemon doesn't run
    // `isSafeIssueURL` on it and neither do we.
    let odd = "ssh://git@example.com/repo"
    #expect(throws: (any Error).self) { _ = try WorkOnIssue.parse(["--url", odd]) }
    let cmd = try StartReview.parse(["--url", odd])
    #expect(cmd.url == odd)
}

@Test func startReviewRejectsBlankURL() {
    #expect(throws: (any Error).self) {
        _ = try StartReview.parse(["--url", "   "])
    }
}

@Test func startReviewTrimsSurroundingWhitespaceBeforeSending() throws {
    // Validation only checked emptiness on the trimmed value, so an untrimmed
    // `--url` could reach `git clone` with padding. Trim what goes on the wire,
    // matching how `BoardArgs.urlList` treats the batch verb's inputs.
    let cmd = try StartReview.parse(["--url", "  \(prURL)\n "])
    #expect(cmd.trimmedURL == prURL)
}

// MARK: create-manager

@Test func createManagerParsesWithoutAgent() throws {
    let cmd = try CreateManager.parse([])
    #expect(cmd.agent == nil)
}

@Test func createManagerParsesAgent() throws {
    let cmd = try CreateManager.parse(["--agent", "cursor"])
    #expect(cmd.agent == "cursor")
}

@Test func createManagerRejectsBlankAgent() {
    #expect(throws: (any Error).self) {
        _ = try CreateManager.parse(["--agent", "  "])
    }
}

@Test func createManagerAcceptsUnknownAgentKind() throws {
    // `AgentKind` is an open RawRepresentable struct that downstream packages
    // extend, so the CLI must not hold a stale allowlist.
    let cmd = try CreateManager.parse(["--agent", "some-future-agent"])
    #expect(cmd.agent == "some-future-agent")
}

// MARK: quick-action

@Test func quickActionParsesSessionAndAction() throws {
    let cmd = try QuickActionCmd.parse(["--session", sessionUUID, "--action", "fixChecks"])
    #expect(cmd.session == sessionUUID)
    #expect(cmd.action == "fixChecks")
}

@Test func quickActionAcceptsEveryKnownAction() throws {
    for action in validQuickActions {
        let cmd = try QuickActionCmd.parse(["--session", sessionUUID, "--action", action])
        #expect(cmd.action == action)
    }
}

@Test func quickActionRejectsInvalidUUIDAndAction() {
    #expect(throws: (any Error).self) {
        _ = try QuickActionCmd.parse(["--session", "nope", "--action", "fixChecks"])
    }
    #expect(throws: (any Error).self) {
        _ = try QuickActionCmd.parse(["--session", sessionUUID, "--action", "mergepr"])
    }
}

// MARK: read verbs + registration

@Test func boardReadVerbsParseWithNoArguments() throws {
    _ = try ListTickets.parse([])
    _ = try ListReviews.parse([])
    _ = try RefreshTickets.parse([])
}

@Test func boardVerbsAreRegisteredOnTheRootCommand() throws {
    // Each board verb must resolve from `crow <verb>`, not just as a type.
    let work = try CrowCommand.parseAsRoot(["work-on-issue", "--url", issueURL])
    #expect(work is WorkOnIssue)
    let batch = try CrowCommand.parseAsRoot(["batch-work-on-issues", "--url", issueURL])
    #expect(batch is BatchWorkOnIssues)
    let review = try CrowCommand.parseAsRoot(["start-review", "--url", prURL])
    #expect(review is StartReview)
    let manager = try CrowCommand.parseAsRoot(["create-manager"])
    #expect(manager is CreateManager)
    let refresh = try CrowCommand.parseAsRoot(["refresh-tickets"])
    #expect(refresh is RefreshTickets)
    let quick = try CrowCommand.parseAsRoot(["quick-action", "--session", sessionUUID, "--action", "mergePR"])
    #expect(quick is QuickActionCmd)
    let tickets = try CrowCommand.parseAsRoot(["list-tickets"])
    #expect(tickets is ListTickets)
    let reviews = try CrowCommand.parseAsRoot(["list-reviews"])
    #expect(reviews is ListReviews)
}
