import ArgumentParser
import Foundation
import Testing
import CrowCore
@testable import CrowCLILib

// MARK: - `crow skin` command parsing (CROW-1334)

@Test func skinGroupRoutesToSubcommands() throws {
    #expect(try Skin.parseAsRoot(["list"]) is SkinList)
    #expect(try Skin.parseAsRoot(["get", "--id", "graphite"]) is SkinGet)
    #expect(try Skin.parseAsRoot(["create", "--from", "corveil", "--name", "X"]) is SkinCreate)
    #expect(try Skin.parseAsRoot(["export", "--id", "graphite"]) is SkinExport)
    #expect(try Skin.parseAsRoot(["remove", "--id", "dusty"]) is SkinRemove)
    #expect(try Skin.parseAsRoot(["default", "set", "graphite"]) is SkinDefaultSet)
    #expect(try Skin.parseAsRoot(["default", "clear"]) is SkinDefaultClear)
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("crow-cli-skin-\(UUID().uuidString).json")
    try Data("{}".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let add = try #require(try Skin.parseAsRoot(["add", file.path, "--id", "mine"]) as? SkinAdd)
    #expect(add.id == "mine")
}

/// The ticket's acceptance command parses, with the dashes optional on TOKEN.
@Test func skinCreateTicketExampleParses() throws {
    let cmd = try SkinCreate.parse([
        "--from", "corveil-classic", "--name", "Dusty", "--set", "accent=#7AA2F7",
        "--set-light", "bg-deep=#FAFAFA", "--set", "on-accent=rgba(0, 0, 0, 0.9)",
    ])
    #expect(cmd.from == "corveil-classic")
    #expect(cmd.id == nil)
    #expect(try SkinCreate.parse(cmd.set, flag: "--set") == [
        "--accent": "#7AA2F7", "--on-accent": "rgba(0, 0, 0, 0.9)",
    ])
    #expect(try SkinCreate.parse(cmd.setLight, flag: "--set-light") == ["--bg-deep": "#FAFAFA"])
}

@Test(arguments: [
    ["--from", "corveil", "--name", "X", "--set", "accent"],               // no =
    ["--from", "corveil", "--name", "X", "--set", "accent="],              // no value
    ["--from", "corveil", "--name", "X", "--set", "ink-900=#000"],         // brand primitive
    ["--from", "corveil", "--name", "X", "--set-light", "nope=#000"],      // unknown token
    ["--from", "Corveil", "--name", "X"],                                  // bad --from id
    ["--from", "corveil", "--name", "X", "--id", "Bad Id"],                // bad --id
    ["--from", "corveil", "--name", "   "],                                // blank name
    ["--from", "corveil", "--name", "✨"],                                  // no derivable id
])
func skinCreateRejects(_ args: [String]) {
    #expect(throws: (any Error).self) { try SkinCreate.parse(args) }
}

@Test func skinAddRequiresAReadableFile() {
    #expect(throws: (any Error).self) { try SkinAdd.parse(["/no/such/skin.json"]) }
    #expect(throws: (any Error).self) {
        try SkinAdd.parse([FileManager.default.temporaryDirectory.path])
    }
}

@Test func skinDefaultSetValidatesTheID() {
    #expect(throws: (any Error).self) { try SkinDefault.parseAsRoot(["set", "Not An Id"]) }
    #expect(throws: (any Error).self) { try SkinDefault.parseAsRoot(["set"]) }
}

@Test func skinExportTakesAnOptionalOut() throws {
    let cmd = try SkinExport.parse(["--id", "graphite", "--out", "~/graphite.json"])
    #expect(cmd.out == "~/graphite.json")
    #expect(try SkinExport.parse(["--id", "graphite"]).out == nil)
}
