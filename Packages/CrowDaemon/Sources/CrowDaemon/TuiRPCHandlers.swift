import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// TUI form-factor recording RPCs (CROW-1255). Start/stop/mark/hud are **not**
/// `localOnlyDenial` — the operator is on the iPad.
func makeTuiHandlers(
    appState: AppState,
    tuiRecorder: TuiRecorder?
) -> [String: CommandRouter.Handler] {
    [
        "tui-record-start": { params in
            try await mapRPCError {
                guard let recorder = tuiRecorder else {
                    throw DaemonRPCError.applicationError("TUI recorder is not available")
                }
                let sessionID = try TuiRPC.sessionID(params)
                let resolved = try await MainActor.run { () -> (UUID, Int, Bool) in
                    let terms = appState.terminals[sessionID] ?? []
                    let terminalID: UUID
                    if let raw = params["terminal_id"]?.stringValue, let id = UUID(uuidString: raw) {
                        terminalID = id
                    } else if terms.count == 1 {
                        terminalID = terms[0].id
                    } else {
                        throw DaemonRPCError.invalidParams(
                            "terminal_id is required when the session has more than one terminal")
                    }
                    guard let term = terms.first(where: { $0.id == terminalID }) else {
                        throw DaemonRPCError.applicationError("terminal not found")
                    }
                    guard let window = term.tmuxBinding?.windowIndex else {
                        throw DaemonRPCError.applicationError("tmux window index cannot be resolved")
                    }
                    let session = appState.sessions.first { $0.id == sessionID }
                    return (terminalID, window, term.isAgentSurface(session: session))
                }
                let expectBind = params["expect_bind"]?.boolValue ?? false
                let note = params["note"]?.stringValue
                let result = try recorder.start(
                    sessionID: sessionID,
                    terminalID: resolved.0,
                    tmuxWindow: resolved.1,
                    agentSurface: resolved.2,
                    note: note,
                    expectBind: expectBind)
                return TuiRPC.startJSON(result)
            }
        },
        "tui-record-stop": { params in
            try await mapRPCError {
                guard let recorder = tuiRecorder else {
                    throw DaemonRPCError.applicationError("TUI recorder is not available")
                }
                let id = try TuiRPC.recordingID(params)
                let report = try recorder.stop(recordingID: id)
                return [
                    "recording_id": .string(id.uuidString),
                    "status": .string(report.status.rawValue),
                    "report": TuiRPC.reportJSON(report),
                ]
            }
        },
        "tui-record-mark": { params in
            try await mapRPCError {
                guard let recorder = tuiRecorder else {
                    throw DaemonRPCError.applicationError("TUI recorder is not available")
                }
                try recorder.mark(
                    recordingID: try TuiRPC.recordingID(params),
                    note: params["note"]?.stringValue)
                return ["ok": .bool(true)]
            }
        },
        "tui-record-list": { params in
            try await mapRPCError {
                guard let recorder = tuiRecorder else {
                    return ["recordings": .array([])]
                }
                let sessionID = params["session_id"]?.stringValue.flatMap(UUID.init)
                let status = params["status"]?.stringValue.flatMap(TuiRecordingStatus.init(rawValue:))
                let rows = recorder.list(sessionID: sessionID, status: status)
                return ["recordings": .array(rows.map { .object(TuiRPC.recordJSON($0)) })]
            }
        },
        "tui-record-get": { params in
            try await mapRPCError {
                guard let recorder = tuiRecorder else {
                    throw DaemonRPCError.applicationError("TUI recorder is not available")
                }
                let id = try TuiRPC.recordingID(params)
                let got = try recorder.get(recordingID: id)
                var size = got.record.bytes
                if size == 0 {
                    let pty = got.dir.appendingPathComponent("pty.ndjson")
                    size = (try? FileManager.default.attributesOfItem(atPath: pty.path)[.size] as? Int) ?? 0
                }
                var result = TuiRPC.recordJSON(got.record, dir: got.dir, byteSize: size)
                if let report = got.report {
                    result["report"] = TuiRPC.reportJSON(report)
                }
                return result
            }
        },
        "tui-record-log": { params in
            try await mapRPCError {
                guard let recorder = tuiRecorder else {
                    throw DaemonRPCError.applicationError("TUI recorder is not available")
                }
                let id = try TuiRPC.recordingID(params)
                let kind = params["kind"]?.stringValue
                let since = params["since"]?.intValue
                let got = try recorder.log(recordingID: id, kind: kind, since: since)
                return [
                    "observations": .array(got.observations.map { TuiRPC.observationJSON($0) }),
                    "next_since": .int(got.nextSince),
                ]
            }
        },
        "tui-record-delete": { params in
            try await mapRPCError {
                guard let recorder = tuiRecorder else {
                    throw DaemonRPCError.applicationError("TUI recorder is not available")
                }
                recorder.delete(recordingID: try TuiRPC.recordingID(params))
                return ["deleted": .bool(true)]
            }
        },
        "tui-record-hud": { params in
            try await mapRPCError {
                let sessionID = try TuiRPC.sessionID(params)
                guard let on = params["on"]?.boolValue else {
                    throw DaemonRPCError.invalidParams("on is required")
                }
                guard let recorder = tuiRecorder else {
                    throw DaemonRPCError.applicationError("TUI recorder is not available")
                }
                recorder.setHUD(sessionID: sessionID, on: on)
                return ["ok": .bool(true)]
            }
        },
    ]
}
