import Foundation
import Testing
import ArgumentParser
@testable import CrowCLILib

// MARK: - session lifecycle verbs (#816)

private let validUUID = "b7c1e2d3-4f5a-6789-abcd-0123456789ab"

/// Every lifecycle verb takes exactly one flag — `--session` — and maps to the
/// RPC method of the same name. Parsed as a group so a newly added verb can't
/// quietly skip the UUID guard.
@Test func lifecycleVerbsParseSessionFlag() throws {
    #expect(try MarkInReview.parse(["--session", validUUID]).session == validUUID)
    #expect(try CompleteSession.parse(["--session", validUUID]).session == validUUID)
    #expect(try SetSessionActive.parse(["--session", validUUID]).session == validUUID)
    #expect(try MarkIssueDone.parse(["--session", validUUID]).session == validUUID)
    #expect(try AddMergeLabel.parse(["--session", validUUID]).session == validUUID)
}

/// validate() runs during parse, so a malformed UUID throws here.
@Test func lifecycleVerbsRejectInvalidUUID() {
    #expect(throws: (any Error).self) { _ = try MarkInReview.parse(["--session", "not-a-uuid"]) }
    #expect(throws: (any Error).self) { _ = try CompleteSession.parse(["--session", "not-a-uuid"]) }
    #expect(throws: (any Error).self) { _ = try SetSessionActive.parse(["--session", "not-a-uuid"]) }
    #expect(throws: (any Error).self) { _ = try MarkIssueDone.parse(["--session", "not-a-uuid"]) }
    #expect(throws: (any Error).self) { _ = try AddMergeLabel.parse(["--session", "not-a-uuid"]) }
}

@Test func lifecycleVerbsRequireSessionFlag() {
    #expect(throws: (any Error).self) { _ = try MarkInReview.parse([]) }
    #expect(throws: (any Error).self) { _ = try CompleteSession.parse([]) }
    #expect(throws: (any Error).self) { _ = try SetSessionActive.parse([]) }
    #expect(throws: (any Error).self) { _ = try MarkIssueDone.parse([]) }
    #expect(throws: (any Error).self) { _ = try AddMergeLabel.parse([]) }
}

/// The verbs are flat top-level subcommands (like `set-status`), not a nested
/// `crow session …` group — this pins the command names the docs advertise.
@Test func lifecycleVerbsRouteFromRoot() throws {
    let expected: [(String, any ParsableCommand.Type)] = [
        ("mark-in-review", MarkInReview.self),
        ("complete-session", CompleteSession.self),
        ("set-session-active", SetSessionActive.self),
        ("mark-issue-done", MarkIssueDone.self),
        ("add-merge-label", AddMergeLabel.self),
    ]
    for (name, type) in expected {
        let parsed = try CrowCommand.parseAsRoot([name, "--session", validUUID])
        #expect(Swift.type(of: parsed) == type, "`crow \(name)` should route to \(type)")
    }
}
