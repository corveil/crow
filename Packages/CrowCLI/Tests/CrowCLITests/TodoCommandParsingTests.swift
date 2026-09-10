import Foundation
import Testing
import ArgumentParser
@testable import CrowCLILib

private let todoUUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

@Test func todoAddParsesTextAndFlags() throws {
    let cmd = try TodoAdd.parse([
        "native scratch list",
        "--tag", "ios,cli",
        "--priority", "p2",
        "--note", "before a ticket exists",
    ])
    #expect(cmd.text == "native scratch list")
    #expect(cmd.tag == "ios,cli")
    #expect(cmd.priority == "p2")
    #expect(cmd.note == "before a ticket exists")
}

@Test func todoAddRejectsBlankText() {
    #expect(throws: (any Error).self) {
        _ = try TodoAdd.parse(["   "])
    }
}

@Test func todoAddRejectsBadPriority() {
    #expect(throws: (any Error).self) {
        _ = try TodoAdd.parse(["idea", "--priority", "urgent"])
    }
}

@Test func todoListParsesFilters() throws {
    let cmd = try TodoList.parse(["--state", "captured", "--tag", "ios"])
    #expect(cmd.state == "captured")
    #expect(cmd.tag == "ios")
}

@Test func todoListRejectsUnknownState() {
    #expect(throws: (any Error).self) {
        _ = try TodoList.parse(["--state", "maybe"])
    }
}

@Test func todoEditParsesAddAndRemoveTags() throws {
    let cmd = try TodoEdit.parse([
        "--id", todoUUID,
        "--text", "changed",
        "--add-tag", "cli",
        "--remove-tag", "ios",
    ])
    #expect(cmd.id == todoUUID)
    #expect(cmd.text == "changed")
    #expect(cmd.addTag == ["cli"])
    #expect(cmd.removeTag == ["ios"])
}

@Test func todoLinkParsesSessionType() throws {
    let cmd = try TodoLink.parse([
        "--id", todoUUID,
        "--type", "session",
        "--session", todoUUID,
        "--label", "explore",
    ])
    #expect(cmd.type == "session")
    #expect(cmd.session == todoUUID)
}

@Test func todoLinkRejectsUnknownType() {
    #expect(throws: (any Error).self) {
        _ = try TodoLink.parse(["--id", todoUUID, "--type", "repo"])
    }
}

@Test func todoExploreParsesAgent() throws {
    let cmd = try TodoExplore.parse(["--id", todoUUID, "--agent", "cursor"])
    #expect(cmd.agent == "cursor")
}

@Test func todoTicketRequiresWorkspace() {
    #expect(throws: (any Error).self) {
        _ = try TodoTicket.parse(["--id", todoUUID])
    }
}

@Test func todoTicketParsesWorkspaceAndRepo() throws {
    let cmd = try TodoTicket.parse([
        "--id", todoUUID, "--workspace", "Corveil", "--repo", "corveil/crow",
    ])
    #expect(cmd.workspace == "Corveil")
    #expect(cmd.repo == "corveil/crow")
}

@Test func todoTalkParsesPositionalText() throws {
    let cmd = try TodoTalk.parse(["--id", todoUUID, "keep going"])
    #expect(cmd.text == "keep going")
}

@Test func todoGroupIsRegistered() throws {
    #expect(CrowCommand.configuration.subcommands.contains { $0 == Todo.self })
    let names = Todo.configuration.subcommands.map { $0.configuration.commandName }
    #expect(names.contains("add"))
    #expect(names.contains("explore"))
    #expect(names.contains("ticket"))
    #expect(names.contains("work"))
    #expect(names.contains("talk"))
}

@Test func todoNestedParseResolvesToCommandType() throws {
    #expect(try CrowCommand.parseAsRoot(["todo", "list"]) is TodoList)
    #expect(try CrowCommand.parseAsRoot(["todo", "get", "--id", todoUUID]) is TodoGet)
    #expect(try CrowCommand.parseAsRoot(["todo", "done", "--id", todoUUID]) is TodoDone)
    #expect(try CrowCommand.parseAsRoot(["todo", "work", "--id", todoUUID]) is TodoWork)
}
