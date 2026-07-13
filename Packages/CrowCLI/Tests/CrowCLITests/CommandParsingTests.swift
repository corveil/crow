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

// MARK: - set-ticket --priority + set-goal (#696)

@Test func setTicketParsesPriority() throws {
    let cmd = try SetTicket.parse(["--session", validUUID, "--priority", "high"])
    #expect(cmd.session == validUUID)
    try cmd.validate() // --priority alone satisfies the has-field rule
}

@Test func setTicketAcceptsCaseInsensitivePriority() throws {
    let cmd = try SetTicket.parse(["--session", validUUID, "--priority", "Highest"])
    try cmd.validate()
}

@Test func setTicketRejectsBogusPriority() {
    #expect(throws: (any Error).self) {
        let cmd = try SetTicket.parse(["--session", validUUID, "--priority", "urgent"])
        try cmd.validate()
    }
}

@Test func setGoalParsesGoal() throws {
    let cmd = try SetGoal.parse(["--session", validUUID, "--goal", "Q3 latency KPI"])
    #expect(cmd.session == validUUID)
    try cmd.validate()
}

@Test func setGoalParsesClear() throws {
    let cmd = try SetGoal.parse(["--session", validUUID, "--clear"])
    try cmd.validate()
}

@Test func setGoalRejectsGoalWithClear() {
    #expect(throws: (any Error).self) {
        let cmd = try SetGoal.parse(["--session", validUUID, "--goal", "x", "--clear"])
        try cmd.validate()
    }
}

@Test func setGoalRejectsNoArgs() {
    #expect(throws: (any Error).self) {
        let cmd = try SetGoal.parse(["--session", validUUID])
        try cmd.validate()
    }
}

@Test func setGoalRejectsInvalidUUID() {
    #expect(throws: (any Error).self) {
        let cmd = try SetGoal.parse(["--session", "not-a-uuid", "--goal", "x"])
        try cmd.validate()
    }
}

// MARK: - transition-ticket (#529)

@Test func transitionTicketParsesValidArgs() throws {
    let cmd = try TransitionTicket.parse(["--session", validUUID, "--to", "inProgress"])
    #expect(cmd.session == validUUID)
    #expect(cmd.to == "inProgress")
    try cmd.validate()
}

@Test func transitionTicketAcceptsCaseInsensitiveStatus() throws {
    let cmd = try TransitionTicket.parse(["--session", validUUID, "--to", "INREVIEW"])
    try cmd.validate()
}

@Test func transitionTicketRejectsUnknownStatus() {
    #expect(throws: (any Error).self) {
        let cmd = try TransitionTicket.parse(["--session", validUUID, "--to", "backlog"])
        try cmd.validate()
    }
}

@Test func transitionTicketRejectsInvalidUUID() {
    #expect(throws: (any Error).self) {
        let cmd = try TransitionTicket.parse(["--session", "not-a-uuid", "--to", "done"])
        try cmd.validate()
    }
}
