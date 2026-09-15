import ArgumentParser
import Foundation
import Testing
@testable import CrowCLILib

private let validUUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

@Test func tuiRecordStartParsesSessionTerminalAndNote() throws {
    let cmd = try TuiRecordStart.parse([
        "--session", validUUID,
        "--terminal", validUUID,
        "--note", "cursor jumped",
    ])
    #expect(cmd.session == validUUID)
    #expect(cmd.terminal == validUUID)
    #expect(cmd.note == "cursor jumped")
    try cmd.validate()
}

@Test func tuiRecordStartRejectsBadUUID() {
    #expect(throws: (any Error).self) {
        _ = try TuiRecordStart.parse(["--session", "nope"])
    }
}

@Test func tuiRecordHudParsesOnAndOff() throws {
    let on = try TuiRecordHud.parse(["--session", validUUID, "on"])
    #expect(on.mode == "on")
    try on.validate()
    let off = try TuiRecordHud.parse(["--session", validUUID, "off"])
    #expect(off.mode == "off")
    try off.validate()
}

@Test func tuiRecordHudRejectsUnknownMode() {
    #expect(throws: (any Error).self) {
        _ = try TuiRecordHud.parse(["--session", validUUID, "maybe"])
    }
}

@Test func tuiRecordLogParsesSince() throws {
    let cmd = try TuiRecordLog.parse(["--id", validUUID, "--since", "1200", "--kind", "cursor_mismatch"])
    #expect(cmd.since == 1200)
    #expect(cmd.kind == "cursor_mismatch")
}

@Test func tuiRecordExportParsesDirAndFixture() throws {
    let cmd = try TuiRecordExport.parse(["--id", validUUID, "--dir", "/tmp/out", "--fixture"])
    #expect(cmd.dir == "/tmp/out")
    #expect(cmd.fixture)
    try cmd.validate()
}

@Test func tuiRecordExportRunDoesNotCallRPC() throws {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url = url.deletingLastPathComponent() }
    let src = try String(
        contentsOf: url.appendingPathComponent(
            "Packages/CrowCLI/Sources/CrowCLILib/Commands/TuiCommands.swift"),
        encoding: .utf8)
    let start = try #require(src.range(of: "BEGIN export-no-rpc"))
    let end = try #require(src.range(of: "END export-no-rpc"))
    let body = src[start.upperBound..<end.lowerBound]
    #expect(!body.contains("try rpc("))
    #expect(!body.contains("rpc(\""))
}

@Test func tuiIsRegisteredOnCrowCommand() {
    let names = CrowCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
    #expect(names.contains("tui"))
    let record = Tui.configuration.subcommands.compactMap { $0.configuration.commandName }
    #expect(record.contains("record"))
    let leaves = TuiRecord.configuration.subcommands.compactMap { $0.configuration.commandName }
    #expect(Set(leaves) == [
        "start", "stop", "mark", "list", "get", "log", "delete", "hud", "export",
    ])
}
