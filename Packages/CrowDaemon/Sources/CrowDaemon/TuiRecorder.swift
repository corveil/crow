import Crypto
import CrowCore
import CrowPersistence
import Foundation

/// Daemon-owned TUI recorder (CROW-1255). Two dedicated serial `DispatchQueue`s
/// (not a Swift actor — `capturePane`'s timeout must not occupy the cooperative
/// pool). The PTY hot path is a connection-local `if let tee { tee.yield }`.
final class TuiRecorder: @unchecked Sendable {
    let root: URL
    let ingestQueue: DispatchQueue
    let samplerQueue: DispatchQueue
    let registry = TuiConnectionRegistry()
    let index: TuiRecordingIndex
    let eventHub: EventHub?

    var tmux: TuiTmuxHooks
    var now: () -> Date
    var maxDuration: TimeInterval
    var maxBytes: Int
    var maxConcurrent: Int
    var samplerInterval: TimeInterval
    var retentionDays: Int
    var bindDeadlineMs: Int
    var disconnectGraceMs: Int

    private var live: [UUID: LiveRecording] = [:]
    private var samplerWork: DispatchWorkItem?
    private var reaperWork: DispatchWorkItem?
    private var captureOnMainActor = false

    init(
        root: URL? = nil,
        tmux: TuiTmuxHooks = .noop,
        eventHub: EventHub? = nil,
        now: @escaping () -> Date = Date.init,
        maxDuration: TimeInterval = TuiLimits.maxDuration,
        maxBytes: Int = TuiLimits.maxBytes,
        maxConcurrent: Int = TuiLimits.maxConcurrent,
        samplerInterval: TimeInterval = TuiLimits.samplerInterval,
        retentionDays: Int = TuiLimits.retentionDays,
        bindDeadlineMs: Int = TuiLimits.bindDeadlineMs,
        disconnectGraceMs: Int = TuiLimits.disconnectGraceMs
    ) {
        let dir: URL
        if let root {
            dir = root
        } else {
            Self.trapIfConstructingLivePathUnderTests()
            dir = AppSupportDirectory.url.appendingPathComponent("tui-recordings", isDirectory: true)
        }
        self.root = dir
        self.tmux = tmux
        self.eventHub = eventHub
        self.now = now
        self.maxDuration = maxDuration
        self.maxBytes = maxBytes
        self.maxConcurrent = maxConcurrent
        self.samplerInterval = samplerInterval
        self.retentionDays = retentionDays
        self.bindDeadlineMs = bindDeadlineMs
        self.disconnectGraceMs = disconnectGraceMs
        self.ingestQueue = DispatchQueue(label: "crow.tui.ingest", qos: .utility)
        self.samplerQueue = DispatchQueue(label: "crow.tui.sampler", qos: .utility)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        self.index = TuiRecordingIndex(root: dir)
    }

    deinit {
        samplerWork?.cancel()
        reaperWork?.cancel()
    }

    /// Seal crashed in-flight recordings, then start the daily reaper + sampler.
    func boot() {
        ingestQueue.sync {
            let cutoff = now().addingTimeInterval(-TuiLimits.bootAbandonAge)
            for rec in index.all() where rec.status == .unbound || rec.status == .recording {
                if rec.startedAt < cutoff {
                    abandonLocked(id: rec.id, reason: "daemon_restart")
                }
            }
        }
        reap()
        armSampler()
        armReaper()
    }

    func start(
        sessionID: UUID,
        terminalID: UUID,
        tmuxWindow: Int,
        agentSurface: Bool,
        note: String?,
        expectBind: Bool
    ) throws -> TuiStartResult {
        try ingestQueue.sync {
            if let existing = index.inFlight(sessionID: sessionID, terminalID: terminalID) {
                return TuiStartResult(
                    id: existing.id,
                    dir: dir(for: existing.id),
                    ptySource: existing.ptySource,
                    reused: true)
            }
            guard index.inFlightCount() < maxConcurrent else {
                throw DaemonRPCError.applicationError("concurrent TUI recording limit reached (max \(maxConcurrent))")
            }
            let id = UUID()
            let recDir = dir(for: id)
            try FileManager.default.createDirectory(
                at: recDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let started = now()
            let record = TuiRecordingRecord(
                id: id, sessionID: sessionID, terminalID: terminalID,
                tmuxWindow: tmuxWindow, agentSurface: agentSurface,
                status: .unbound, ptySource: .none, clientSamples: false,
                startedAt: started, sealedAt: nil, bytes: 0, note: note,
                formFactor: nil, abandonedReason: nil)
            index.upsert(record)
            let liveRec = LiveRecording(record: record, dir: recDir, startedAt: started)
            liveRec.writeHeader()
            live[id] = liveRec
            CrowLog.info("[CrowTui record_start id=\(id.uuidString) session=\(sessionID.uuidString) pty_source=none]")
            if expectBind {
                let deadline = DispatchTime.now() + .milliseconds(bindDeadlineMs)
                ingestQueue.asyncAfter(deadline: deadline) { [weak self] in
                    self?.abandonIfStillUnbound(id)
                }
            }
            armSampler()
            return TuiStartResult(id: id, dir: recDir, ptySource: .none, reused: false)
        }
    }

    func bind(group: String, recordingID: UUID) -> TuiBindResult {
        ingestQueue.sync {
            if let prior = registry.bind(group: group, recordingID: recordingID), prior != recordingID {
                unbindLocked(id: prior, reason: "rebind", grace: false)
            }
            guard var rec = live[recordingID]?.record ?? index.get(recordingID) else {
                broadcastNotActive(recordingID)
                return TuiBindResult(ok: false, reason: "not_active", tee: nil)
            }
            if rec.status == .sealed || rec.status == .abandoned {
                registry.unbind(recordingID: recordingID)
                broadcastNotActive(recordingID)
                return TuiBindResult(ok: false, reason: "not_active", tee: nil)
            }
            let liveRec: LiveRecording
            if let existing = live[recordingID] {
                liveRec = existing
            } else {
                liveRec = LiveRecording(record: rec, dir: dir(for: recordingID), startedAt: rec.startedAt)
                live[recordingID] = liveRec
            }
            rec.status = .recording
            rec.ptySource = .attach
            rec.abandonedReason = nil
            liveRec.record = rec
            liveRec.cancelUnbindTimer()
            index.upsert(rec)
            let tee = TuiBoundedTee(
                recordingID: recordingID,
                ingestQueue: ingestQueue,
                onDrain: { [weak self] events in self?.appendTeeEvents(recordingID, events) },
                onBackpressure: { [weak self] in
            self?.ingestQueue.async { [weak self] in
                self?.sealLocked(id: recordingID, reason: "tee_backpressure")
            }
                })
            liveRec.tee = tee
            liveRec.boundGroup = group
            tee.yieldBind(group)
            CrowLog.info("[CrowTui record_bind id=\(recordingID.uuidString) group=\(group)]")
            return TuiBindResult(ok: true, reason: nil, tee: tee)
        }
    }

    func unbind(group: String, recordingID: UUID, reason: String) {
        ingestQueue.sync {
            registry.unbind(group: group)
            unbindLocked(id: recordingID, reason: reason, grace: reason == "disconnect")
        }
    }

    func ingestSample(_ sample: TuiClientSample, recordingID: UUID) {
        ingestQueue.async { [weak self] in
            guard let self, let liveRec = self.live[recordingID] else { return }
            guard liveRec.record.status == .recording, liveRec.record.ptySource == .attach,
                  liveRec.tee != nil, liveRec.tee?.isSealed == false else { return }
            let t = self.t(for: liveRec)
            if !liveRec.acceptSample(at: t) {
                CrowLog.info("[CrowTui sample_gap id=\(recordingID.uuidString) last_sample_ms=\(liveRec.lastSampleT ?? 0)]")
                let obs = TuiObservation(
                    t: t, kind: "sample_gap", severity: "yellow",
                    formFactor: sample.formFactor,
                    sessionID: liveRec.record.sessionID,
                    terminalID: liveRec.record.terminalID,
                    signature: "sample_gap.rate_limit",
                    facts: ["last_sample_ms": .int(liveRec.lastSampleT ?? 0)])
                liveRec.observations.append(obs)
                liveRec.writeObservation(obs)
                return
            }
            liveRec.record.clientSamples = true
            liveRec.record.formFactor = sample.formFactor
            self.index.upsert(liveRec.record)
            liveRec.writeJSON([
                "t": t, "t_client": sample.tClient, "type": "tui-sample",
            ], extra: sample, to: .observations)
            liveRec.clientSamples.append((t, sample))
            liveRec.detectorEvents.append(.client(t: t, sample: sample))
            self.runStreamDetectors(liveRec)
            self.maybeCap(liveRec)
        }
    }

    func mark(recordingID: UUID, note: String?) throws {
        try ingestQueue.sync {
            guard let liveRec = live[recordingID],
                  liveRec.record.status == .unbound || liveRec.record.status == .recording else {
                throw DaemonRPCError.applicationError("recording is not active")
            }
            let t = self.t(for: liveRec)
            liveRec.writeJSON(["t": t, "type": "marker", "name": note as Any], to: .pty)
            liveRec.tee?.yieldMarker(note)
            // History dump on the sampler queue — never on ingest.
            samplerQueue.async { [weak self] in
                self?.dumpHistory(liveRec, t: t)
            }
        }
    }

    @discardableResult
    func stop(recordingID: UUID) throws -> TuiReport {
        try ingestQueue.sync {
            guard live[recordingID] != nil || index.get(recordingID) != nil else {
                throw DaemonRPCError.applicationError("recording not found")
            }
            return sealLocked(id: recordingID, reason: "stop")
        }
    }

    func delete(recordingID: UUID) {
        ingestQueue.sync {
            if live[recordingID] != nil {
                _ = sealLocked(id: recordingID, reason: "delete")
            }
            index.remove(recordingID)
            try? FileManager.default.removeItem(at: dir(for: recordingID))
        }
    }

    func get(recordingID: UUID) throws -> (record: TuiRecordingRecord, dir: URL, report: TuiReport?) {
        let rec = try ingestQueue.sync { () -> TuiRecordingRecord in
            guard let rec = index.get(recordingID) else {
                throw DaemonRPCError.applicationError("recording not found")
            }
            return rec
        }
        let recDir = dir(for: recordingID)
        let report = loadReport(recDir)
        return (rec, recDir, report)
    }

    func list(sessionID: UUID?, status: TuiRecordingStatus?) -> [TuiRecordingRecord] {
        ingestQueue.sync {
            index.all().filter { rec in
                if let sessionID, rec.sessionID != sessionID { return false }
                if let status, rec.status != status { return false }
                return true
            }
        }
    }

    func log(recordingID: UUID, kind: String?, since: Int?) throws -> (observations: [TuiObservation], nextSince: Int) {
        let recDir = dir(for: recordingID)
        let url = recDir.appendingPathComponent("observations.ndjson")
        guard FileManager.default.fileExists(atPath: url.path) else {
            if index.get(recordingID) == nil {
                throw DaemonRPCError.applicationError("recording not found")
            }
            return ([], since ?? 0)
        }
        let data = try Data(contentsOf: url)
        var rows: [TuiObservation] = []
        var next = since ?? 0
        var bytes = 0
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) {
            guard let obs = try? decoder.decode(TuiObservation.self, from: Data(line)) else { continue }
            if let since, obs.t <= since { continue }
            if let kind, obs.kind != kind { continue }
            bytes += line.count + 1
            if rows.count >= TuiLimits.logMaxRows || bytes > TuiLimits.logMaxBytes { break }
            rows.append(obs)
            next = max(next, obs.t)
        }
        return (rows, next)
    }

    func dir(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// HUD-on is display-only. Every surface of `sessionID` may show the overlay;
    /// samples are still bind-gated and never joined by session_id.
    func setHUD(sessionID: UUID, on: Bool) {
        broadcast(
            recordingID: UUID(),
            sessionID: sessionID,
            t: 0,
            kind: on ? "hud_on" : "hud_off",
            severity: "green",
            signature: on ? "hud_on" : "hud_off",
            grid: nil)
    }

    /// Exposed for tests: whether a `capturePane` hook ran on the MainActor.
    var didCaptureOnMainActor: Bool { captureOnMainActor }

    /// Drain ingest + sampler so tests can observe file/index writes.
    func flushForTests() {
        ingestQueue.sync {}
        samplerQueue.sync {}
        ingestQueue.sync {}
    }

    /// Ingest only — never wait on a blocked `capturePane` (sampler queue).
    func flushIngestForTests() {
        ingestQueue.sync {}
    }

    func reap() {
        samplerQueue.async { [weak self] in
            guard let self else { return }
            guard self.retentionDays > 0 else { return }
            let cutoff = self.now().addingTimeInterval(-TimeInterval(self.retentionDays * 86400))
            for rec in self.index.all() where rec.status == .sealed || rec.status == .abandoned {
                let stamp = rec.sealedAt ?? rec.startedAt
                if stamp < cutoff {
                    let age = Int(self.now().timeIntervalSince(stamp) / 86400)
                    CrowLog.info("[CrowTui record_reap id=\(rec.id.uuidString) age_days=\(age)]")
                    self.index.remove(rec.id)
                    try? FileManager.default.removeItem(at: self.dir(for: rec.id))
                }
            }
        }
    }

    // MARK: - Internals

    private func t(for liveRec: LiveRecording) -> Int {
        Int((now().timeIntervalSince(liveRec.startedAt) * 1000).rounded())
    }

    private func appendTeeEvents(_ id: UUID, _ events: [TuiTeeEvent]) {
        // Already on ingestQueue.
        guard let liveRec = live[id] else { return }
        for event in events {
            let t = self.t(for: liveRec)
            switch event {
            case .output(let data):
                liveRec.writeJSON([
                    "t": t, "type": "o", "data": data.base64EncodedString(),
                ], to: .pty)
                liveRec.bytes += data.count
                liveRec.detectorEvents.append(.output(t: t))
            case .input(let data):
                liveRec.writeJSON([
                    "t": t, "type": "i", "data": data.base64EncodedString(),
                ], to: .pty)
                liveRec.bytes += data.count
            case .resize(let cols, let rows, let src):
                liveRec.writeJSON([
                    "t": t, "type": "resize", "cols": cols, "rows": rows, "src": src,
                ], to: .pty)
                liveRec.lastPtyCols = cols
                liveRec.lastPtyRows = rows
                liveRec.detectorEvents.append(.resize(t: t, cols: cols, rows: rows, hidden: nil, hasFocus: nil))
            case .selectWindow(let window):
                liveRec.writeJSON([
                    "t": t, "type": "select-window", "window": window,
                ], to: .pty)
                liveRec.detectorEvents.append(.selectWindow(t: t, agentSurface: liveRec.record.agentSurface))
            case .bind(let group):
                liveRec.writeJSON(["t": t, "type": "bind", "group": group], to: .pty)
            case .unbind(let reason):
                liveRec.writeJSON(["t": t, "type": "unbind", "reason": reason], to: .pty)
            case .marker(let name):
                liveRec.writeJSON(["t": t, "type": "marker", "name": name as Any], to: .pty)
            }
        }
        liveRec.record.bytes = liveRec.bytes
        index.upsert(liveRec.record)
        runStreamDetectors(liveRec)
        maybeCap(liveRec)
    }

    private func runStreamDetectors(_ liveRec: LiveRecording) {
        let found = TuiDetectors.detect(
            events: liveRec.detectorEvents,
            sessionID: liveRec.record.sessionID,
            terminalID: liveRec.record.terminalID)
        let existing = Set(liveRec.observations.map { "\($0.t)|\($0.kind)|\($0.signature)" })
        for obs in found where !existing.contains("\(obs.t)|\(obs.kind)|\(obs.signature)") {
            liveRec.observations.append(obs)
            liveRec.writeObservation(obs)
            broadcastObservation(obs, recordingID: liveRec.record.id, sessionID: liveRec.record.sessionID)
        }
        liveRec.detectorEvents = Array(liveRec.detectorEvents.suffix(400))
    }

    private func maybeCap(_ liveRec: LiveRecording) {
        if liveRec.bytes >= maxBytes {
            _ = sealLocked(id: liveRec.record.id, reason: "max_bytes")
            return
        }
        if now().timeIntervalSince(liveRec.startedAt) >= maxDuration {
            _ = sealLocked(id: liveRec.record.id, reason: "max_duration")
        }
    }

    private func unbindLocked(id: UUID, reason: String, grace: Bool) {
        guard let liveRec = live[id] else { return }
        liveRec.tee?.yieldUnbind(reason)
        liveRec.tee?.seal()
        liveRec.tee = nil
        liveRec.boundGroup = nil
        liveRec.record.ptySource = .none
        index.upsert(liveRec.record)
        CrowLog.info("[CrowTui record_unbind id=\(id.uuidString) reason=\(reason)]")
        if grace, liveRec.record.status == .recording {
            liveRec.cancelUnbindTimer()
            let work = DispatchWorkItem { [weak self] in
                self?.ingestQueue.async { [weak self] in
                    self?.abandonIfStillUnboundAfterGrace(id)
                }
            }
            liveRec.unbindTimer = work
            ingestQueue.asyncAfter(deadline: .now() + .milliseconds(disconnectGraceMs), execute: work)
        }
    }

    private func abandonIfStillUnbound(_ id: UUID) {
        ingestQueue.async { [weak self] in
            guard let self, let liveRec = self.live[id], liveRec.record.status == .unbound,
                  liveRec.record.ptySource == .none else { return }
            self.abandonLocked(id: id, reason: "unbound")
        }
    }

    private func abandonIfStillUnboundAfterGrace(_ id: UUID) {
        guard let liveRec = live[id], liveRec.record.ptySource == .none,
              liveRec.record.status == .recording || liveRec.record.status == .unbound else { return }
        abandonLocked(id: id, reason: "disconnect_timeout")
    }

    private func abandonLocked(id: UUID, reason: String) {
        CrowLog.info("[CrowTui record_drop id=\(id.uuidString) reason=\(reason)]")
        _ = sealLocked(id: id, reason: reason, abandoned: true)
    }

    @discardableResult
    private func sealLocked(id: UUID, reason: String, abandoned: Bool = false) -> TuiReport {
        guard let liveRec = live[id] else {
            if var rec = index.get(id) {
                rec.status = abandoned ? .abandoned : .sealed
                rec.sealedAt = now()
                rec.abandonedReason = abandoned ? reason : rec.abandonedReason
                index.upsert(rec)
                return TuiDetectors.report(
                    recordingID: id, status: rec.status, ptySource: rec.ptySource,
                    clientSamples: rec.clientSamples, formFactor: rec.formFactor,
                    durationMs: Int(now().timeIntervalSince(rec.startedAt) * 1000),
                    bytes: rec.bytes, observations: [])
            }
            return TuiDetectors.report(
                recordingID: id, status: .abandoned, ptySource: .none,
                clientSamples: false, formFactor: nil, durationMs: 0, bytes: 0, observations: [])
        }
        liveRec.tee?.seal()
        liveRec.tee = nil
        liveRec.cancelUnbindTimer()
        registry.unbind(recordingID: id)
        let t = self.t(for: liveRec)
        // History dump on sampler — wait briefly so report.json can include it,
        // but never from ingest via capturePane itself.
        let dumpDone = DispatchSemaphore(value: 0)
        samplerQueue.async { [weak self] in
            self?.dumpHistory(liveRec, t: t)
            dumpDone.signal()
        }
        // Don't stall ingest for a 10s capturePane: skip-if-in-flight with a short wait.
        _ = dumpDone.wait(timeout: .now() + 0.05)

        let duration = Int(now().timeIntervalSince(liveRec.startedAt) * 1000)
        liveRec.record.status = abandoned ? .abandoned : .sealed
        liveRec.record.sealedAt = now()
        liveRec.record.abandonedReason = abandoned ? reason : nil
        liveRec.record.bytes = liveRec.bytes
        index.upsert(liveRec.record)
        let report = TuiDetectors.report(
            recordingID: id,
            status: liveRec.record.status,
            ptySource: liveRec.record.ptySource,
            clientSamples: liveRec.record.clientSamples,
            formFactor: liveRec.record.formFactor,
            durationMs: duration,
            bytes: liveRec.bytes,
            observations: liveRec.observations)
        liveRec.writeReport(report)
        liveRec.close()
        live[id] = nil
        let red = report.counts.filter { ["cursor_mismatch", "viewport_mismatch", "grid_mismatch", "resize_storm", "duplicate_chrome", "scroll_jump", "cursor_below_input", "focus_steal"].contains($0.key) }.values.reduce(0, +)
        let yellow = report.counts.values.reduce(0, +) - red
        CrowLog.info("[CrowTui record_stop id=\(id.uuidString) duration_ms=\(duration) bytes=\(liveRec.bytes) red=\(red) yellow=\(yellow)]")
        if reason == "tee_backpressure" || reason == "max_bytes" || reason == "unbound" {
            CrowLog.info("[CrowTui record_drop id=\(id.uuidString) reason=\(reason)]")
        }
        return report
    }

    private func dumpHistory(_ liveRec: LiveRecording, t: Int) {
        if Thread.isMainThread { captureOnMainActor = true }
        guard !liveRec.dumpInFlight else { return }
        liveRec.dumpInFlight = true
        defer { liveRec.dumpInFlight = false }
        let target = "\(TerminalCockpit.sessionName):\(liveRec.record.tmuxWindow)"
        let historySize: Int
        if let last = liveRec.lastTmux {
            historySize = last.historySize
        } else {
            historySize = TuiLimits.historyDumpLines
        }
        let linesBack = min(max(historySize, 0), TuiLimits.historyDumpLines)
        do {
            let text = try tmux.capturePane(target, linesBack)
            liveRec.writeJSON([
                "t": t, "type": "history-dump", "lines_back": linesBack, "text": text,
            ], to: .observations)
            liveRec.detectorEvents.append(.dump(t: t, text: text, ptyRows: liveRec.lastPtyRows ?? lastTmuxRows(liveRec)))
            ingestQueue.async { [weak self] in self?.runStreamDetectors(liveRec) }
        } catch {
            CrowLog.info("[CrowTui capture_timeout window=\(liveRec.record.tmuxWindow)]")
        }
    }

    private func lastTmuxRows(_ liveRec: LiveRecording) -> Int {
        liveRec.lastTmux?.rows ?? liveRec.lastPtyRows ?? 24
    }

    private func armSampler() {
        samplerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.sampleTick()
            self?.armSampler()
        }
        samplerWork = work
        samplerQueue.asyncAfter(deadline: .now() + samplerInterval, execute: work)
    }

    private func armReaper() {
        reaperWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reap()
            self?.armReaper()
        }
        reaperWork = work
        samplerQueue.asyncAfter(deadline: .now() + 86400, execute: work)
    }

    private func sampleTick() {
        let snapshots: [LiveRecording] = ingestQueue.sync {
            Array(live.values.filter { $0.record.status == .unbound || $0.record.status == .recording })
        }
        for liveRec in snapshots {
            if Thread.isMainThread { captureOnMainActor = true }
            let target = "\(TerminalCockpit.sessionName):\(liveRec.record.tmuxWindow)"
            do {
                let raw = try tmux.displayMessage(
                    target,
                    "#{pane_width} #{pane_height} #{cursor_x} #{cursor_y} #{alternate_on} #{alternate-screen} #{pane_in_mode} #{history_size} #{history_limit}")
                let parts = raw.split(separator: " ")
                guard parts.count >= 9,
                      let cols = Int(parts[0]), let rows = Int(parts[1]),
                      let cx = Int(parts[2]), let cy = Int(parts[3]),
                      let altOn = Int(parts[4]),
                      let histSize = Int(parts[7]), let histLimit = Int(parts[8])
                else { continue }
                let altScreen = parts[5] == "on" || parts[5] == "1"
                let inMode = (Int(parts[6]) ?? 0) != 0
                let viewport = try tmux.capturePane(target, 0)
                let hash = "sha256:" + sha256Hex(viewport)
                let sample = TuiTmuxSample(
                    t: 0, cols: cols, rows: rows, cursorX: cx, cursorY: cy,
                    alternateOn: altOn != 0, alternateScreen: altScreen,
                    paneInMode: inMode, historySize: histSize, historyLimit: histLimit,
                    viewportHash: hash, viewportText: nil)
                ingestQueue.async { [weak self] in
                    guard let self, self.live[liveRec.record.id] != nil else { return }
                    let t = self.t(for: liveRec)
                    var stored = sample
                    stored.t = t
                    // Store raw viewport only when hashes diverge from last client sample.
                    if let client = liveRec.clientSamples.last, client.sample.visibleHash != hash {
                        stored.viewportText = viewport
                    }
                    liveRec.lastTmux = stored
                    liveRec.writeJSON([
                        "t": t, "type": "tmux-sample",
                        "cols": cols, "rows": rows,
                        "cursor_x": cx, "cursor_y": cy,
                        "alternate_on": altOn != 0,
                        "alternate_screen": altScreen,
                        "history_size": histSize,
                        "visible_hash": hash,
                    ], to: .observations)
                    liveRec.detectorEvents.append(.tmux(t: t, sample: stored, agentSurface: liveRec.record.agentSurface))
                    self.runStreamDetectors(liveRec)
                    self.maybeCap(liveRec)
                }
            } catch {
                CrowLog.info("[CrowTui capture_timeout window=\(liveRec.record.tmuxWindow)]")
            }
        }
    }

    private func broadcastNotActive(_ id: UUID) {
        let rec = index.get(id)
        broadcast(
            recordingID: id,
            sessionID: rec?.sessionID,
            t: 0, kind: "not_active", severity: "yellow",
            signature: "not_active", grid: nil)
    }

    private func broadcastObservation(_ obs: TuiObservation, recordingID: UUID, sessionID: UUID) {
        var grid: [String: [Int]]?
        if case .object(let pty)? = obs.facts["pty"],
           case .int(let pc)? = pty["cols"], case .int(let pr)? = pty["rows"],
           case .object(let css)? = obs.facts["css"],
           case .int(let cc)? = css["cols"], case .int(let cr)? = css["rows"] {
            grid = ["pty": [pc, pr], "css": [cc, cr]]
        }
        broadcast(
            recordingID: recordingID, sessionID: sessionID,
            t: obs.t, kind: obs.kind, severity: obs.severity,
            signature: obs.signature, grid: grid)
    }

    private func broadcast(
        recordingID: UUID, sessionID: UUID?,
        t: Int, kind: String, severity: String, signature: String,
        grid: [String: [Int]]?
    ) {
        guard let eventHub else { return }
        let frame = EventHub.tuiRecordEventFrame(
            recordingID: recordingID, sessionID: sessionID,
            t: t, kind: kind, severity: severity, signature: signature, grid: grid)
        Task { await eventHub.broadcast(frame) }
    }

    private func loadReport(_ dir: URL) -> TuiReport? {
        let url = dir.appendingPathComponent("report.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TuiReport.self, from: data)
    }

    private static func isRunningUnderTests() -> Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil { return true }
        let arg0 = CommandLine.arguments.first
        let runnerNames: Set<String> = ["swiftpm-testing-helper", "xctest"]
        if let base = (arg0 as NSString?)?.lastPathComponent, runnerNames.contains(base) { return true }
        if runnerNames.contains(ProcessInfo.processInfo.processName) { return true }
        if arg0?.contains(".xctest") == true { return true }
        return false
    }

    private static func trapIfConstructingLivePathUnderTests() {
        guard isRunningUnderTests() else { return }
        fatalError("""
            TuiRecorder() was constructed with the default LIVE recordings path \
            under a test process (ADR 0012). Inject an explicit temp directory.
            """)
    }
}

func sha256Hex(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Per-recording live state

private final class LiveRecording: @unchecked Sendable {
    var record: TuiRecordingRecord
    let dir: URL
    let startedAt: Date
    var tee: TuiBoundedTee?
    var boundGroup: String?
    var bytes = 0
    var lastPtyCols: Int?
    var lastPtyRows: Int?
    var lastTmux: TuiTmuxSample?
    var clientSamples: [(t: Int, sample: TuiClientSample)] = []
    var detectorEvents: [TuiDetectors.Event] = []
    var observations: [TuiObservation] = []
    var dumpInFlight = false
    var unbindTimer: DispatchWorkItem?
    var lastSampleT: Int?
    private var sampleTimes: [Int] = []
    private var ptyHandle: FileHandle?
    private var obsHandle: FileHandle?
    private let writeLock = NSLock()

    enum Stream { case pty, observations }

    init(record: TuiRecordingRecord, dir: URL, startedAt: Date) {
        self.record = record
        self.dir = dir
        self.startedAt = startedAt
        let ptyURL = dir.appendingPathComponent("pty.ndjson")
        let obsURL = dir.appendingPathComponent("observations.ndjson")
        FileManager.default.createFile(atPath: ptyURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: obsURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        ptyHandle = try? FileHandle(forWritingTo: ptyURL)
        obsHandle = try? FileHandle(forWritingTo: obsURL)
    }

    func writeHeader() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        writeJSON([
            "v": 1, "type": "header",
            "recording_id": record.id.uuidString,
            "started_at": iso.string(from: startedAt),
            "session_id": record.sessionID.uuidString,
            "terminal_id": record.terminalID.uuidString,
            "tmux_window": record.tmuxWindow,
            "pty_source": record.ptySource.rawValue,
            "client_samples": record.clientSamples,
            "agent_surface": record.agentSurface,
            "cols": 80, "rows": 24,
        ], to: .pty)
    }

    func writeJSON(_ dict: [String: Any], extra: TuiClientSample? = nil, to stream: Stream) {
        var merged = dict
        if let extra, let data = try? JSONEncoder().encode(extra),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj { merged[k] = v }
        }
        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) else { return }
        writeLock.lock()
        let handle = stream == .pty ? ptyHandle : obsHandle
        handle?.seekToEndOfFile()
        handle?.write(data)
        handle?.write(Data([0x0A]))
        writeLock.unlock()
    }

    func writeObservation(_ obs: TuiObservation) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(obs) else { return }
        writeLock.lock()
        obsHandle?.seekToEndOfFile()
        obsHandle?.write(data)
        obsHandle?.write(Data([0x0A]))
        writeLock.unlock()
    }

    func writeReport(_ report: TuiReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(report) else { return }
        let url = dir.appendingPathComponent("report.json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        writeManifest()
    }

    func writeManifest() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dict: [String: Any] = [
            "recording_id": record.id.uuidString,
            "session_id": record.sessionID.uuidString,
            "terminal_id": record.terminalID.uuidString,
            "status": record.status.rawValue,
            "pty_source": record.ptySource.rawValue,
            "client_samples": record.clientSamples,
            "started_at": iso.string(from: record.startedAt),
            "bytes": record.bytes,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted]) else { return }
        let url = dir.appendingPathComponent("manifest.json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func acceptSample(at t: Int) -> Bool {
        sampleTimes.append(t)
        sampleTimes = sampleTimes.filter { t - $0 <= 1000 }
        lastSampleT = t
        return sampleTimes.count <= TuiLimits.sampleRatePerSecond
    }

    func cancelUnbindTimer() {
        unbindTimer?.cancel()
        unbindTimer = nil
    }

    func close() {
        writeLock.lock()
        try? ptyHandle?.close()
        try? obsHandle?.close()
        ptyHandle = nil
        obsHandle = nil
        writeLock.unlock()
    }
}
