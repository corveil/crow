import CrowClaude
import CrowCore
import CrowIPC
import CrowPersistence
import Foundation

// Hook ingest (`hook-event`) plus the payload helpers / once-per-cwd drop
// loggers that only this handler uses.
//
// Extracted from `makeEngineRouter`'s dictionary literal (CROW-1174). The
// daemon has no `hook-event` registration — `crowd` answers it only via
// `fallback: makeEngineRouter(ctx)`.

/// Extract the tool name from a hook payload, tolerating each harness's shape.
/// Claude/Cursor/Codex send a flat `tool_name`; Antigravity nests it as
/// `toolCall.name` (camelCase) — but **only on `PreToolUse`**. Antigravity's
/// `PostToolUse` stdin carries no tool name at all (only `stepIdx`/`error`/common
/// fields), and Crow deliberately doesn't register `PreToolUse` (its strict
/// decision gate), so for Antigravity this fallback is future-proofing for a
/// possible `PreToolUse` re-enable, not a live path — Antigravity's registered
/// `PostToolUse` tool activity is unnamed by design (a documented Tier-2 gap;
/// see `AntigravitySignalSource`). Harmless for the other harnesses (they have
/// no `toolCall` object).
func hookToolName(from payload: [String: JSONValue]) -> String? {
    if let flat = payload["tool_name"]?.stringValue { return flat }
    return payload["toolCall"]?.objectValue?["name"]?.stringValue
}

/// Extract Antigravity's conversation id from a hook stdin payload, trying the
/// documented `conversationId` and a snake_case fallback (CROW-1107). The id names
/// the transcript's `brain/<id>/…` directory, so the `hook-event` handler records
/// it against the worktree Crow owns for the session.
///
/// ⚠️ Docs-derived, pending live-verify: `agy` can't be run here, so the exact
/// field name is from Antigravity CLI docs, not first-party capture. A wrong name
/// yields no id ⇒ no map entry ⇒ nothing uploaded for that conversation — never a
/// misattribution (the worktree comes from session ownership, not the payload).
func antigravityConversationID(from payload: [String: JSONValue]) -> String? {
    for key in ["conversationId", "conversation_id"] {
        if let v = payload[key]?.stringValue {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    return nil
}

/// Extract Antigravity's transcript-path hint from a hook payload (`transcriptPath`
/// / `transcript_path`), if present — an optional locator only; the collector
/// derives the durable `transcript_full.jsonl` from the conversation id regardless
/// (CROW-1107).
func antigravityTranscriptPath(from payload: [String: JSONValue]) -> String? {
    for key in ["transcriptPath", "transcript_path"] {
        if let v = payload[key]?.stringValue {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    return nil
}

/// Payload `cwd`s already logged as unresolved hook-event drops. An unmapped
/// global hook config re-fires on every event, so without this the only
/// diagnostic channel left after #903 (see the hook-event handler) would flood
/// an unrotated launchd log. Capped so a pathological spread of cwds can't grow
/// it without limit; MainActor-isolated since its sole caller runs inside the
/// handler's `MainActor.run`. Never reset for the daemon's lifetime, so a drop
/// that gets fixed (worktree registered) and later regresses won't re-log —
/// acceptable for a diagnostic.
@MainActor private var loggedUnresolvedHookDrops: Set<String> = []

/// Neutralize a caller-supplied value before it reaches the log: cap length (the
/// per-set count caps bound record *count*; this bounds record *size*), and
/// escape every C0 control (and DEL) so an embedded ESC/ANSI sequence can't
/// mangle a terminal that `cat`s the launchd log. `\n`/`\r` get readable forms;
/// the rest become `\xNN`. Shared by both hook-drop loggers below.
private func oneLineForLog(_ s: String) -> String {
    var out = ""
    for scalar in String(s.prefix(200)).unicodeScalars {
        switch scalar {
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case let c where c.value < 0x20 || c.value == 0x7F:
            out += String(format: "\\x%02x", c.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// Log an unresolved hook-event drop at most once per `cwd`. Only the no-id /
/// no-cwd-match branch calls this, where `session_id` is always absent — so the
/// key is `cwd` alone (a `nil` cwd and a literal cwd of "none" are kept
/// distinct).
@MainActor private func logUnresolvedHookDropOnce(eventName: String, cwd: String?) {
    // Distinguish nil from a literal "none" path so the dedup key can't collide.
    let key = cwd.map { "cwd:" + $0 } ?? "<nil>"
    guard !loggedUnresolvedHookDrops.contains(key) else { return }
    // Hold the cap by refusing new keys once full (rather than clearing, which
    // would re-log every already-seen key on the next cycle). Beyond the cap,
    // novel cwds go unlogged — acceptable for a diagnostic bounded to the small
    // set of real worktrees in practice. `hook-event` is gated local-only
    // (RPCWebSocketHandler.localOnlyDenial), so filling this cap needs local
    // socket access, not a remote /rpc peer.
    guard loggedUnresolvedHookDrops.count < 256 else { return }
    loggedUnresolvedHookDrops.insert(key)
    CrowLog.error(
        "[hook-event] dropped \(oneLineForLog(eventName)): unresolved session "
        + "(no session_id, cwd=\(cwd.map(oneLineForLog) ?? "<none>"))"
    )
}

/// Inherited-config drops already logged, keyed on `cwd` **and** the foreign
/// session id — unlike the unresolved set above, one cwd can legitimately see
/// several foreign ids over a daemon's life (a main clone rewritten for a new
/// session while its worktrees keep running), and collapsing them onto `cwd`
/// alone would hide all but the first.
@MainActor private var loggedForeignHookDrops: Set<String> = []

/// Log an inherited-block drop at most once per (cwd, foreign id) pair.
///
/// This one is worth a log line rather than silence: it is the visible symptom
/// of a main clone still carrying a hook block, which `reconcileMainClone`
/// should have cleared at launch. Seeing it repeatedly means reconciliation is
/// not reaching that directory.
///
/// Same shape as the unresolved logger — 256-key cap held by refusing new keys,
/// never reset for the daemon's lifetime — because this fires on essentially
/// every tool call of every affected session.
@MainActor private func logForeignHookDropOnce(
    eventName: String, cwd: String, provided: UUID, resolved: UUID
) {
    let key = "\(cwd)|\(provided.uuidString)"
    guard !loggedForeignHookDrops.contains(key) else { return }
    guard loggedForeignHookDrops.count < 256 else { return }
    loggedForeignHookDrops.insert(key)
    CrowLog.error(
        "[hook-event] dropped \(oneLineForLog(eventName)): hook config for session "
        + "\(provided.uuidString) fired in \(oneLineForLog(cwd)), which belongs to "
        + "\(resolved.uuidString) — an inherited main-clone block (#915). "
        + "Its .claude/settings.local.json still carries Crow hooks."
    )
}

@MainActor
func makeEngineHookHandlers(
    appState: AppState,
    store: JSONStore,
    sessionService: SessionService,
    hostBridge: HostBridge,
    hookDebug: Bool
) -> [String: CommandRouter.Handler] {
    let capturedAppState = appState
    let capturedStore = store
    let capturedService = sessionService
    // The explicit annotation is load-bearing, not decoration: a large
    // dictionary of closures without a contextual type blows Swift's
    // type-checker solver budget (CROW-1134 / CROW-1174).
    let handlers: [String: CommandRouter.Handler] = [
        "hook-event": { @Sendable params in
            guard let eventName = params["event_name"]?.stringValue else {
                // Deliberately not logged: a params-shaped request is a
                // caller bug (the CLI makes --event required), the RPC error
                // already signals it, and an un-deduped per-request log here
                // would be the flood the unresolved-session site below is
                // written to avoid (#903 review).
                throw RPCError.invalidParams("event_name required")
            }
            let payload = params["payload"]?.objectValue ?? [:]

            // session_id is now optional — Codex's global hooks don't
            // know the Crow session UUID, so the server resolves it via
            // the `cwd` field in the payload.
            let providedSessionID = params["session_id"]?.stringValue
                .flatMap(UUID.init(uuidString:))
            let requestedAgentKind = params["agent_kind"]?.stringValue
                .flatMap { $0.isEmpty ? nil : AgentKind(rawValue: $0) }
            let cwd = payload["cwd"]?.stringValue

            // Build a human-readable summary from the event (independent
            // of session resolution).
            let summary: String = {
                switch eventName {
                case "PreToolUse", "PostToolUse", "PostToolUseFailure":
                    let tool = hookToolName(from: payload) ?? "unknown"
                    return "\(eventName): \(tool)"
                case "Notification":
                    let msg = payload["message"]?.stringValue ?? ""
                    return "Notification: \(msg.prefix(80))"
                case "Stop":
                    return "Agent finished responding"
                case "Interrupt":
                    return "Turn interrupted"
                case "StopFailure":
                    return "Agent stopped with error"
                case "SessionStart":
                    return "Session started"
                case "SessionEnd":
                    return "Session ended"
                case "PermissionRequest":
                    return "Permission requested"
                case "PermissionDenied":
                    return "Permission denied"
                case "UserPromptSubmit":
                    return "User submitted prompt"
                case "TaskCreated":
                    return "Task created"
                case "TaskCompleted":
                    return "Task completed"
                case "SubagentStart":
                    let agentType = payload["agent_type"]?.stringValue ?? "agent"
                    return "Subagent started: \(agentType)"
                case "SubagentStop":
                    return "Subagent stopped"
                case "PreCompact":
                    return "Context compaction starting"
                case "PostCompact":
                    return "Context compaction finished"
                default:
                    return eventName
                }
            }()

            return try await MainActor.run {
                // Resolve session — `cwd` is authoritative, and a provided
                // id is trusted only when cwd can't answer.
                //
                // cwd wins because it describes which session is *actually
                // running*, whereas `--session` only describes which file
                // the command was written into — and one settings file is
                // read by more sessions than the one it was written for. A
                // git worktree's `.git` is a file pointing at the main
                // clone, and project-root resolution follows it, so a
                // worktree session loads the **main clone's**
                // `.claude/settings.local.json` in addition to its own
                // (#915). The main clone's block therefore fires inside
                // every worktree session of that repo.
                //
                // That block is not necessarily stale — if a session really
                // does run in the main clone, its uuid is live and
                // `ClaudeHookRepair` rightly leaves the file alone — so the
                // old "a live id wins" rule attributed every worktree
                // session's events to the main clone's session, and fired
                // each event twice (once per block). Dropping the mismatch
                // fixes attribution and the duplicate in one step, for the
                // files already on disk, with no change to what we write.
                //
                // Unchanged below the first branch: an unknown-but-provided
                // id is still recorded rather than dropped (#897 — a stale
                // file's uuid can outlive its session, and recording under
                // the id we were handed beats losing the event), and an
                // agent whose cwd matches no registered worktree still
                // falls back to the provided id.
                let liveSessionIDs = Set(capturedAppState.sessions.map(\.id))
                let sessionID: UUID
                // Only *live* owners count. A row can outlive its session
                // (orphan recovery, a failed delete), and letting a dead one
                // own the directory would drop a live session's events.
                let owners = cwd.map {
                    capturedAppState.sessionIDs(forWorktreePath: $0)
                        .filter(liveSessionIDs.contains)
                } ?? []
                if let cwd, !owners.isEmpty {
                    let provided = providedSessionID
                    // Ids we honor over `owners`' arbitrary pick:
                    //
                    //  - One that owns the directory. With two rows on one
                    //    path the pick is a coin flip, so an id that owns it
                    //    is always preferred over whichever came first.
                    //  - The Manager. Its block lives at devRoot and is
                    //    matched by constant, never by path, everywhere else
                    //    (cf. `ClaudeHookRepair.sweep`); if devRoot were ever
                    //    registered as a worktree, path-based routing would
                    //    hijack — or silence — the session that orchestrates
                    //    everything.
                    let honored = provided.map {
                        owners.contains($0) || $0 == AppState.managerSessionID
                    } ?? false
                    // Anything else that is live is foreign to this
                    // directory: an inherited block. A provided id that is
                    // *not* live is #897's stale uuid, which
                    // `unknownSessionFallsBackToCwd` re-routes here rather
                    // than discards.
                    if let provided, !honored, liveSessionIDs.contains(provided) {
                        logForeignHookDropOnce(
                            eventName: eventName, cwd: cwd,
                            provided: provided, resolved: owners[0])
                        throw RPCError.invalidParams(
                            "hook config for session \(provided.uuidString) fired in a"
                            + " worktree owned by \(owners[0].uuidString); dropped as inherited")
                    }
                    if let provided, honored {
                        sessionID = provided
                    } else {
                        sessionID = owners[0]
                    }
                } else if let provided = providedSessionID {
                    sessionID = provided
                } else {
                    // No id, and no worktree matched the payload cwd: every
                    // event for this session is dropped. Since the client no
                    // longer surfaces this (fire-and-forget, #903), log it —
                    // deduped per cwd, because a global hook config with no
                    // --session run from a cwd outside any registered
                    // worktree (Codex/OpenCode/Antigravity; cf. #897)
                    // re-fires it on every event.
                    logUnresolvedHookDropOnce(eventName: eventName, cwd: cwd)
                    throw RPCError.invalidParams("session_id required or resolvable from payload cwd")
                }
                let sessionIsLive = liveSessionIDs.contains(sessionID)
                let sessionIDStr = sessionID.uuidString

                if hookDebug {
                    let shortID = String(sessionIDStr.prefix(8))
                    let keys = payload.keys.sorted().joined(separator: ",")
                    CrowLog.info("[hook-event] session=\(shortID) event=\(eventName) payload-keys=[\(keys)]")
                }

                let event = HookEvent(
                    sessionID: sessionID,
                    eventName: eventName,
                    summary: summary
                )

                // Flatten the raw JSON payload into the typed AgentHookEvent
                // that the state-machine signal source consumes. Keeps
                // CrowCore free of JSONValue, and localizes the field
                // extraction in one place.
                let agentEvent = AgentHookEvent(
                    sessionID: sessionID,
                    eventName: eventName,
                    toolName: hookToolName(from: payload),
                    source: payload["source"]?.stringValue,
                    message: payload["message"]?.stringValue,
                    notificationType: payload["notification_type"]?.stringValue,
                    agentType: payload["agent_type"]?.stringValue,
                    summary: summary
                )

                // Resolve the agent: explicit kind param > session's
                // stored agentKind > app default.
                let session = capturedAppState.sessions.first(where: { $0.id == sessionID })
                let resolvedKind = requestedAgentKind
                    ?? session?.agentKind
                    ?? capturedAppState.defaultAgentKind
                let signalSource = AgentRegistry.shared.agent(for: resolvedKind)?.stateSignalSource

                // CROW-1107: capture Antigravity's conversation→worktree map.
                // `agy`'s transcript records no cwd, so it can't be attributed
                // by the shared `cwdFilter` path (CROW-1097). What Crow *does*
                // know is exact: it launched `agy` in this session's worktree,
                // and the hook carries the `conversationId` that names the
                // transcript's `brain/<id>/…` dir. Record the pairing so
                // `AntigravityAgent.logSources` can return exactly this
                // worktree's transcripts. The worktree comes from Crow's own
                // session ownership — never the payload — so there is no
                // possibility of misattribution (best-effort, deduped, and it
                // never blocks or fails the hook).
                if resolvedKind == .antigravity,
                   let conversationID = antigravityConversationID(from: payload),
                   let worktree = capturedAppState.primaryWorktree(for: sessionID)?.worktreePath {
                    AntigravityConversationMap.record(
                        conversationID: conversationID,
                        worktreePath: worktree,
                        transcriptPath: antigravityTranscriptPath(from: payload))
                }

                let state = capturedAppState.hookState(for: sessionID)
                let stateBefore = state.activityState
                // Snapshot the color-driving subset so we can persist only on a
                // real change (keeps sidebar colors correct after relaunch — #367).
                let snapshotBefore = state.persistedSnapshot

                // Append to ring buffer (keep last 50 events per session)
                state.hookEvents.append(event)
                if state.hookEvents.count > 50 { state.hookEvents.removeFirst(state.hookEvents.count - 50) }

                // Count completed compactions (ADR 0008 follow-up 3).
                // `noteCompactionEvent` and the persist path shipped with
                // #704, but nothing ever called this — `PostCompact` fell
                // through to the signal source's `default`, so the grade's
                // heaviest penalty was inert on real data. Wired in
                // CROW-983.
                if eventName == SessionHookState.compactionEventName {
                    state.noteCompactionEvent(eventName)
                    // A Manager never reaches a terminal status, so it has
                    // no snapshot to persist the running total into.
                    // Attribute its compactions to the current ISO week as
                    // they happen.
                    if capturedAppState.isManagerSession(sessionID) {
                        capturedService.noteManagerCompaction(sessionID: sessionID)
                    }
                }

                // Ask the agent for the state transition and apply it.
                // The signal source is pure — all side effects (persistence,
                // notifications, etc.) stay here in the handler.
                if let signalSource {
                    let transition = signalSource.transition(
                        for: agentEvent,
                        currentActivityState: state.activityState,
                        currentNotificationType: state.pendingNotification?.notificationType,
                        currentLastTopLevelStopAt: state.lastTopLevelStopAt
                    )
                    if let newActivityState = transition.newActivityState {
                        state.activityState = newActivityState
                    }
                    switch transition.notification {
                    case .leave:
                        break
                    case .clear:
                        state.pendingNotification = nil
                    case .set(let notification):
                        state.pendingNotification = notification
                    }
                    switch transition.toolActivity {
                    case .leave:
                        break
                    case .clear:
                        state.lastToolActivity = nil
                    case .set(let activity):
                        state.lastToolActivity = activity
                    }
                    switch transition.lastTopLevelStopAt {
                    case .leave:
                        break
                    case .clear:
                        state.lastTopLevelStopAt = nil
                    case .set(let date):
                        state.lastTopLevelStopAt = date
                    }
                }

                // Trigger notification/sound for this event
                hostBridge.presentHookNotification(
                    sessionID: sessionID,
                    eventName: eventName,
                    payload: payload,
                    summary: summary
                )

                if hookDebug && state.activityState != stateBefore {
                    let shortID = String(sessionIDStr.prefix(8))
                    CrowLog.info("[hook-event] session=\(shortID) event=\(eventName) state=\(stateBefore.rawValue)→\(state.activityState.rawValue)")
                }

                // Persist the color-driving state only when it actually changed,
                // so sidebar colors survive a quit→relaunch (#367). Excluding
                // lastToolActivity means frequent PostToolUse events don't write.
                //
                // Gated on the session still existing: a stale hook block
                // naming a deleted session would otherwise keep appending
                // `hookStates` rows keyed to a uuid nothing ever prunes
                // (#897). `reseed` only filters those on read.
                let snapshotAfter = state.persistedSnapshot
                if sessionIsLive && snapshotAfter != snapshotBefore {
                    capturedStore.mutate { data in
                        var map = data.hookStates ?? [:]
                        map[sessionIDStr] = snapshotAfter
                        data.hookStates = map
                    }
                }

                return [
                    "received": .bool(true),
                    "session_id": .string(sessionIDStr),
                    "event_name": .string(eventName),
                ]
            }
        },
    ]
    return handlers
}
