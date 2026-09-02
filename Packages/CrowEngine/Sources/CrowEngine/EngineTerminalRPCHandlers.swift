import CrowClaude
import CrowCore
import CrowIPC
import CrowPersistence
import CrowTerminal
import Foundation

/// Terminal lifecycle and `send`.
///
/// Extracted from `makeEngineRouter`'s dictionary literal (CROW-1174). These
/// methods have no daemon registration — `crowd` answers them only via
/// `fallback: makeEngineRouter(ctx)`. `rename-terminal` is daemon-owned and
/// is not registered here.
@MainActor
func makeEngineTerminalHandlers(
    appState: AppState,
    store: JSONStore,
    sessionService: SessionService,
    telemetryPort: UInt16?,
    devRoot: String
) -> [String: CommandRouter.Handler] {
    let capturedAppState = appState
    let capturedStore = store
    let capturedService = sessionService
    let capturedTelemetryPort = telemetryPort
    // The explicit annotation is load-bearing, not decoration: a large
    // dictionary of closures without a contextual type blows Swift's
    // type-checker solver budget (CROW-1134 / CROW-1174).
    let handlers: [String: CommandRouter.Handler] = [
        "new-terminal": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr) else {
                throw RPCError.invalidParams("session_id required")
            }
            // cwd is optional (#639): the web UI's "+" add-terminal button
            // sends only session_id — it can't reliably know the worktree
            // path. Default to the session's primary worktree — mirroring
            // SessionService.addTerminal — then devRoot, so the derived
            // path always satisfies the traversal guard below.
            let cwd: String
            if let explicit = params["cwd"]?.stringValue, !explicit.isEmpty {
                cwd = explicit
            } else {
                cwd = await MainActor.run {
                    capturedAppState.primaryWorktree(for: sessionID)?.worktreePath ?? devRoot
                }
            }
            // Validate cwd is within devRoot to prevent path traversal
            guard Validation.isPathWithinRoot(cwd, root: devRoot) else {
                throw RPCError.invalidParams("Terminal cwd must be within the configured devRoot")
            }
            let rawCommand = params["command"]?.stringValue
            let isManaged = params["managed"]?.boolValue ?? false
            return await MainActor.run {
                // Resolve claude binary path if command references claude; also
                // inject --rc --name when remote control is enabled so the session
                // appears in claude.ai's Remote Control panel under the Crow
                // session name.
                var command = rawCommand
                var rcInjected = false
                let session = capturedAppState.sessions.first(where: { $0.id == sessionID })
                let sessionName = session?.name
                // The default managed-terminal name is the configured agent's
                // displayName (CROW-427) — Cursor sessions read "Cursor",
                // Codex sessions read "OpenAI Codex", etc. When the session
                // can't be found yet, fall back to the AppState default kind.
                let agentKind = session?.agentKind ?? capturedAppState.defaultAgentKind
                let defaultName = isManaged ? agentKind.displayName : "Shell"
                let terminalName = params["name"]?.stringValue ?? defaultName
                if let cmd = rawCommand, cmd.contains("claude") {
                    let rcEnabled = capturedAppState.remoteControlEnabled
                    command = EngineHelpers.resolveClaudeInCommand(
                        cmd,
                        remoteControl: rcEnabled,
                        sessionName: sessionName
                    )
                    rcInjected = rcEnabled
                        && !cmd.contains("--rc")
                        && !cmd.contains("--remote-control")
                }
                let trackReadiness = isManaged
                // Brand-new managed terminals DEFER their agent launch until
                // the shell signals readiness (issue #408). Pasting the launch
                // command immediately races the shell's line editor (zle): if
                // the prompt isn't live yet the keystrokes are dropped and the
                // window is left at a bare zsh with no agent. Instead hold the
                // command in `pendingLaunchCommands` and register the window
                // with `command: nil`, so the deferred paste happens in
                // `SessionService.wireTerminalReadiness` on `.shellReady`.
                let hasCommand = !(command?.isEmpty ?? true)
                let deferLaunch = trackReadiness && hasCommand
                let registerCommand = deferLaunch ? nil : command
                // Every session, including the Manager (#314), runs on
                // tmux (#303). Register the tmux window now — its shell
                // starts immediately, so there's no offscreen pre-init.
                //
                // Persist `registerCommand` (nil for a deferred launch), NOT
                // the raw launch command: the launch lives in
                // `pendingLaunchCommands` (in-memory) and the persisted row
                // must not carry it, or the hydrate-fresh fallback would
                // blind-paste it into a not-yet-ready shell on the recovery
                // path — the very race this fixes (#408). A restored managed
                // terminal relaunches via the autoLaunch/launchAgent path.
                var terminal = SessionTerminal(
                    sessionID: sessionID,
                    name: terminalName,
                    cwd: cwd,
                    command: registerCommand,
                    isManaged: isManaged,
                    backend: .tmux
                )
                // Seed readiness + pending-launch state BEFORE registering so
                // the sentinel's `.shellReady` (which can only fire on a later
                // main-actor turn) always finds the pending command and the
                // autoLaunch membership populated.
                if trackReadiness {
                    capturedAppState.terminalReadiness[terminal.id] = .uninitialized
                }
                if deferLaunch, let command {
                    capturedAppState.pendingLaunchCommands[terminal.id] = command
                    // Membership lets the existing `.timedOut` re-arm machinery
                    // (`reArmStuckReadinessWatches`) recover a slow launch.
                    capturedAppState.autoLaunchTerminals.insert(terminal.id)
                }
                var launchFailed = false
                do {
                    // Bounded retry with a modestly-longer per-call `new-window`
                    // budget: under load the tmux subprocess can exceed the 2s
                    // default and get SIGTERM'd, leaving a window-less terminal
                    // (#408). This runs inside `MainActor.run`, so the budget is
                    // kept tight (2 attempts × 3s) to cap worst-case main-actor
                    // stall at ~6s rather than beachballing concurrent RPCs.
                    let binding = try EngineHelpers.registerWithRetry(attempts: 2) { _ in
                        try TmuxBackend.shared.registerTerminal(
                            id: terminal.id,
                            name: terminalName,
                            cwd: cwd,
                            command: registerCommand,
                            trackReadiness: trackReadiness,
                            agentKind: agentKind,
                            // Agent TUIs get the alt-buffer scroll model;
                            // plain shells keep the unified scrollback
                            // (ADR-0013). `agentKind` can't discriminate —
                            // it always resolves to a default.
                            agentSurface: terminal.isAgentSurface(session: session),
                            usesAlternateScreen: AgentRegistry.shared.usesAlternateScreen(for: session?.agentKind),
                            newWindowTimeout: 3.0
                        )
                    }
                    terminal.tmuxBinding = binding
                } catch {
                    // The tmux window never materialized. Don't pretend the
                    // launch succeeded (#408): surface it so the UI shows a
                    // Retry affordance and the CLI caller reports honestly
                    // instead of leaving a silent window-less terminal.
                    CrowLog.info("[Crow] tmux registerTerminal failed after retries (\(error)); surfacing launch failure")
                    launchFailed = true
                    if trackReadiness {
                        capturedAppState.terminalReadiness[terminal.id] = .failed
                    }
                    capturedAppState.pendingLaunchCommands.removeValue(forKey: terminal.id)
                    capturedAppState.autoLaunchTerminals.remove(terminal.id)
                }
                capturedAppState.terminals[sessionID, default: []].append(terminal)
                capturedStore.mutate { $0.terminals.append(terminal) }
                if trackReadiness {
                    TerminalRouter.trackReadiness(for: terminal)
                }
                if rcInjected {
                    capturedAppState.remoteControlActiveTerminals.insert(terminal.id)
                }
                var result: [String: JSONValue] = [
                    "terminal_id": .string(terminal.id.uuidString),
                    "session_id": .string(idStr),
                ]
                if launchFailed { result["launch_failed"] = .bool(true) }
                return result
            }
        },

        "list-terminals": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw RPCError.invalidParams("session_id required")
            }
            let terms = await MainActor.run { capturedAppState.terminals(for: id) }
            let readiness = await MainActor.run { capturedAppState.terminalReadiness }
            // Windows stuck in the alternate-screen buffer or capped at the
            // old 5000-line history-limit can't show full scroll-up history
            // and can only be healed by recreation (CROW-804). Read the live
            // set once so the web UI can badge the affected tabs.
            // Paired with which windows run the agent-TUI scroll model
            // (ADR-0013) — read from tmux (`alternate-screen` per window)
            // rather than inferred client-side, so `app.js` routes the wheel
            // on the SAME ground truth the daemon actually applied. One
            // combined read so this RPC forks a single `tmux` subprocess.
            // `nil` means the read FAILED (tmux down / timed out), which is
            // not the same as "no such windows" — see the agent_surface
            // fallback below.
            let classification = await MainActor.run {
                TmuxBackend.shared.windowScrollbackClassification()
            }
            let degraded = classification?.degraded ?? []
            // For the fallback below, when tmux couldn't answer.
            let session = await MainActor.run {
                capturedAppState.sessions.first(where: { $0.id == id })
            }
            let items: [JSONValue] = terms.map { t in
                // `readiness` lets CLI callers (setup.sh) verify the agent
                // actually started rather than assuming a launch succeeded
                // (#408). Defaults to `uninitialized` for un-tracked shells.
                .object([
                    "id": .string(t.id.uuidString),
                    "name": .string(t.name),
                    "session_id": .string(t.sessionID.uuidString),
                    "managed": .bool(t.isManaged),
                    // `window` is the tmux window index the web `/terminal` WS
                    // selects to stream this terminal. The web UI shows a blank
                    // pane without it (the retired curated daemon handler used
                    // to provide it — CROW-593 review regression).
                    "window": t.tmuxBinding.map { .int($0.windowIndex) } ?? .null,
                    "readiness": .string((readiness[t.id] ?? .uninitialized).rawValue),
                    // True when this terminal's window has degraded scrollback
                    // and needs a recreate (CROW-804). Never degraded when
                    // there's no window binding yet.
                    "scrollback_degraded": .bool(t.tmuxBinding.map { degraded.contains($0.windowIndex) } ?? false),
                    // True when this terminal is an agent-TUI surface that
                    // owns its own viewport + scrollback (ADR-0013). The web
                    // client routes the wheel and the mouse-mode swallow on
                    // this.
                    //
                    // tmux is authoritative when it ANSWERED and this
                    // terminal has a window. Otherwise — no binding yet, or
                    // the read failed — fall back to the SAME predicate the
                    // daemon registers the window with, so the two agree
                    // (including for the Manager, whose terminal carries no
                    // `isManaged` flag). Failing to `false` instead would
                    // tell the client to swallow mouse modes and scroll
                    // locally while tmux has that window in the alt buffer,
                    // where there is no scrollback to scroll.
                    "agent_surface": .bool(
                        classification.flatMap { c in
                            t.tmuxBinding.map { c.agentSurfaces.contains($0.windowIndex) }
                        } ?? t.isAgentSurface(session: session)),
                    // Sibling of `agent_surface` (CROW-1010, redefined
                    // CROW-1023). True only for a window that has actually
                    // entered the alt buffer. The client caps xterm
                    // scrollback to 0 on THIS — not on `agent_surface` alone
                    // — so an inline agent (Cursor, AND an inline-rendering
                    // Claude Code build) keeps the unified 50k, and the #850
                    // local wheel + the CROW-1020 scrollbar have something to
                    // scroll.
                    //
                    // CROW-1023: detected per-window from the runtime
                    // `#{alternate_on}` read, latched sticky
                    // (`observedAltBufferWindows`) — NOT the static per-kind
                    // capability. Two Claude Code builds diverge: one enters
                    // the alt buffer (`alt_on=1`), one renders inline
                    // (`alt_on=0`), and only a runtime read separates them.
                    // The `AgentRegistry` capability survives as the
                    // pre-window / read-failure prior (no window observed
                    // yet), mirroring the `agent_surface` fallback above.
                    "uses_alternate_screen": .bool(
                        classification.flatMap { c in
                            t.tmuxBinding.map { c.altBuffer.contains($0.windowIndex) }
                        } ?? AgentRegistry.shared.usesAlternateScreen(for: session?.agentKind)),
                ])
            }
            return ["terminals": .array(items)]
        },

        "close-terminal": { @Sendable params in
            guard let sessionIDStr = params["session_id"]?.stringValue,
                  let sessionID = UUID(uuidString: sessionIDStr),
                  let terminalIDStr = params["terminal_id"]?.stringValue,
                  let terminalID = UUID(uuidString: terminalIDStr) else {
                throw RPCError.invalidParams("session_id and terminal_id required")
            }
            return try await MainActor.run {
                guard let terminals = capturedAppState.terminals[sessionID],
                      let terminal = terminals.first(where: { $0.id == terminalID }) else {
                    throw RPCError.applicationError("Terminal not found")
                }
                guard !terminal.isManaged else {
                    throw RPCError.applicationError("Cannot close managed terminal")
                }
                TerminalRouter.destroy(terminal)
                capturedAppState.terminals[sessionID]?.removeAll { $0.id == terminalID }
                capturedAppState.terminalReadiness.removeValue(forKey: terminalID)
                capturedAppState.autoLaunchTerminals.remove(terminalID)
                capturedAppState.pendingLaunchCommands.removeValue(forKey: terminalID)
                if capturedAppState.activeTerminalID[sessionID] == terminalID {
                    capturedAppState.activeTerminalID[sessionID] = capturedAppState.terminals[sessionID]?.first?.id
                }
                capturedStore.mutate { data in data.terminals.removeAll { $0.id == terminalID } }
                return ["deleted": .bool(true)]
            }
        },

        // Heal a terminal whose tmux window has degraded scrollback — stuck
        // in the alternate-screen buffer and/or capped at the old 5000-line
        // history-limit, which tmux can't fix in place (CROW-804). Kills the
        // window and rebuilds a fresh, correctly-configured one, relaunching
        // the agent (`claude --continue`). Destructive to the running agent,
        // so the web UI confirms before calling this.
        "recreate-terminal": { @Sendable params in
            guard let sessionIDStr = params["session_id"]?.stringValue,
                  let sessionID = UUID(uuidString: sessionIDStr),
                  let terminalIDStr = params["terminal_id"]?.stringValue,
                  let terminalID = UUID(uuidString: terminalIDStr) else {
                throw RPCError.invalidParams("session_id and terminal_id required")
            }
            return try await MainActor.run {
                guard capturedService.recreateTerminalSurface(
                    sessionID: sessionID, terminalID: terminalID, devRoot: devRoot) else {
                    // False = terminal not found OR the fresh tmux window
                    // failed to register (the old window was killed, so the
                    // terminal is now unbound). Surface it either way (CROW-804).
                    throw RPCError.applicationError("Could not recreate terminal (not found or tmux window failed to register)")
                }
                return ["recreated": .bool(true)]
            }
        },

        "send": { @Sendable params in
            guard let sessionIDStr = params["session_id"]?.stringValue,
                  let sessionID = UUID(uuidString: sessionIDStr),
                  let terminalIDStr = params["terminal_id"]?.stringValue,
                  let terminalID = UUID(uuidString: terminalIDStr),
                  var text = params["text"]?.stringValue else {
                throw RPCError.invalidParams("session_id, terminal_id, and text required")
            }
            // Process escape sequences: literal \n in the text becomes a real newline
            text = text.replacingOccurrences(of: "\\n", with: "\n")
            text = text.replacingOccurrences(of: "\\t", with: "\t")
            CrowLog.info("crow send: text length=\(text.count), ends_with_newline=\(text.hasSuffix("\n")), ends_with_cr=\(text.hasSuffix("\r"))")
            // Resolved OFF the MainActor: `resolveCrowBinary` stats and may
            // create the `.claude/bin/crow` symlink, and blocking I/O on the
            // MainActor is what wedged the daemon's RPC surface in #892.
            // It only needs `devRoot`, so hoisting costs nothing.
            let crowPath = ClaudeHookConfigWriter.resolveCrowBinary(devRoot: devRoot)
            await MainActor.run {
                let routedTerminal = capturedAppState.terminals[sessionID]?.first(where: { $0.id == terminalID })
                // tmux-backed terminals already have their window from
                // registerTerminal — no surface recovery needed before send.

                // For managed terminals receiving an agent-launching
                // command, write hook config (and inject OTEL env vars
                // for Claude) before forwarding so the agent picks up
                // hooks on startup. The agent dispatch is driven by the
                // session's `agentKind` and the agent's
                // `launchCommandToken` (e.g. "claude", "codex").
                if let terminals = capturedAppState.terminals[sessionID],
                   let terminal = terminals.first(where: { $0.id == terminalID }),
                   terminal.isManaged,
                   let session = capturedAppState.sessions.first(where: { $0.id == sessionID }),
                   let agent = AgentRegistry.shared.agent(for: session.agentKind) {
                    let wtPath = capturedAppState.primaryWorktree(for: sessionID)?.worktreePath
                    // #861 review r17 (Yellow 1): the `send` RPC is a launch path
                    // too. An operator recovering a dead Grok `.review` pane the
                    // documented way — `crow send <term> "grok -c"` — reopens the
                    // clone right here; `commandLaunchesToken("grok -c", "grok")`
                    // matches. So strip the clone's committed config + seed trust
                    // FIRST, via the SAME shared gate as the four SessionService
                    // paths, before `prepareAgentLaunchText` (re)writes Crow's clean
                    // `.grok/hooks/crow.json` — otherwise a hostile `.grok/hooks/*.json`
                    // restored by the review skill's `gh pr checkout` fires on that
                    // resume. Gated on the same agent-launch detection as the hook
                    // write, so a plain `crow send "yes"` doesn't re-strip. Strip is
                    // a no-op unless this is a Grok `.review` clone.
                    if let wtPath,
                       AgentLaunch.commandLaunchesAgent(text, agent: agent) {
                        SessionService.prepareWorktreeForAgentLaunch(
                            agentKind: session.agentKind,
                            sessionKind: session.kind,
                            worktreePath: wtPath,
                            ownership: SessionService.HookOwnership.snapshot(
                                capturedAppState, crowPath: crowPath))
                    }
                    let prepared = AgentLaunch.prepareAgentLaunchText(
                        command: text,
                        agent: agent,
                        sessionID: sessionID,
                        worktreePath: wtPath,
                        crowPath: crowPath,
                        telemetryPort: capturedTelemetryPort
                    )
                    text = prepared.text
                    if prepared.didLaunch {
                        capturedAppState.terminalReadiness[terminalID] = .agentLaunched
                    }
                }

                if let routedTerminal {
                    TerminalRouter.send(routedTerminal, text: text)
                } else {
                    // No SessionTerminal row known — nothing to route to.
                    CrowLog.info("[Crow] crow send for unknown terminal \(terminalID); ignoring")
                }
            }
            return ["sent": .bool(true)]
        },
    ]
    return handlers
}
