import ArgumentParser
import Foundation
import Testing

@testable import CrowCLILib

private let validUUID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

// MARK: - Subcommand routing

@Test func gatewayGroupRoutesToSubcommands() throws {
    #expect(try Gateway.parseAsRoot(["get", "--manager"]) is GatewayGet)
    #expect(try Gateway.parseAsRoot(
        ["set", "--manager", "--base-url", "https://gw.example.com", "--header", "K: V"]
    ) is GatewaySet)
    #expect(try Gateway.parseAsRoot(["clear", "--manager"]) is GatewayClear)
}

@Test func webPasswordGroupRoutesToSubcommands() throws {
    #expect(try WebPassword.parseAsRoot(["status"]) is WebPasswordStatus)
    #expect(try WebPassword.parseAsRoot(["set"]) is WebPasswordSet)
    #expect(try WebPassword.parseAsRoot(["clear"]) is WebPasswordClear)
}

// MARK: - Target selector

@Test func gatewayGetParsesManagerTarget() throws {
    let cmd = try GatewayGet.parse(["--manager"])
    #expect(cmd.target.manager)
    #expect(cmd.target.workspace == nil)
    #expect(!cmd.reveal)
    #expect(cmd.target.params["target"] == .string("manager"))
}

@Test func gatewayGetParsesWorkspaceTargetAndReveal() throws {
    let byName = try GatewayGet.parse(["--workspace", "Corveil", "--reveal"])
    #expect(byName.target.workspace == "Corveil")
    #expect(byName.reveal)
    #expect(byName.target.params["workspace"] == .string("Corveil"))
    // A UUID is just as valid a reference as a name.
    #expect(try GatewayGet.parse(["--workspace", validUUID]).target.workspace == validUUID)
}

@Test func gatewayTargetRejectsBothAndNeither() {
    for args in [["--manager", "--workspace", "Corveil"], [], ["--workspace", "  "]] {
        #expect(throws: (any Error).self, "expected \(args) to be rejected") {
            _ = try GatewayGet.parse(args)
        }
    }
}

@Test func gatewayClearRequiresATarget() throws {
    #expect(try GatewayClear.parse(["--manager"]).target.manager)
    #expect(throws: (any Error).self) { _ = try GatewayClear.parse([]) }
}

// MARK: - gateway set

@Test func gatewaySetParsesRepeatableHeaders() throws {
    let cmd = try GatewaySet.parse([
        "--manager",
        "--base-url", "https://gw.example.com",
        "--header", "X-Api-Key: sk-test-1",
        "--header", "X-Tenant: acme",
    ])
    #expect(cmd.baseURL == "https://gw.example.com")
    #expect(cmd.header == ["X-Api-Key: sk-test-1", "X-Tenant: acme"])
}

@Test func gatewaySetAcceptsBlankHeaderValue() throws {
    // "keep the stored secret" — must survive client-side validation, since it's
    // the documented way to change a base URL without restating credentials.
    let cmd = try GatewaySet.parse([
        "--manager", "--base-url", "https://gw.example.com", "--header", "X-Api-Key:",
    ])
    #expect(cmd.header == ["X-Api-Key:"])
}

@Test func gatewaySetRequiresBaseURLAndHeader() {
    // Both-or-neither: a URL with no header (and vice versa) is refused locally
    // before it reaches the daemon.
    #expect(throws: (any Error).self) {
        _ = try GatewaySet.parse(["--manager", "--base-url", "https://gw.example.com"])
    }
    #expect(throws: (any Error).self) {
        _ = try GatewaySet.parse(["--manager", "--header", "X-Api-Key: sk-test-1"])
    }
    #expect(throws: (any Error).self) {
        _ = try GatewaySet.parse([
            "--manager", "--base-url", "  ", "--header", "X-Api-Key: sk-test-1",
        ])
    }
}

@Test func gatewaySetRejectsMalformedHeaders() {
    for header in ["no-colon-here", ": orphan-value", "   "] {
        #expect(throws: (any Error).self, "expected '\(header)' to be rejected") {
            _ = try GatewaySet.parse([
                "--manager", "--base-url", "https://gw.example.com", "--header", header,
            ])
        }
    }
}

@Test func validateHeaderLineAcceptsValuesContainingColons() throws {
    try validateHeaderLine("Authorization: Bearer a:b:c")
    try validateHeaderLine("X-Api-Key: op://Vault/Item/field")
}

// MARK: - web-password

@Test func webPasswordSetParsesStdinFlag() throws {
    #expect(!(try WebPasswordSet.parse([])).stdin)
    #expect((try WebPasswordSet.parse(["--stdin"])).stdin)
}

@Test func webPasswordSetHasNoPasswordFlag() {
    // Plaintext in argv would land in shell history and local `ps` (CROW-815).
    #expect(throws: (any Error).self) {
        _ = try WebPasswordSet.parse(["--password", "hunter2"])
    }
}

@Test func webPasswordStatusAndClearTakeNoArguments() throws {
    _ = try WebPasswordStatus.parse([])
    _ = try WebPasswordClear.parse([])
    #expect(throws: (any Error).self) { _ = try WebPasswordClear.parse(["--manager"]) }
}

// MARK: - Registration

@Test func rootCommandRegistersSecretGroups() {
    let names = CrowCommand.configuration.subcommands.map { $0.configuration.commandName }
    #expect(names.contains("gateway"))
    #expect(names.contains("web-password"))
}
