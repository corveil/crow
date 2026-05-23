import Foundation
import Testing
import ArgumentParser
@testable import CrowCLILib

// MARK: - Command Argument Parsing Tests

private let validUUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

@Test func hookEventCmdParsesValidArgs() throws {
    let cmd = try HookEventCmd.parse(["--session", validUUID, "--event", "Stop"])
    #expect(cmd.session == validUUID)
    #expect(cmd.event == "Stop")
}

@Test func hookEventCmdRejectsInvalidUUID() {
    // Validation functions are tested directly (matching existing ValidationTests pattern)
    #expect(throws: (any Error).self) {
        try validateUUID("not-a-uuid", label: "session UUID")
    }
}

@Test func newSessionParsesManagerKind() throws {
    let cmd = try NewSession.parse(["--name", "Manager 2", "--kind", "manager"])
    #expect(cmd.name == "Manager 2")
    #expect(cmd.kind == "manager")
    try cmd.validate()
}

@Test func newSessionDefaultsToNoKind() throws {
    let cmd = try NewSession.parse(["--name", "feature"])
    #expect(cmd.kind == nil)
    try cmd.validate()
}

@Test func newSessionRejectsInvalidKind() {
    // ArgumentParser runs validate() during parse, so an invalid kind throws here.
    #expect(throws: (any Error).self) {
        _ = try NewSession.parse(["--name", "x", "--kind", "bogus"])
    }
}

@Test func newSessionRejectsReviewAndJobKinds() {
    // Review and job sessions need dedicated setup flows, so new-session only
    // accepts work and manager.
    for kind in ["review", "job"] {
        #expect(throws: (any Error).self) {
            _ = try NewSession.parse(["--name", "x", "--kind", kind])
        }
    }
}

@Test func setStatusParsesArgs() throws {
    let cmd = try SetStatus.parse(["--session", validUUID, "active"])
    #expect(cmd.session == validUUID)
    #expect(cmd.status == "active")
}

@Test func setStatusRejectsInvalidStatus() {
    #expect(throws: (any Error).self) {
        try validateSessionStatus("invalid-status")
    }
}

@Test func addLinkParsesAllArgs() throws {
    let cmd = try AddLink.parse(["--session", validUUID, "--label", "PR", "--url", "https://example.com", "--type", "pr"])
    #expect(cmd.session == validUUID)
    #expect(cmd.label == "PR")
    #expect(cmd.url == "https://example.com")
    #expect(cmd.type == "pr")
}

@Test func addLinkDefaultTypeIsCustom() throws {
    let cmd = try AddLink.parse(["--session", validUUID, "--label", "Docs", "--url", "https://docs.com"])
    #expect(cmd.type == "custom")
}
