import Foundation
import Testing
@testable import CrowCore

@Suite("BinaryOverrides", .serialized)
struct BinaryOverridesTests {
    /// Resets the shared override state at the end of the suite so other
    /// tests don't see leaked entries. Each test that mutates state is
    /// responsible for resetting before returning, but this is belt + braces.
    init() {
        BinaryOverrides.shared.set([:])
    }

    @Test func emptyByDefault() {
        BinaryOverrides.shared.set([:])
        #expect(BinaryOverrides.shared.path(for: .codex) == nil)
        #expect(BinaryOverrides.shared.path(for: .cursor) == nil)
        #expect(BinaryOverrides.shared.path(for: .claudeCode) == nil)
    }

    @Test func setStoresRawKeyedByAgentKind() {
        BinaryOverrides.shared.set([
            "codex": "/Users/me/.nvm/versions/node/v22/bin/codex",
            "cursor": "/tmp/agent",
        ])
        defer { BinaryOverrides.shared.set([:]) }

        #expect(BinaryOverrides.shared.path(for: .codex) == "/Users/me/.nvm/versions/node/v22/bin/codex")
        #expect(BinaryOverrides.shared.path(for: .cursor) == "/tmp/agent")
        #expect(BinaryOverrides.shared.path(for: .claudeCode) == nil)
    }

    @Test func setReplacesPreviousMap() {
        BinaryOverrides.shared.set(["codex": "/tmp/codex-a"])
        BinaryOverrides.shared.set(["cursor": "/tmp/agent"])
        defer { BinaryOverrides.shared.set([:]) }

        // Previous codex entry is gone — `set` replaces, not merges.
        #expect(BinaryOverrides.shared.path(for: .codex) == nil)
        #expect(BinaryOverrides.shared.path(for: .cursor) == "/tmp/agent")
    }

    @Test func unknownAgentKindRoundTrips() {
        // AgentKind is a RawRepresentable struct so downstream packages can
        // register their own kinds. The override map should accept and
        // surface arbitrary keys.
        BinaryOverrides.shared.set(["custom-agent": "/tmp/custom"])
        defer { BinaryOverrides.shared.set([:]) }

        #expect(BinaryOverrides.shared.path(for: AgentKind(rawValue: "custom-agent")) == "/tmp/custom")
    }
}
