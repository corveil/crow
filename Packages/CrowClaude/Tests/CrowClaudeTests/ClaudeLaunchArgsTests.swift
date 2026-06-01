import Foundation
import Testing
import CrowCore
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

// MARK: - Launch-line gateway prefix (ClaudeLaunchArgs.gatewayEnvPrefix, CROW-402)

@Test func gatewayEnvPrefixUnsetsWhenNil() throws {
    // No gateway → explicitly unset so a global ~/.zshrc export (or a sibling
    // workspace's gateway) can't bleed into this launch.
    #expect(ClaudeLaunchArgs.gatewayEnvPrefix(nil) == "unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS && ")
}

@Test func gatewayEnvPrefixExportsSingleHeader() throws {
    // Single header → both vars go on the launch line via `export … &&` so they
    // compose in front of any OTEL `export … &&` prefix and reach `claude`.
    let resolved = GatewayResolver.Resolved(
        baseURL: "https://corveil.io",
        customHeaders: "x-citadel-api-key: Bearer sk-1"
    )
    let prefix = ClaudeLaunchArgs.gatewayEnvPrefix(resolved)
    #expect(prefix == "export ANTHROPIC_BASE_URL='https://corveil.io' ANTHROPIC_CUSTOM_HEADERS='x-citadel-api-key: Bearer sk-1' && ")
    #expect(!prefix.contains("\n"))
}

@Test func gatewayEnvPrefixUnsetsInheritedHeadersForMultiLine() throws {
    // A multi-header value has an embedded newline; pasting it onto the launch
    // line would submit the command early, so it's carried by settings.local.json.
    // The prefix must still `unset ANTHROPIC_CUSTOM_HEADERS` so the gateway's
    // baseURL isn't paired with a stale ~/.zshrc-inherited header value, and must
    // not contain a raw newline.
    let resolved = GatewayResolver.Resolved(
        baseURL: "https://corveil.io",
        customHeaders: "x-a: one\nx-b: two"
    )
    let prefix = ClaudeLaunchArgs.gatewayEnvPrefix(resolved)
    #expect(prefix == "unset ANTHROPIC_CUSTOM_HEADERS && export ANTHROPIC_BASE_URL='https://corveil.io' && ")
    #expect(prefix.contains("unset ANTHROPIC_CUSTOM_HEADERS"))
    #expect(prefix.contains("export ANTHROPIC_BASE_URL='https://corveil.io'"))
    #expect(!prefix.contains("\n"))
}
