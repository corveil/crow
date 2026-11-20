import Foundation
import Testing
@testable import CrowCore

// `create-manager --name / --prompt` (CROW-1474). The CLI and the daemon both
// run these, so a bad value fails the same way from either side.

@Test func managerCreationNameFollowsRenameRules() throws {
    #expect(try ManagerCreation.validatedName(nil) == nil)
    #expect(try ManagerCreation.validatedName("review crow-1078") == "review crow-1078")
    #expect(try ManagerCreation.validatedName(String(repeating: "x", count: 256)) != nil)
    for bad in ["", "  ", "line\nbreak", "tab\there", String(repeating: "x", count: 257)] {
        #expect(throws: ManagerCreation.InvalidRequest.self) {
            _ = try ManagerCreation.validatedName(bad)
        }
    }
}

@Test func managerCreationPromptRejectsBlankAndOversized() throws {
    #expect(try ManagerCreation.validatedPrompt(nil) == nil)
    let brief = "# Brief\n\nRead the ticket.\n"
    #expect(try ManagerCreation.validatedPrompt(brief) == brief)
    let atLimit = String(repeating: "x", count: ManagerCreation.maxPromptBytes)
    #expect(try ManagerCreation.validatedPrompt(atLimit) == atLimit)
    #expect(throws: ManagerCreation.InvalidRequest.self) {
        _ = try ManagerCreation.validatedPrompt(" \n\t ")
    }
    #expect(throws: ManagerCreation.InvalidRequest.self) {
        _ = try ManagerCreation.validatedPrompt(atLimit + "x")
    }
    // The limit is bytes, not characters: a multi-byte prompt under the
    // character count can still be too long for one argv string.
    let multiByte = String(repeating: "é", count: ManagerCreation.maxPromptBytes / 2 + 1)
    #expect(throws: ManagerCreation.InvalidRequest.self) {
        _ = try ManagerCreation.validatedPrompt(multiByte)
    }
}

@Test func managerCreationDefaultNameIsLowestUnused() {
    #expect(ManagerCreation.defaultName(existing: []) == "Manager 2")
    #expect(ManagerCreation.defaultName(existing: ["Manager 2", "Manager 4"]) == "Manager 3")
    #expect(ManagerCreation.defaultName(existing: ["Manager 2", "Manager 3"]) == "Manager 4")
}

@Test func managerCreationSeededNeedsPromptBriefAndPane() {
    #expect(ManagerCreation.seeded(promptGiven: true, briefWritten: true, paneUp: true))
    // A tagged Manager always gets a workspace brief file, so a written brief
    // without a caller prompt is not "seeded".
    #expect(!ManagerCreation.seeded(promptGiven: false, briefWritten: true, paneUp: true))
    #expect(!ManagerCreation.seeded(promptGiven: true, briefWritten: false, paneUp: true))
    #expect(!ManagerCreation.seeded(promptGiven: true, briefWritten: true, paneUp: false))
}
