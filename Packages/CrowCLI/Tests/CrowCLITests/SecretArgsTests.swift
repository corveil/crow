import ArgumentParser
import Foundation
import Testing

@testable import CrowCLILib

@Test func passwordFromStdinUsesTheLineVerbatim() throws {
    #expect(try SecretArgs.passwordFromStdin("hunter2") == "hunter2")
    // Spaces are legal password characters — trimming would change the secret.
    #expect(try SecretArgs.passwordFromStdin("  spaced  ") == "  spaced  ")
}

@Test func passwordFromStdinStripsTrailingCarriageReturn() throws {
    // A CRLF pipe must not silently append \r to the stored password.
    #expect(try SecretArgs.passwordFromStdin("hunter2\r") == "hunter2")
}

@Test func passwordFromStdinRejectsEmptyAndAbsentInput() {
    #expect(throws: (any Error).self) { _ = try SecretArgs.passwordFromStdin("") }
    #expect(throws: (any Error).self) { _ = try SecretArgs.passwordFromStdin("\r") }
    // nil = EOF with nothing piped in.
    #expect(throws: (any Error).self) { _ = try SecretArgs.passwordFromStdin(nil) }
}

@Test func confirmPasswordRequiresAMatch() throws {
    #expect(try SecretArgs.confirmPassword("hunter2", "hunter2") == "hunter2")
    #expect(throws: (any Error).self) {
        _ = try SecretArgs.confirmPassword("hunter2", "hunter3")
    }
    #expect(throws: (any Error).self) { _ = try SecretArgs.confirmPassword("", "") }
}

@Test func validatePasswordRejectsOnlyEmptiness() throws {
    // No strength rule on purpose: the server has none either, so inventing one
    // here would reject passwords the web UI accepts.
    #expect(try SecretArgs.validatePassword("a") == "a")
    #expect(try SecretArgs.validatePassword(" ") == " ")
    #expect(throws: (any Error).self) { _ = try SecretArgs.validatePassword("") }
}
