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

@Test func claudeLaunchArgsResumeSuffix() {
    #expect(ClaudeLaunchArgs.resumeSuffix(nil) == "")
    #expect(ClaudeLaunchArgs.resumeSuffix("  ") == "")
    #expect(ClaudeLaunchArgs.resumeSuffix("abc-123") == " --resume 'abc-123'")
    #expect(ClaudeLaunchArgs.resumeSuffix("has'quote") == " --resume 'has'\\''quote'")
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

@Test func claudeLaunchArgsAutoPermissionDoesNotBypassOrAddDir() {
    // CROW-1176 / CROW-1215: Claude ≥ 2.1.257 can stall on the first extra-workdir
    // Read in auto mode. Crow keeps `--permission-mode auto` and does not paper
    // over that prompt with bypass, a blanket `--add-dir`, or `--permission-prompts
    // none` (print-mode only; declined).
    let s = ClaudeLaunchArgs.argsSuffix(
        remoteControl: true, sessionName: "Manager", autoPermissionMode: true)
    #expect(s.contains("--permission-mode auto"))
    #expect(!s.contains("--dangerously-skip-permissions"))
    #expect(!s.contains("bypassPermissions"))
    #expect(!s.contains("--add-dir"))
    #expect(!s.contains("--permission-prompts"))
    #expect(s == " --permission-mode auto --rc --name 'Manager'")
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
    #expect(prefix == "export ANTHROPIC_BASE_URL='https://corveil.io' CLAUDE_CODE_AUTO_MODE_SERVER=1 ANTHROPIC_CUSTOM_HEADERS='x-citadel-api-key: Bearer sk-1' && ")
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
    #expect(prefix == "unset ANTHROPIC_CUSTOM_HEADERS && export ANTHROPIC_BASE_URL='https://corveil.io' CLAUDE_CODE_AUTO_MODE_SERVER=1 && ")
    #expect(prefix.contains("unset ANTHROPIC_CUSTOM_HEADERS"))
    #expect(prefix.contains("export ANTHROPIC_BASE_URL='https://corveil.io'"))
    #expect(!prefix.contains("\n"))
}

// MARK: - Auto-mode server check behind a gateway (CROW-1426)

@Test func gatewayEnvPrefixKeepsAutoModeServerCheckOn() throws {
    // Claude Code ≥ 2.1.319 asks about or denies calls the server can't check
    // behind a gateway; `=1` keeps the server check on even when the user's
    // shell sets CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS. Both header shapes
    // carry it.
    for headers in ["x-citadel-api-key: Bearer sk-1", "x-a: one\nx-b: two"] {
        let prefix = ClaudeLaunchArgs.gatewayEnvPrefix(
            GatewayResolver.Resolved(baseURL: "https://corveil.io", customHeaders: headers))
        #expect(prefix.contains(" CLAUDE_CODE_AUTO_MODE_SERVER=1 "))
        // Classifier auto mode, never a bypass, and never the local fallback.
        #expect(!prefix.contains("CLAUDE_CODE_AUTO_MODE_SERVER=0"))
        #expect(!prefix.contains("--dangerously-skip-permissions"))
        #expect(!prefix.contains("bypassPermissions"))
    }
}

@Test func gatewayEnvPrefixOmitsAutoModeServerWithoutGateway() throws {
    // No gateway → first-party API, where the server check is the default.
    // Nothing to pin, and the operator's own value is left alone.
    #expect(!ClaudeLaunchArgs.gatewayEnvPrefix(nil).contains("CLAUDE_CODE_AUTO_MODE_SERVER"))
}

@Test func autoModeServerRidesLaunchLineNotSettingsEnv() throws {
    // CROW-1426: the settings.local.json `env` block outranks the operator's
    // ~/.claude/settings.json, so writing the var there would take away their
    // `=0` escape hatch for a gateway that drops the check. Launch line only.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("crow-1426-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    ClaudeHookConfigWriter.writeGatewayEnv(
        dirPath: dir.path,
        resolved: GatewayResolver.Resolved(
            baseURL: "https://corveil.io", customHeaders: "x-citadel-api-key: Bearer sk-1"))
    let written = try String(
        contentsOf: dir.appendingPathComponent(".claude/settings.local.json"), encoding: .utf8)
    #expect(written.contains("ANTHROPIC_BASE_URL"))
    #expect(!written.contains("CLAUDE_CODE_AUTO_MODE_SERVER"))
}
