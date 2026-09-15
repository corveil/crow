import ArgumentParser
import CrowIPC
import Foundation

/// Parent command for TUI form-factor recording: `crow tui record <subcommand>`.
///
/// `export` is a local copy from the recordings directory on this host. It does
/// **not** call `rpc()` — Unix-socket frames are capped at 1 MB and a recording
/// may be 64 MiB. There is no `tui-record-export` RPC and no parity-ledger row.
public struct Tui: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "TUI form-factor recording",
        subcommands: [TuiRecord.self]
    )

    public init() {}
}

public struct TuiRecord: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start, stop, and inspect TUI recordings",
        discussion: """
        Recordings live under Application Support/crow/tui-recordings/. They \
        capture PTY bytes and keystrokes — opt-in, local-first, never uploaded. \
        Watch is a poll of `log --since`, not a second tmux attach.
        """,
        subcommands: [
            TuiRecordStart.self,
            TuiRecordStop.self,
            TuiRecordMark.self,
            TuiRecordList.self,
            TuiRecordGet.self,
            TuiRecordLog.self,
            TuiRecordDelete.self,
            TuiRecordHud.self,
            TuiRecordExport.self,
        ]
    )

    public init() {}
}

public struct TuiRecordStart: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start a recording (tmux sampler until a surface binds)"
    )

    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Terminal UUID (required unless the session has exactly one)")
    var terminal: String?
    @Option(name: .long, help: "Operator note") var note: String?

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        if let terminal { try validateUUID(terminal, label: "terminal UUID") }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["session_id": .string(session)]
        if let terminal { params["terminal_id"] = .string(terminal) }
        if let note { params["note"] = .string(note) }
        printJSON(try rpc("tui-record-start", params: params))
    }
}

public struct TuiRecordStop: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop and seal a recording")

    @Option(name: .long, help: "Recording UUID") var id: String

    public init() {}

    public func validate() throws { try validateUUID(id, label: "recording UUID") }

    public func run() throws {
        printJSON(try rpc("tui-record-stop", params: ["recording_id": .string(id)]))
    }
}

public struct TuiRecordMark: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "mark", abstract: "Drop a marker and history dump")

    @Option(name: .long, help: "Recording UUID") var id: String
    @Option(name: .long, help: "Marker note") var note: String?

    public init() {}

    public func validate() throws { try validateUUID(id, label: "recording UUID") }

    public func run() throws {
        var params: [String: JSONValue] = ["recording_id": .string(id)]
        if let note { params["note"] = .string(note) }
        printJSON(try rpc("tui-record-mark", params: params))
    }
}

public struct TuiRecordList: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list", abstract: "List recordings")

    @Option(name: .long, help: "Filter by session UUID") var session: String?
    @Option(name: .long, help: "Filter by status (unbound|recording|sealed|abandoned)")
    var status: String?

    public init() {}

    public func validate() throws {
        if let session { try validateUUID(session, label: "session UUID") }
        if let status {
            let allowed = ["unbound", "recording", "sealed", "abandoned"]
            guard allowed.contains(status) else {
                throw ValidationError("status must be one of: \(allowed.joined(separator: ", "))")
            }
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let session { params["session_id"] = .string(session) }
        if let status { params["status"] = .string(status) }
        printJSON(try rpc("tui-record-list", params: params))
    }
}

public struct TuiRecordGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show report.json plus dir/byte_size"
    )

    @Option(name: .long, help: "Recording UUID") var id: String

    public init() {}

    public func validate() throws { try validateUUID(id, label: "recording UUID") }

    public func run() throws {
        printJSON(try rpc("tui-record-get", params: ["recording_id": .string(id)]))
    }
}

public struct TuiRecordLog: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Poll observations (CLI watch is this + --since, not a push transport)",
        discussion: """
        Returns at most 256 KiB or 200 rows, plus next_since. Loop with \
        --since to tail a live recording. There is no tui-record-watch RPC.
        """
    )

    @Option(name: .long, help: "Recording UUID") var id: String
    @Option(name: .long, help: "Only this observation kind") var kind: String?
    @Option(name: .long, help: "Only observations with t > this daemon timestamp")
    var since: Int?

    public init() {}

    public func validate() throws { try validateUUID(id, label: "recording UUID") }

    public func run() throws {
        var params: [String: JSONValue] = ["recording_id": .string(id)]
        if let kind { params["kind"] = .string(kind) }
        if let since { params["since"] = .int(since) }
        printJSON(try rpc("tui-record-log", params: params))
    }
}

public struct TuiRecordDelete: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a recording directory")

    @Option(name: .long, help: "Recording UUID") var id: String

    public init() {}

    public func validate() throws { try validateUUID(id, label: "recording UUID") }

    public func run() throws {
        printJSON(try rpc("tui-record-delete", params: ["recording_id": .string(id)]))
    }
}

public struct TuiRecordHud: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hud",
        abstract: "Toggle the on-device diagnostics HUD for a session"
    )

    @Option(name: .long, help: "Session UUID") var session: String
    @Argument(help: "on or off") var mode: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        guard mode == "on" || mode == "off" else {
            throw ValidationError("hud mode must be on or off")
        }
    }

    public func run() throws {
        printJSON(try rpc("tui-record-hud", params: [
            "session_id": .string(session),
            "on": .bool(mode == "on"),
        ]))
    }
}

/// Local copy from Application Support. Does not call `rpc()`.
public struct TuiRecordExport: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Copy a recording to --dir (local filesystem; no RPC)",
        discussion: """
        Reads ~/Library/Application Support/crow/tui-recordings/<id>/ (or the \
        Linux equivalent) on this host. --fixture writes geometry + detector \
        inputs only — never the raw PTY byte stream.
        """
    )

    @Option(name: .long, help: "Recording UUID") var id: String
    @Option(name: .long, help: "Destination directory") var dir: String
    @Flag(name: .long, help: "Geometry + detector inputs only; no raw PTY bytes")
    var fixture: Bool = false

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "recording UUID")
        guard !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--dir is required")
        }
    }

    public func run() throws {
        // BEGIN export-no-rpc
        // Intentionally does not call rpc() — see discussion. A later engineer
        // must not "fix" this by shipping 64 MiB over the Unix socket.
        let src = tuiRecordingsRoot().appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw ValidationError("recording not found at \(src.path)")
        }
        let dest = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        if fixture {
            try writeFixture(from: src, to: dest.appendingPathComponent("fixture.json"))
        } else {
            let out = dest.appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: out.path) {
                try FileManager.default.removeItem(at: out)
            }
            try FileManager.default.copyItem(at: src, to: out)
        }
        printJSON([
            "exported": .bool(true),
            "recording_id": .string(id),
            "dir": .string(dest.path),
            "fixture": .bool(fixture),
        ])
        // END export-no-rpc
    }
}

func tuiRecordingsRoot() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("crow", isDirectory: true)
        .appendingPathComponent("tui-recordings", isDirectory: true)
}

private func writeFixture(from src: URL, to dest: URL) throws {
    let reportURL = src.appendingPathComponent("report.json")
    let report = (try? Data(contentsOf: reportURL)).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    } ?? [:]
    let obsURL = src.appendingPathComponent("observations.ndjson")
    var timeline: [[String: Any]] = []
    if let data = try? Data(contentsOf: obsURL),
       let text = String(data: data, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if obj["type"] as? String == "o" { continue }
            if obj["data"] is String { continue }
            timeline.append(obj)
        }
    }
    var fixture: [String: Any] = [
        "name": (report["first_red"] as? [String: Any])?["signature"] as? String ?? "tui-fixture",
        "issue": NSNull(),
        "timeline": timeline,
    ]
    if let ff = report["form_factor"] {
        fixture["form_factor"] = ff
    }
    if let expect = report["first_red"] {
        fixture["expect"] = expect
    } else {
        fixture["expect"] = NSNull()
    }
    let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .prettyPrinted])
    try data.write(to: dest)
}
