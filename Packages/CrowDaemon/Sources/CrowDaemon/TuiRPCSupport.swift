import CrowCore
import CrowIPC
import Foundation

enum TuiRPC {
    static func recordingID(_ params: [String: JSONValue]) throws -> UUID {
        guard let raw = params["recording_id"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw DaemonRPCError.invalidParams("recording_id required")
        }
        return id
    }

    static func sessionID(_ params: [String: JSONValue]) throws -> UUID {
        guard let raw = params["session_id"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw DaemonRPCError.invalidParams("session_id required")
        }
        return id
    }

    static func startJSON(_ result: TuiStartResult) -> [String: JSONValue] {
        [
            "recording_id": .string(result.id.uuidString),
            "bind_deadline_ms": .int(TuiLimits.bindDeadlineMs),
            "dir": .string(result.dir.path),
            "limits": .object([
                "duration_ms": .int(Int(TuiLimits.maxDuration * 1000)),
                "bytes": .int(TuiLimits.maxBytes),
                "concurrent": .int(TuiLimits.maxConcurrent),
            ]),
            "pty_source": .string(result.ptySource.rawValue),
            "reused": .bool(result.reused),
        ]
    }

    static func recordJSON(_ rec: TuiRecordingRecord, dir: URL? = nil, byteSize: Int? = nil) -> [String: JSONValue] {
        var obj: [String: JSONValue] = [
            "recording_id": .string(rec.id.uuidString),
            "session_id": .string(rec.sessionID.uuidString),
            "terminal_id": .string(rec.terminalID.uuidString),
            "status": .string(rec.status.rawValue),
            "pty_source": .string(rec.ptySource.rawValue),
            "client_samples": .bool(rec.clientSamples),
            "started_at": .string(iso(rec.startedAt)),
            "bytes": .int(rec.bytes),
        ]
        if let sealed = rec.sealedAt { obj["sealed_at"] = .string(iso(sealed)) }
        if let note = rec.note { obj["note"] = .string(note) }
        if let ff = rec.formFactor { obj["form_factor"] = .string(ff) }
        if let reason = rec.abandonedReason { obj["reason"] = .string(reason) }
        if let dir { obj["dir"] = .string(dir.path) }
        if let byteSize { obj["byte_size"] = .int(byteSize) }
        return obj
    }

    static func reportJSON(_ report: TuiReport) -> JSONValue {
        var obj: [String: JSONValue] = [
            "recording_id": .string(report.recordingID.uuidString),
            "status": .string(report.status.rawValue),
            "pty_source": .string(report.ptySource.rawValue),
            "client_samples": .bool(report.clientSamples),
            "duration_ms": .int(report.durationMs),
            "bytes": .int(report.bytes),
            "counts": .object(report.counts.mapValues { .int($0) }),
            "signatures": .array(report.signatures.map { .string($0) }),
        ]
        if let ff = report.formFactor { obj["form_factor"] = .string(ff) }
        if let red = report.firstRed {
            obj["first_red"] = .object([
                "t": .int(red.t),
                "kind": .string(red.kind),
                "signature": .string(red.signature),
            ])
        }
        return .object(obj)
    }

    static func observationJSON(_ obs: TuiObservation) -> JSONValue {
        var obj: [String: JSONValue] = [
            "t": .int(obs.t),
            "kind": .string(obs.kind),
            "severity": .string(obs.severity),
            "signature": .string(obs.signature),
            "facts": factJSON(obs.facts),
        ]
        if let ff = obs.formFactor { obj["form_factor"] = .string(ff) }
        if let sid = obs.sessionID { obj["session_id"] = .string(sid.uuidString) }
        if let tid = obs.terminalID { obj["terminal_id"] = .string(tid.uuidString) }
        return .object(obj)
    }

    private static func factJSON(_ facts: [String: TuiFact]) -> JSONValue {
        .object(facts.mapValues(factValue))
    }

    private static func factValue(_ fact: TuiFact) -> JSONValue {
        switch fact {
        case .int(let v): return .int(v)
        case .double(let v): return .double(v)
        case .string(let v): return .string(v)
        case .bool(let v): return .bool(v)
        case .object(let v): return .object(v.mapValues(factValue))
        case .array(let v): return .array(v.map(factValue))
        case .null: return .null
        }
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
