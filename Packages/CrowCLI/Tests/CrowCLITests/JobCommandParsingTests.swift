import Foundation
import Testing
import ArgumentParser
@testable import CrowCLILib

// MARK: - `crow job` command parsing (CROW-604)

private let jobUUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

@Test func jobAddParsesFullArgs() throws {
    let cmd = try JobAdd.parse([
        "--name", "nightly triage",
        "--workspace", "RadiusMethod",
        "--repo", "radiusmethod/api",
        "--prompt", "first prompt",
        "--prompt", "second prompt",
        "--daily-at", "09:30",
        "--weekdays", "mon,fri",
        "--disabled",
    ])
    #expect(cmd.name == "nightly triage")
    #expect(cmd.workspace == "RadiusMethod")
    #expect(cmd.repo == "radiusmethod/api")
    #expect(cmd.prompt == ["first prompt", "second prompt"])
    #expect(cmd.dailyAt == "09:30")
    #expect(cmd.weekdays == "mon,fri")
    #expect(cmd.disabled)
}

@Test func jobAddParsesIntervalSchedule() throws {
    let cmd = try JobAdd.parse([
        "--name", "hourly", "--workspace", "ws", "--repo", "o/r",
        "--prompt", "p", "--interval-seconds", "3600",
    ])
    #expect(cmd.intervalSeconds == 3600)
    #expect(!cmd.disabled)
}

@Test func jobAddRequiresSchedule() {
    // validate() runs during parse, so a missing schedule throws here.
    #expect(throws: (any Error).self) {
        _ = try JobAdd.parse(["--name", "x", "--workspace", "ws", "--repo", "o/r", "--prompt", "p"])
    }
}

@Test func jobAddRejectsBothSchedules() {
    #expect(throws: (any Error).self) {
        _ = try JobAdd.parse([
            "--name", "x", "--workspace", "ws", "--repo", "o/r", "--prompt", "p",
            "--interval-seconds", "60", "--daily-at", "09:00",
        ])
    }
}

@Test func jobAddRejectsWeekdaysWithoutDailyAt() {
    #expect(throws: (any Error).self) {
        _ = try JobAdd.parse([
            "--name", "x", "--workspace", "ws", "--repo", "o/r", "--prompt", "p",
            "--interval-seconds", "60", "--weekdays", "mon",
        ])
    }
}

@Test func jobAddRequiresPrompt() {
    #expect(throws: (any Error).self) {
        _ = try JobAdd.parse(["--name", "x", "--workspace", "ws", "--repo", "o/r", "--interval-seconds", "60"])
    }
}

@Test func jobAddAcceptsPromptFileOnly() throws {
    let cmd = try JobAdd.parse([
        "--name", "x", "--workspace", "ws", "--repo", "o/r",
        "--prompt-file", "/tmp/prompt.md", "--interval-seconds", "60",
    ])
    #expect(cmd.promptFile == ["/tmp/prompt.md"])
}

@Test func jobAddRejectsMultipleStdinPromptFiles() {
    #expect(throws: (any Error).self) {
        _ = try JobAdd.parse([
            "--name", "x", "--workspace", "ws", "--repo", "o/r",
            "--prompt-file", "-", "--prompt-file", "-", "--interval-seconds", "60",
        ])
    }
}

@Test func jobAddRejectsBlankName() {
    #expect(throws: (any Error).self) {
        _ = try JobAdd.parse(["--name", "  ", "--workspace", "ws", "--repo", "o/r", "--prompt", "p", "--interval-seconds", "60"])
    }
}

@Test func jobAddRejectsBareOrPathLikeRepo() {
    // repo must be an owner/repo slug; its last component becomes a folder
    // name, so bare names and path-like components are rejected client-side.
    for bad in ["api", "foo/..", "../foo", "/repo", "owner/"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            _ = try JobAdd.parse(["--name", "x", "--workspace", "ws", "--repo", bad, "--prompt", "p", "--interval-seconds", "60"])
        }
    }
}

@Test func jobAddAcceptsNestedGroupRepo() throws {
    let cmd = try JobAdd.parse(["--name", "x", "--workspace", "ws", "--repo", "group/sub/project", "--prompt", "p", "--interval-seconds", "60"])
    #expect(cmd.repo == "group/sub/project")
}

@Test func jobEditRejectsBlankNameAndBadRepo() {
    #expect(throws: (any Error).self) {
        _ = try JobEdit.parse(["--id", jobUUID, "--name", "  "])
    }
    #expect(throws: (any Error).self) {
        _ = try JobEdit.parse(["--id", jobUUID, "--repo", "foo/.."])
    }
}

@Test func jobEditParsesPartialFields() throws {
    let cmd = try JobEdit.parse(["--id", jobUUID, "--name", "renamed"])
    #expect(cmd.id == jobUUID)
    #expect(cmd.name == "renamed")
    #expect(cmd.workspace == nil)
    #expect(cmd.repo == nil)
    #expect(cmd.prompt.isEmpty)
    #expect(cmd.intervalSeconds == nil)
}

@Test func jobEditParsesScheduleChange() throws {
    let cmd = try JobEdit.parse(["--id", jobUUID, "--daily-at", "18:00", "--weekdays", "sat,sun"])
    #expect(cmd.dailyAt == "18:00")
    #expect(cmd.weekdays == "sat,sun")
}

@Test func jobEditRequiresAtLeastOneField() {
    #expect(throws: (any Error).self) {
        _ = try JobEdit.parse(["--id", jobUUID])
    }
}

@Test func jobEditRejectsInvalidUUID() {
    #expect(throws: (any Error).self) {
        _ = try JobEdit.parse(["--id", "not-a-uuid", "--name", "x"])
    }
}

@Test func jobIdSubcommandsParseValidUUID() throws {
    #expect(try JobGet.parse(["--id", jobUUID]).id == jobUUID)
    #expect(try JobEnable.parse(["--id", jobUUID]).id == jobUUID)
    #expect(try JobDisable.parse(["--id", jobUUID]).id == jobUUID)
    #expect(try JobRun.parse(["--id", jobUUID]).id == jobUUID)
    #expect(try JobDelete.parse(["--id", jobUUID]).id == jobUUID)
    #expect(try JobDuplicate.parse(["--id", jobUUID]).id == jobUUID)
}

@Test func jobIdSubcommandsRejectInvalidUUID() {
    #expect(throws: (any Error).self) { _ = try JobGet.parse(["--id", "nope"]) }
    #expect(throws: (any Error).self) { _ = try JobEnable.parse(["--id", "nope"]) }
    #expect(throws: (any Error).self) { _ = try JobDisable.parse(["--id", "nope"]) }
    #expect(throws: (any Error).self) { _ = try JobRun.parse(["--id", "nope"]) }
    #expect(throws: (any Error).self) { _ = try JobDelete.parse(["--id", "nope"]) }
    #expect(throws: (any Error).self) { _ = try JobDuplicate.parse(["--id", "nope"]) }
}

@Test func jobGroupRoutesToSubcommands() throws {
    // The nested `crow job <sub>` group resolves each verb to its command type.
    let parsed = try Job.parseAsRoot(["list"])
    #expect(parsed is JobList)
    let get = try Job.parseAsRoot(["get", "--id", jobUUID])
    #expect(get is JobGet)
}
