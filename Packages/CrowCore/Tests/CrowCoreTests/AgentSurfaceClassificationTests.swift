import Foundation
import Testing
@testable import CrowCore

/// Which terminals take the alt-buffer scroll model (ADR-0013, #824).
///
/// The classification lives in one place because the daemon uses it twice — to
/// set `alternate-screen on` at window creation/adopt, and as the
/// `list-terminals` `agent_surface` fallback before a window exists. If those
/// two ever disagree, the client routes the wheel one way while tmux is
/// configured the other.
@Suite("Agent-surface classification")
struct AgentSurfaceClassificationTests {

    private func terminal(isManaged: Bool, sessionID: UUID = UUID()) -> SessionTerminal {
        SessionTerminal(sessionID: sessionID, name: "t", cwd: "/tmp", isManaged: isManaged)
    }

    @Test func managedWorkTerminalIsAnAgentSurface() {
        let session = Session(name: "work", status: .active, kind: .work)
        #expect(terminal(isManaged: true).isAgentSurface(session: session))
    }

    @Test func plainShellIsNotAnAgentSurface() {
        // The unified 50k scrollback is the right model for line-streaming
        // output; this is the case that must NOT regress.
        let session = Session(name: "work", status: .active, kind: .work)
        #expect(!terminal(isManaged: false).isAgentSurface(session: session))
    }

    /// The regression this suite exists for. `createManagerTerminal` builds its
    /// row via `SessionTerminal(sessionID:name:cwd:command:)`, so `isManaged`
    /// takes the memberwise default of `false` — yet the Manager runs a
    /// full-frame repainting agent and was one of the windows #822 was reported
    /// against. Keying the scroll model on `isManaged` alone silently left the
    /// Manager on the sediment path.
    @Test func managerTerminalIsAnAgentSurfaceDespiteNotBeingManaged() {
        let session = Session(name: "Manager", status: .active, kind: .manager)
        let managerTerminal = SessionTerminal(
            sessionID: session.id, name: session.name, cwd: "/dev/root", command: "claude --rc")
        #expect(!managerTerminal.isManaged, "precondition: the Manager row carries no isManaged flag")
        #expect(managerTerminal.isAgentSurface(session: session))
    }

    /// The counterweight to the test above. A Manager session can hold extra
    /// plain shells — `new-terminal` with only a `session_id` (the `+` button,
    /// or `crow new-terminal --session <manager-uuid>`) produces
    /// `isManaged: false` with no command. Classifying by session kind ALONE
    /// swept those into the alt-buffer model, taking away the unified 50k
    /// scrollback from an ordinary line-streaming shell. Only the terminal that
    /// actually launches the agent qualifies.
    @Test func plainShellInAManagerSessionIsNotAnAgentSurface() {
        let session = Session(name: "Manager", status: .active, kind: .manager)
        let shell = SessionTerminal(sessionID: session.id, name: "Shell", cwd: "/dev/root")
        #expect(shell.command == nil, "precondition: an added shell carries no launch command")
        #expect(!shell.isAgentSurface(session: session))
    }

    @Test func unhydratedSessionFallsBackToIsManaged() {
        // Before the session is known we can only trust the flag we have.
        #expect(terminal(isManaged: true).isAgentSurface(session: nil))
        #expect(!terminal(isManaged: false).isAgentSurface(session: nil))
    }

    @Test func managerSessionKindDoesNotLeakAcrossSessions() {
        // A work session's plain shell stays unified even if a Manager exists.
        let work = Session(name: "work", status: .active, kind: .work)
        let shell = SessionTerminal(sessionID: work.id, name: "Shell", cwd: "/repo", command: "vim")
        #expect(!shell.isAgentSurface(session: work),
                "a command alone must not promote a work-session shell")
    }
}
