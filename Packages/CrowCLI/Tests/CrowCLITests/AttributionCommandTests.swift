import ArgumentParser
import CrowCore
import CrowIPC
import Foundation
import Testing
@testable import CrowCLILib

// MARK: - `crow attribution` (CROW-1533)
//
// `render` takes the RPC transport as a closure, so these run without a socket.

private let sessionID = "A416EFE8-37D2-4019-B280-2062FA69455F"
private let fakeGatewayKey = "sk-citadel-TESTTESTTEST"

/// A fake daemon answering `get-session` and `automation-get`. Records every
/// call so a test can assert what was (and wasn't) asked.
private final class FakeDaemon: @unchecked Sendable {
    var agentKind: String? = "claude-code"
    var model: JSONValue = .string("claude-opus-5-5")
    var attributionModel: JSONValue? = .bool(true)
    var configReadable = true
    var sessionKnown = true
    var unreachable = false
    private(set) var calls: [(String, [String: JSONValue])] = []

    struct Unreachable: Error {}
    struct NotFound: Error {}

    func call(_ method: String, _ params: [String: JSONValue]) throws -> [String: JSONValue] {
        calls.append((method, params))
        if unreachable { throw Unreachable() }
        switch method {
        case "get-session":
            guard sessionKnown else { throw NotFound() }
            var session: [String: JSONValue] = [
                "id": .string(sessionID),
                "name": .string("crow-1533"),
                "context": .object(["model": model, "tokens": .int(1000)]),
                // Gateway-ish fields a real payload can carry. The verb must
                // never echo them.
                "gateway_base_url": .string("https://gateway.example/\(fakeGatewayKey)"),
                "gateway_set": .bool(true),
                "agent_display_name": .string("Evil $(id) \(fakeGatewayKey)"),
            ]
            if let agentKind { session["agent_kind"] = .string(agentKind) }
            return session
        case "automation-get":
            var automation: [String: JSONValue] = ["config_readable": .bool(configReadable)]
            if let attributionModel { automation["attribution_model"] = attributionModel }
            return ["automation": .object(automation)]
        default:
            Issue.record("unexpected RPC \(method)")
            return [:]
        }
    }

    var methods: [String] { calls.map(\.0) }
}

private func render(
    _ kind: CrowAttribution.FooterKind = .review,
    session: String? = nil,
    noModel: Bool = false,
    environment: [String: String] = ["CROW_SESSION_ID": sessionID],
    daemon: FakeDaemon
) -> String {
    Attribution.render(
        kind: kind, session: session, noModel: noModel,
        environment: environment, call: daemon.call)
}

private let reviewNoModel = "[🐦‍⬛ Reviewed by Crow via Claude Code](https://github.com/corveil/crow)"

@Test func attributionPrintsReviewFooterWithModel() {
    let daemon = FakeDaemon()
    #expect(render(daemon: daemon) ==
        "[🐦‍⬛ Reviewed by Crow via Claude Code · claude-opus-5-5](https://github.com/corveil/crow)")
    #expect(daemon.calls.first?.1["session_id"] == .string(sessionID))
}

@Test func attributionPrintsCreatedFooterWithModel() {
    let daemon = FakeDaemon()
    daemon.agentKind = "codex"
    daemon.model = .string("gpt-5.5-codex")
    #expect(render(.created, daemon: daemon) ==
        "[🐦‍⬛ Created with Crow via OpenAI Codex · gpt-5.5-codex](https://github.com/corveil/crow)")
}

@Test func attributionHonoursTheConfigOptOut() {
    let daemon = FakeDaemon()
    daemon.attributionModel = .bool(false)
    #expect(render(daemon: daemon) == reviewNoModel)
}

/// When the setting can't be read, leave the model out: an opt-out must not
/// silently come back.
@Test func attributionLeavesModelOutWhenTheSettingIsUnreadable() {
    let missingKey = FakeDaemon()
    missingKey.attributionModel = nil
    #expect(render(daemon: missingKey) == reviewNoModel)

    let corrupt = FakeDaemon()
    corrupt.configReadable = false
    #expect(render(daemon: corrupt) == reviewNoModel)
}

@Test func attributionNoModelFlagSkipsTheModel() {
    let daemon = FakeDaemon()
    #expect(render(noModel: true, daemon: daemon) == reviewNoModel)
    #expect(!daemon.methods.contains("automation-get"))
}

@Test func attributionHarnessWithoutModelPrintsFooterWithoutModel() {
    let daemon = FakeDaemon()
    daemon.agentKind = "cursor"
    daemon.model = .null
    #expect(render(daemon: daemon) ==
        "[🐦‍⬛ Reviewed by Crow via Cursor](https://github.com/corveil/crow)")
}

@Test func attributionWithoutSessionPrintsFooterWithoutModel() {
    let daemon = FakeDaemon()
    #expect(render(environment: [:], daemon: daemon) == reviewNoModel)
    #expect(daemon.calls.isEmpty)
}

@Test func attributionUnknownSessionPrintsFooterWithoutModel() {
    let daemon = FakeDaemon()
    daemon.sessionKnown = false
    #expect(render(daemon: daemon) == reviewNoModel)
}

@Test func attributionMalformedSessionIsNeverSentToTheDaemon() {
    let daemon = FakeDaemon()
    #expect(render(session: "not-a-uuid; rm -rf /", daemon: daemon) == reviewNoModel)
    #expect(daemon.calls.isEmpty)
}

@Test func attributionUnreachableDaemonPrintsFooterWithoutModel() {
    let daemon = FakeDaemon()
    daemon.unreachable = true
    // Without a session payload the environment names the harness.
    #expect(render(environment: ["CROW_SESSION_ID": sessionID, "CROW_AGENT_KIND": "codex"], daemon: daemon) ==
        "[🐦‍⬛ Reviewed by Crow via OpenAI Codex](https://github.com/corveil/crow)")
}

@Test func attributionExplicitSessionBeatsTheEnvironment() {
    let other = "11111111-2222-3333-4444-555555555555"
    let daemon = FakeDaemon()
    daemon.agentKind = "codex"
    daemon.model = .string("gpt-5.5")
    let out = render(
        session: other,
        environment: ["CROW_SESSION_ID": sessionID, "CROW_AGENT_DISPLAY_NAME": "Claude Code"],
        daemon: daemon)
    #expect(out == "[🐦‍⬛ Reviewed by Crow via OpenAI Codex · gpt-5.5](https://github.com/corveil/crow)")
    #expect(daemon.calls.first?.1["session_id"] == .string(other))
}

/// The model string is untrusted end to end, not just in CrowCore.
@Test(arguments: [
    "x$(id)",
    "`id`",
    "a](https://evil.example)",
    "arn:aws:bedrock:us-east-1:123456789012:inference-profile/x",
    String(repeating: "a", count: 65),
    "",
])
func attributionDropsUnsafeModel(_ model: String) {
    let daemon = FakeDaemon()
    daemon.model = .string(model)
    #expect(render(daemon: daemon) == reviewNoModel)
}

/// The verb never reads gateway headers or the payload's gateway fields, so a
/// key can't reach a footer. `agent_display_name` is ignored too: the name
/// comes from `agent_kind` through Crow's own table.
@Test func attributionNeverPrintsGatewayValues() {
    let environment = [
        "CROW_SESSION_ID": sessionID,
        "ANTHROPIC_CUSTOM_HEADERS": "x-corveil-key: \(fakeGatewayKey)",
        "CROW_CORVEIL_GATEWAY_KEY": fakeGatewayKey,
    ]
    for kind in CrowAttribution.FooterKind.allCases {
        for noModel in [false, true] {
            let out = render(kind, noModel: noModel, environment: environment, daemon: FakeDaemon())
            #expect(!out.contains(fakeGatewayKey), "\(kind) noModel=\(noModel): \(out)")
            #expect(!out.contains("gateway"))
            #expect(!out.contains("$("))
        }
    }
}

// MARK: - Parsing

@Test func attributionParsesKindAndFlags() throws {
    let cmd = try Attribution.parse(["--kind", "created", "--session", sessionID, "--no-model"])
    #expect(cmd.kind == .created)
    #expect(cmd.session == sessionID)
    #expect(cmd.noModel)

    let bare = try Attribution.parse(["--kind", "review"])
    #expect(bare.kind == .review)
    #expect(bare.session == nil)
    #expect(!bare.noModel)
}

@Test func attributionRejectsUnknownOrMissingKind() {
    #expect(throws: (any Error).self) { _ = try Attribution.parse(["--kind", "approved"]) }
    #expect(throws: (any Error).self) { _ = try Attribution.parse([]) }
}

@Test func attributionIsRegistered() throws {
    #expect(try CrowCommand.parseAsRoot(["attribution", "--kind", "review"]) is Attribution)
}
