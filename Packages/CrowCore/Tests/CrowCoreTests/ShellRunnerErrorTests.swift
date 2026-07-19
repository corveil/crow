import Foundation
import Testing
@testable import CrowCore

@Suite("ShellRunnerError LocalizedError (CROW-621)")
struct ShellRunnerErrorTests {

    @Test func localizedDescriptionIncludesExitCodeAndOutput() {
        let error = ShellRunnerError.nonZeroExit(
            exitCode: 1,
            output: "GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)\n"
        )
        let description = error.localizedDescription
        #expect(description.contains("exit code 1"))
        #expect(description.contains("enablePullRequestAutoMerge"))
        #expect(description.contains("Auto merge is not allowed"))
    }

    @Test func localizedDescriptionHandlesEmptyOutput() {
        let error = ShellRunnerError.nonZeroExit(exitCode: 127, output: "   \n")
        #expect(error.localizedDescription == "Command failed with exit code 127")
    }

    @Test func localizedDescriptionIsNotOpaqueErrorZero() {
        // Regression: without LocalizedError, Foundation prints
        // "The operation couldn't be completed. (CrowCore.ShellRunnerError error 0.)"
        let error = ShellRunnerError.nonZeroExit(exitCode: 1, output: "gh: not authenticated")
        #expect(!error.localizedDescription.contains("error 0"))
        #expect(error.localizedDescription.contains("gh: not authenticated"))
    }
}
