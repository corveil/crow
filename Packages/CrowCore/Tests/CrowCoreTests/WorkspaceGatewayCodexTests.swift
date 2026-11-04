import Foundation
import Testing
@testable import CrowCore

/// CROW-1407: `WorkspaceGateway.codexUpstream`, the per-gateway Codex opt-in.
@Suite("WorkspaceGateway codexUpstream")
struct WorkspaceGatewayCodexTests {
    private func decode(_ json: String) throws -> WorkspaceGateway {
        try JSONDecoder().decode(WorkspaceGateway.self, from: Data(json.utf8))
    }

    @Test func absentByDefaultSoExistingGatewaysDoNotRouteCodex() throws {
        let g = try decode(#"{"baseURL":"https://corveil.io","customHeaders":{"x-citadel-api-key":"k"}}"#)
        #expect(g.codexUpstream == nil)
        // And it stays off the wire when unset, so an older Crow reading this
        // config sees exactly the shape it always did.
        let encoded = String(data: try JSONEncoder().encode(g), encoding: .utf8) ?? ""
        #expect(!encoded.contains("codexUpstream"))
    }

    @Test func roundTripsEveryMode() throws {
        for mode in CodexUpstream.allCases {
            let g = WorkspaceGateway(baseURL: "https://corveil.io", customHeaders: ["k": "v"], codexUpstream: mode)
            let back = try JSONDecoder().decode(WorkspaceGateway.self, from: JSONEncoder().encode(g))
            #expect(back == g)
        }
        #expect(try decode(#"{"baseURL":"u","customHeaders":{"k":"v"},"codexUpstream":"openai_api"}"#)
            .codexUpstream == .openaiAPI)
    }

    @Test func unknownOrMistypedValueDecodesAsOffInsteadOfFailing() throws {
        // A failed gateway decode would make the whole config unreadable, and the
        // next write would reset it to defaults. Unknown reads as "not routed".
        #expect(try decode(#"{"baseURL":"u","customHeaders":{"k":"v"},"codexUpstream":"future_mode"}"#)
            .codexUpstream == nil)
        #expect(try decode(#"{"baseURL":"u","customHeaders":{"k":"v"},"codexUpstream":7}"#)
            .codexUpstream == nil)
    }

    @Test func carryingKeepsTheStoredOptInOnlyWhenTheNewOneIsUnset() {
        let stored = WorkspaceGateway(baseURL: "a", customHeaders: ["k": "v"], codexUpstream: .auto)
        let rebuilt = WorkspaceGateway(baseURL: "b", customHeaders: ["k": "v2"])
        #expect(rebuilt.carryingCodexUpstream(from: stored).codexUpstream == .auto)
        #expect(rebuilt.carryingCodexUpstream(from: stored).baseURL == "b")
        let explicit = WorkspaceGateway(baseURL: "b", customHeaders: ["k": "v"], codexUpstream: .openaiAPI)
        #expect(explicit.carryingCodexUpstream(from: stored).codexUpstream == .openaiAPI)
        #expect(rebuilt.carryingCodexUpstream(from: nil).codexUpstream == nil)
    }

    @Test func keyRotationKeepsTheOptIn() {
        let g = WorkspaceGateway(baseURL: "a", customHeaders: ["x-citadel-api-key": "old"], codexUpstream: .chatgptCodex)
        let rotated = g.rewritingGatewayKey(from: "old", to: "new")
        #expect(rotated.customHeaders["x-citadel-api-key"] == "new")
        #expect(rotated.codexUpstream == .chatgptCodex)
    }

    @Test func transportStripKeepsTheOptInButBlanksSecrets() {
        var config = AppConfig()
        config.managerGateway = WorkspaceGateway(
            baseURL: "https://corveil.io", customHeaders: ["x-citadel-api-key": "secret"], codexUpstream: .auto)
        let stripped = SettingsSecrets.strippedForTransport(config)
        #expect(stripped.managerGateway?.customHeaders["x-citadel-api-key"] == "")
        #expect(stripped.managerGateway?.codexUpstream == .auto)
    }
}
