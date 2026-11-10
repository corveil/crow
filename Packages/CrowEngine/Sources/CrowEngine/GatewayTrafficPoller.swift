import CrowCore
import CrowPersistence
import Foundation

/// When the gateway-traffic verifier runs (CROW-1423). Pure, so the cadence
/// is unit-tested without a clock or a daemon.
///
/// The poller checks every ``checkInterval`` (30 s, one small config read),
/// and this decides:
///
/// - **Debug mode off:** never read a request log. On the first check after
///   it turns off, ``Action/clear`` the evidence so a stale verdict can't
///   reappear when it is turned back on.
/// - **Debug mode on:** run at once the first time it is seen on — at `crowd`
///   start with it already on, or within one check of turning it on — then at
///   most once per ``passInterval`` (5 min, the log-sync cadence).
public struct GatewayTrafficSchedule: Sendable, Equatable {
    public static let checkInterval: TimeInterval = 30
    public static let passInterval: TimeInterval = 300

    public enum Action: Sendable, Equatable { case idle, run, clear }

    var lastPassAt: Date?
    var enabled = false

    public init() {}

    public mutating func next(debugMode: Bool, now: Date) -> Action {
        guard debugMode else {
            defer { enabled = false; lastPassAt = nil }
            return enabled ? .clear : .idle
        }
        if enabled, let last = lastPassAt, now.timeIntervalSince(last) < Self.passInterval {
            return .idle
        }
        enabled = true
        lastPassAt = now
        return .run
    }
}

/// Runs the verifier on ``GatewayTrafficSchedule`` and publishes the result to
/// ``GatewayTrafficBoard``. This is the only caller of the verifier, so it is
/// the gate for "with debug mode off, `crowd` reads no request log".
public actor GatewayTrafficPoller {
    private let devRoot: String
    private let appState: AppState
    private let loadConfig: @Sendable (String) -> AppConfig?
    private let verifier: GatewayTrafficVerifier
    private let board: GatewayTrafficBoard
    private let now: @Sendable () -> Date
    private var schedule = GatewayTrafficSchedule()
    /// Source problems already logged, so a key that stays unreadable is said
    /// once rather than every pass.
    private var logged = Set<String>()

    public init(
        devRoot: String,
        appState: AppState,
        loadConfig: @escaping @Sendable (String) -> AppConfig? = { ConfigStore.loadConfig(devRoot: $0) },
        verifier: GatewayTrafficVerifier = GatewayTrafficVerifier(),
        board: GatewayTrafficBoard = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.devRoot = devRoot
        self.appState = appState
        self.loadConfig = loadConfig
        self.verifier = verifier
        self.board = board
        self.now = now
    }

    /// One check. Returns what it did, for tests.
    @discardableResult
    public func tick() async -> GatewayTrafficSchedule.Action {
        let config = loadConfig(devRoot)
        let at = now()
        let action = schedule.next(debugMode: config?.debugMode.enabled == true, now: at)
        switch action {
        case .idle:
            break
        case .clear:
            board.replace([:], sources: [], at: at)
            logged.removeAll()
        case .run:
            guard let config else { break }
            let appState = appState
            let inputs = await MainActor.run { SessionService.gatewayTrafficInputs(appState) }
            let (evidence, sources) = await verifier.run(inputs: inputs, config: config, devRoot: devRoot)
            board.replace(evidence, sources: sources, at: now())
            for source in sources where !source.readable {
                // Labels carry an org name and a key *prefix*, never a key.
                let line = "[GatewayTraffic] \(source.label): \(source.note)"
                if logged.insert(line).inserted { CrowLog.info(line) }
            }
        }
        return action
    }

    /// Check forever, every ``GatewayTrafficSchedule/checkInterval``. The
    /// first check runs immediately.
    public nonisolated func start() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(nanoseconds: UInt64(GatewayTrafficSchedule.checkInterval * 1_000_000_000))
            }
        }
    }
}
