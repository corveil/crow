import Foundation

/// Constants for TUI form-factor recording (CROW-1255). Limits are v1 constants,
/// not `AppConfig` — a settings block can land later.
enum TuiLimits {
    static let maxDuration: TimeInterval = 10 * 60
    static let maxBytes = 64 * 1024 * 1024
    static let teeMaxBytes = 8 * 1024 * 1024
    static let teeMaxAge: TimeInterval = 2
    static let maxConcurrent = 2
    static let bindDeadlineMs = 20_000
    static let disconnectGraceMs = 20_000
    static let retentionDays = 7
    static let sampleRatePerSecond = 10
    static let joinWindowMs = 250
    static let historyDumpLines = 200
    static let logMaxRows = 200
    static let logMaxBytes = 256 * 1024
    static let keyboardMinOcclusionPx = 120
    static let samplerInterval: TimeInterval = 1
    /// Abandoned on boot if still `recording`/`unbound` and older than this.
    static let bootAbandonAge: TimeInterval = 5 * 60
}

enum TuiRecordingStatus: String, Codable, Sendable {
    case unbound
    case recording
    case sealed
    case abandoned
}

enum TuiPtySource: String, Codable, Sendable {
    case none
    case attach
}

struct TuiRecordingRecord: Codable, Sendable, Equatable {
    var id: UUID
    var sessionID: UUID
    var terminalID: UUID
    var tmuxWindow: Int
    var agentSurface: Bool
    var status: TuiRecordingStatus
    var ptySource: TuiPtySource
    var clientSamples: Bool
    var startedAt: Date
    var sealedAt: Date?
    var bytes: Int
    var note: String?
    var formFactor: String?
    var abandonedReason: String?
}

struct TuiStartResult: Sendable {
    var id: UUID
    var dir: URL
    var ptySource: TuiPtySource
    var reused: Bool
}

struct TuiBindResult: Sendable {
    var ok: Bool
    var reason: String?
    var tee: TuiBoundedTee?
}

struct TuiClientSample: Codable, Sendable, Equatable {
    var tClient: Int
    var formFactor: String
    var hidden: Bool
    var hasFocus: Bool
    var arrivedAtTop: Bool
    var env: TuiClientEnv
    var viewport: TuiClientViewport
    var cursor: TuiClientCursor
    var modes: TuiClientModes
    var visibleHash: String
    var visibleRows: Int
    var events: [TuiClientEvent]
    /// Visible buffer lines (viewport), used by `cursor_below_input`.
    var visibleLines: [String]?

    enum CodingKeys: String, CodingKey {
        case tClient = "t_client"
        case formFactor = "form_factor"
        case hidden
        case hasFocus = "has_focus"
        case arrivedAtTop = "arrived_at_top"
        case env, viewport, cursor, modes
        case visibleHash = "visible_hash"
        case visibleRows = "visible_rows"
        case events
        case visibleLines = "visible_lines"
    }
}

struct TuiClientEnv: Codable, Sendable, Equatable {
    var ua: String
    var tauri: Bool
    var dpr: Double
    var maxTouchPoints: Int
    var pointerCoarse: Bool
    var webgl: Bool
    var locale: String

    enum CodingKeys: String, CodingKey {
        case ua, tauri, dpr, webgl, locale
        case maxTouchPoints = "max_touch_points"
        case pointerCoarse = "pointer_coarse"
    }
}

struct TuiClientViewport: Codable, Sendable, Equatable {
    var innerW: Int
    var innerH: Int
    var clientW: Int
    var clientH: Int
    var vvW: Int?
    var vvH: Int?
    var vvOffsetTop: Int?
    var vvOffsetLeft: Int?
    var keyboardInsetPx: Int
    var cssCols: Int
    var cssRows: Int
    var cellW: Double
    var cellH: Double

    enum CodingKeys: String, CodingKey {
        case innerW = "inner_w"
        case innerH = "inner_h"
        case clientW = "client_w"
        case clientH = "client_h"
        case vvW = "vv_w"
        case vvH = "vv_h"
        case vvOffsetTop = "vv_offset_top"
        case vvOffsetLeft = "vv_offset_left"
        case keyboardInsetPx = "keyboard_inset_px"
        case cssCols = "css_cols"
        case cssRows = "css_rows"
        case cellW = "cell_w"
        case cellH = "cell_h"
    }
}

struct TuiClientCursor: Codable, Sendable, Equatable {
    var xtermX: Int
    var xtermY: Int
    var xtermViewportY: Int
    var xtermBaseY: Int
    var textareaLeftPx: Double
    var textareaTopPx: Double
    var caretCssX: Double
    var caretCssY: Double

    enum CodingKeys: String, CodingKey {
        case xtermX = "xterm_x"
        case xtermY = "xterm_y"
        case xtermViewportY = "xterm_viewport_y"
        case xtermBaseY = "xterm_base_y"
        case textareaLeftPx = "textarea_left_px"
        case textareaTopPx = "textarea_top_px"
        case caretCssX = "caret_css_x"
        case caretCssY = "caret_css_y"
    }
}

struct TuiClientModes: Codable, Sendable, Equatable {
    var agentSurface: Bool
    var bufferType: String
    var mouseTracking: String
    var appOwnsScroll: Bool
    var altScreenFlag: Bool

    enum CodingKeys: String, CodingKey {
        case agentSurface = "agent_surface"
        case bufferType = "buffer_type"
        case mouseTracking = "mouse_tracking"
        case appOwnsScroll = "app_owns_scroll"
        case altScreenFlag = "alt_screen_flag"
    }
}

struct TuiClientEvent: Codable, Sendable, Equatable {
    var kind: String
    var atClient: Int?
    var preventDefault: Bool?
    var delta: Int?

    enum CodingKeys: String, CodingKey {
        case kind
        case atClient = "at_client"
        case preventDefault = "prevent_default"
        case delta
    }
}

struct TuiTmuxSample: Sendable, Equatable {
    var t: Int
    var cols: Int
    var rows: Int
    var cursorX: Int
    var cursorY: Int
    var alternateOn: Bool
    var alternateScreen: Bool
    var paneInMode: Bool
    var historySize: Int
    var historyLimit: Int
    var viewportHash: String
    var viewportText: String?
}

struct TuiObservation: Codable, Sendable, Equatable {
    var t: Int
    var kind: String
    var severity: String
    var formFactor: String?
    var sessionID: UUID?
    var terminalID: UUID?
    var signature: String
    var facts: [String: TuiFact]

    enum CodingKeys: String, CodingKey {
        case t, kind, severity, signature, facts
        case formFactor = "form_factor"
        case sessionID = "session_id"
        case terminalID = "terminal_id"
    }
}

/// Small JSON-ish value for observation facts (avoids `JSONValue` coupling in detectors).
enum TuiFact: Codable, Sendable, Equatable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case object([String: TuiFact])
    case array([TuiFact])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: TuiFact].self) { self = .object(v); return }
        if let v = try? c.decode([TuiFact].self) { self = .array(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct TuiReport: Codable, Sendable {
    var recordingID: UUID
    var status: TuiRecordingStatus
    var ptySource: TuiPtySource
    var clientSamples: Bool
    var formFactor: String?
    var durationMs: Int
    var bytes: Int
    var counts: [String: Int]
    var firstRed: TuiFirstRed?
    var signatures: [String]

    enum CodingKeys: String, CodingKey {
        case status, bytes, counts, signatures
        case recordingID = "recording_id"
        case ptySource = "pty_source"
        case clientSamples = "client_samples"
        case formFactor = "form_factor"
        case durationMs = "duration_ms"
        case firstRed = "first_red"
    }
}

struct TuiFirstRed: Codable, Sendable, Equatable {
    var t: Int
    var kind: String
    var signature: String
}

enum TuiTeeEvent: Sendable {
    case output(Data)
    case input(Data)
    case resize(cols: Int, rows: Int, src: String)
    case selectWindow(Int)
    case bind(String)
    case unbind(String)
    case marker(String?)
}

/// Injectable tmux sampling so tests can block `capturePane` without a live tmux.
struct TuiTmuxHooks: Sendable {
    var displayMessage: @Sendable (_ target: String, _ format: String) throws -> String
    var capturePane: @Sendable (_ target: String, _ linesBack: Int) throws -> String

    static let noop = TuiTmuxHooks(
        displayMessage: { _, _ in "80 24 0 0 0 off 0 0 50000" },
        capturePane: { _, _ in "" }
    )
}
