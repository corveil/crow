import Foundation
import Testing
@testable import CrowCore

@Suite("SessionTerminal Codable")
struct SessionTerminalTests {

    // MARK: - Round-trip

    @Test func fullRoundTrip() throws {
        let terminal = SessionTerminal(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            sessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Claude Code",
            cwd: "/Users/test/project",
            command: "claude --continue",
            isManaged: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(terminal)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(SessionTerminal.self, from: data)

        #expect(decoded.id == terminal.id)
        #expect(decoded.sessionID == terminal.sessionID)
        #expect(decoded.name == terminal.name)
        #expect(decoded.cwd == terminal.cwd)
        #expect(decoded.command == terminal.command)
        #expect(decoded.isManaged == true)
        #expect(decoded.createdAt == terminal.createdAt)
    }

    // MARK: - Backward Compatibility

    @Test func missingIsManagedDefaultsToFalse() throws {
        let json = """
        {
            "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "sessionID": "11111111-2222-3333-4444-555555555555",
            "name": "Shell",
            "cwd": "/Users/test",
            "createdAt": 1700000000
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let terminal = try decoder.decode(SessionTerminal.self, from: json)

        #expect(terminal.isManaged == false)
    }

    @Test func missingCommandDefaultsToNil() throws {
        let json = """
        {
            "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "sessionID": "11111111-2222-3333-4444-555555555555",
            "name": "Shell",
            "cwd": "/Users/test",
            "createdAt": 1700000000
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let terminal = try decoder.decode(SessionTerminal.self, from: json)

        #expect(terminal.command == nil)
    }

    @Test func isManagedTrueDecodesCorrectly() throws {
        let json = """
        {
            "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "sessionID": "11111111-2222-3333-4444-555555555555",
            "name": "Claude Code",
            "cwd": "/Users/test",
            "isManaged": true,
            "createdAt": 1700000000
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let terminal = try decoder.decode(SessionTerminal.self, from: json)

        #expect(terminal.isManaged == true)
    }

    // MARK: - Backend discriminator (#198 follow-up)

    /// Existing rows on disk lack `backend` and `tmuxBinding`. They must
    /// keep loading; since #303 tmux is the only backend, so a missing
    /// `backend` decodes to `.tmux`.
    @Test func missingBackendDefaultsToTmux() throws {
        let json = """
        {
            "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "sessionID": "11111111-2222-3333-4444-555555555555",
            "name": "Shell",
            "cwd": "/Users/test",
            "createdAt": 1700000000
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let terminal = try decoder.decode(SessionTerminal.self, from: json)

        #expect(terminal.backend == .tmux)
        #expect(terminal.tmuxBinding == nil)
    }

    @Test func tmuxBackendRoundTrip() throws {
        let binding = TmuxBinding(
            socketPath: "/Users/test/Library/Application Support/Crow/tmux.sock",
            sessionName: "crow-cockpit",
            windowIndex: 3
        )
        let terminal = SessionTerminal(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            sessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Build",
            cwd: "/Users/test/project",
            command: nil,
            isManaged: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            backend: .tmux,
            tmuxBinding: binding
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(terminal)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(SessionTerminal.self, from: data)

        #expect(decoded.backend == .tmux)
        #expect(decoded.tmuxBinding == binding)
    }

    /// Legacy rows persisted with an unrecognized `backend` string (before
    /// #303 collapsed the enum to a single case) must migrate forward to
    /// `.tmux` on load rather than throwing on the now-removed enum case.
    @Test func legacyUnknownBackendMigratesToTmux() throws {
        let json = """
        {
            "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "sessionID": "11111111-2222-3333-4444-555555555555",
            "name": "Shell",
            "cwd": "/Users/test",
            "isManaged": false,
            "createdAt": 1700000000,
            "backend": "legacy-unknown"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let terminal = try decoder.decode(SessionTerminal.self, from: json)

        #expect(terminal.backend == .tmux)
        #expect(terminal.tmuxBinding == nil)
    }

    @Test func tmuxBackendWithoutBindingDecodes() throws {
        // Permissive: a `.tmux` row without a binding is invalid runtime
        // state, but the model doesn't reject it — production construction
        // sites enforce the invariant.
        let json = """
        {
            "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "sessionID": "11111111-2222-3333-4444-555555555555",
            "name": "Shell",
            "cwd": "/Users/test",
            "isManaged": false,
            "createdAt": 1700000000,
            "backend": "tmux"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let terminal = try decoder.decode(SessionTerminal.self, from: json)

        #expect(terminal.backend == .tmux)
        #expect(terminal.tmuxBinding == nil)
    }
}
