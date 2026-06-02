import Foundation
import Testing
@testable import CrowClaude

@Test func claudeLaunchArgsDisabledReturnsEmpty() {
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: false, sessionName: nil) == "")
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: false, sessionName: "crow-157") == "")
}

@Test func claudeLaunchArgsEnabledNoName() {
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: nil) == " --rc")
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: "") == " --rc")
}

@Test func claudeLaunchArgsEnabledWithName() {
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: "Manager")
        == " --rc --name 'Manager'")
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: "crow-157-auto-remote-control")
        == " --rc --name 'crow-157-auto-remote-control'")
}

@Test func claudeLaunchArgsShellQuotesApostrophe() {
    // POSIX single-quote escape: '  →  '\''
    let result = ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: "Bob's session")
    #expect(result == " --rc --name 'Bob'\\''s session'")
}

@Test func claudeLaunchArgsShellQuoteBasics() {
    #expect(ClaudeLaunchArgs.shellQuote("plain") == "'plain'")
    #expect(ClaudeLaunchArgs.shellQuote("with space") == "'with space'")
    #expect(ClaudeLaunchArgs.shellQuote("has'quote") == "'has'\\''quote'")
}

@Test func claudeLaunchArgsAutoPermissionModeOnly() {
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: false, sessionName: nil, autoPermissionMode: true)
        == " --permission-mode auto")
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: false, sessionName: "Manager", autoPermissionMode: true)
        == " --permission-mode auto")
}

@Test func claudeLaunchArgsAutoPermissionModeWithRemoteControl() {
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: "Manager", autoPermissionMode: true)
        == " --permission-mode auto --rc --name 'Manager'")
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: nil, autoPermissionMode: true)
        == " --permission-mode auto --rc")
}

@Test func claudeLaunchArgsAutoPermissionModeDefaultsOff() {
    // Existing callers that don't pass autoPermissionMode should be unaffected.
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: true, sessionName: "Manager")
        == " --rc --name 'Manager'")
    #expect(ClaudeLaunchArgs.argsSuffix(remoteControl: false, sessionName: nil) == "")
}
