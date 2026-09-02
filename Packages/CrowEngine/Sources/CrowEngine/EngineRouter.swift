import Foundation
import CrowCore
import CrowIPC
import CrowPersistence

/// The RPC command router for the Crow engine, extracted from `AppDelegate` so
/// both the macOS app and the `crowd` daemon can build the same handler set
/// (CROW-581 headless-engine migration). Host-only touchpoints go through
/// `EngineContext.hostBridge`. Config I/O closures stay on the context
/// (callers still inject them) even though `get-config`/`set-config` live
/// only on the daemon after CROW-1174.
@MainActor
public struct EngineContext {
    public let appState: AppState
    public let store: JSONStore
    public let sessionService: SessionService
    public let issueTracker: IssueTracker?
    public let telemetryPort: UInt16?
    public let devRoot: String
    public let hostBridge: HostBridge
    public let loadConfig: @Sendable () async -> (String, AppConfig)?
    public let applyConfig: @Sendable (AppConfig) async -> AppConfig?

    public init(
        appState: AppState,
        store: JSONStore,
        sessionService: SessionService,
        issueTracker: IssueTracker?,
        telemetryPort: UInt16?,
        devRoot: String,
        hostBridge: HostBridge,
        loadConfig: @escaping @Sendable () async -> (String, AppConfig)?,
        applyConfig: @escaping @Sendable (AppConfig) async -> AppConfig?
    ) {
        self.appState = appState
        self.store = store
        self.sessionService = sessionService
        self.issueTracker = issueTracker
        self.telemetryPort = telemetryPort
        self.devRoot = devRoot
        self.hostBridge = hostBridge
        self.loadConfig = loadConfig
        self.applyConfig = applyConfig
    }
}

/// Builds the engine's `CommandRouter`. This function is a thin assembler
/// (CROW-1174): it captures `EngineContext` deps, merges per-concern handler
/// maps, and returns `CommandRouter(handlers:)`. Each live verb group lives
/// in its own `Engine*RPCHandlers.swift` file so Swift's type-checker solver
/// budget isn't spent on one giant dictionary literal — and so
/// `scripts/check-cli-parity.sh` can glob every registration file.
///
/// Method names the daemon already registers are **not** registered here.
/// `crowd` is built with `fallback: makeEngineRouter(ctx)`, so a shadowed
/// copy would be unreachable and would drift (ADR 0016). The live fallback
/// surface is session reads + ticket metadata, `list-worktrees`, terminals,
/// links, and `hook-event`.
@MainActor
public func makeEngineRouter(_ ctx: EngineContext) -> CommandRouter {
    let hookDebug = ProcessInfo.processInfo.environment["CROW_HOOK_DEBUG"] == "1"
    // First-wins on a key collision. Groups are disjoint today; the uniquing
    // closure is the same one the daemon's pre-split merges used, so a future
    // overlap keeps the earlier registration rather than silently swapping bodies.
    var handlers: [String: CommandRouter.Handler] = [:]
    handlers.merge(
        makeEngineSessionHandlers(
            appState: ctx.appState, store: ctx.store,
            sessionService: ctx.sessionService, tracker: ctx.issueTracker)
    ) { existing, _ in existing }
    handlers.merge(
        makeEngineTerminalHandlers(
            appState: ctx.appState, store: ctx.store,
            sessionService: ctx.sessionService,
            telemetryPort: ctx.telemetryPort, devRoot: ctx.devRoot)
    ) { existing, _ in existing }
    handlers.merge(
        makeEngineLinkHandlers(appState: ctx.appState, store: ctx.store)
    ) { existing, _ in existing }
    handlers.merge(
        makeEngineHookHandlers(
            appState: ctx.appState, store: ctx.store,
            sessionService: ctx.sessionService, hostBridge: ctx.hostBridge,
            hookDebug: hookDebug)
    ) { existing, _ in existing }
    return CommandRouter(handlers: handlers)
}
