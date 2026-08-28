import CrowCore
import CrowEngine
import CrowGit
import CrowIPC
import CrowPersistence
import CrowTerminal
import Foundation

/// Builds the daemon's `CommandRouter`. Handlers mirror the corresponding
/// closures in the macOS app's `AppDelegate.startSocketServer`, but operate
/// purely on `AppState` + `JSONStore` (+ `GitManager` / the tmux `cockpit`)
/// with no AppKit or `SessionService` dependency, so the same domain logic
/// runs on a headless Linux `crowd` (CROW-581).
///
/// This function is a thin assembler (CROW-1134): it constructs shared deps
/// (`ReviewKickoffSerializer`, the Corveil org-list cache, …), merges
/// per-concern handler maps, and returns `CommandRouter(handlers:fallback:)`.
/// Each verb group lives in its own `*RPCHandlers.swift` file so Swift's
/// type-checker solver budget isn't spent on one giant dictionary literal —
/// and so `scripts/check-cli-parity.sh` can glob every registration file.
///
/// Method set:
/// - M0: `new-session`, `list-sessions`, `add-worktree`.
/// - M2 (web UI): expanded `list-sessions`, plus `list-terminals`,
///   `new-terminal`, `close-terminal` (per-session tmux windows).
///
/// `appState` is `@MainActor`-isolated; each handler hops to the main actor for
/// the in-memory mutation exactly as the app does, keeping the persisted
/// `store` and the observable `appState` in lockstep. `cockpit` is nil when no
/// tmux binary was found — terminal handlers then return an application error.
func makeCommandRouter(
    appState: AppState,
    store: JSONStore,
    git: GitManager,
    devRoot: String,
    cockpit: TerminalCockpit?,
    tracker: IssueTracker? = nil,
    allowList: AllowListService? = nil,
    sessionService: SessionService? = nil,
    autoRespond: AutoRespondCoordinator? = nil,
    jobScheduler: JobScheduler? = nil,
    // Backs `rebuild-scorecard` (#767). Defined by the daemon where both the
    // SessionService and the telemetry receiver are in scope; nil when telemetry
    // is off (there'd be no DB to rebuild from).
    rebuildScorecard: (@MainActor @Sendable () async -> Void)? = nil,
    versionUpdateService: VersionUpdateService? = nil,
    // The Corveil org-list cache (CROW-1121), shared between the connection verbs
    // (so `corveil-disconnect` can invalidate it) and the provisioning verbs.
    // Injectable so a test can observe the invalidation; one per router otherwise.
    corveilOrgCache: CorveilOrgListCache = CorveilOrgListCache(),
    soundLibrary: CustomSoundLibrary = .live,
    fallback: CommandRouter? = nil
) -> CommandRouter {
    // Serializes review kickoffs (see start-review) — one per router instance.
    let reviewSerializer = ReviewKickoffSerializer()
    // First-wins on a key collision. Groups are disjoint today; the uniquing
    // closure is the same one the pre-split merges used, so a future overlap
    // keeps the earlier registration rather than silently swapping bodies.
    var handlers: [String: CommandRouter.Handler] = [:]
    handlers.merge(
        makeSessionHandlers(
            appState: appState, store: store, git: git, devRoot: devRoot,
            cockpit: cockpit, tracker: tracker, sessionService: sessionService,
            autoRespond: autoRespond)
    ) { existing, _ in existing }
    handlers.merge(
        makeBoardHandlers(
            appState: appState, tracker: tracker, allowList: allowList,
            sessionService: sessionService, reviewSerializer: reviewSerializer)
    ) { existing, _ in existing }
    handlers.merge(
        makeSnapshotHandlers(
            appState: appState, rebuildScorecard: rebuildScorecard, devRoot: devRoot)
    ) { existing, _ in existing }
    handlers.merge(makeSecretsHandlers(devRoot: devRoot)) { existing, _ in existing }
    handlers.merge(
        makeLifecycleHandlers(
            appState: appState, store: store, sessionService: sessionService,
            jobScheduler: jobScheduler, tracker: tracker, devRoot: devRoot)
    ) { existing, _ in existing }
    handlers.merge(
        makeSettingsHandlers(
            versionUpdateService: versionUpdateService, devRoot: devRoot,
            soundLibrary: soundLibrary)
    ) { existing, _ in existing }
    handlers.merge(makeWorkspaceHandlers(appState: appState, devRoot: devRoot)) { existing, _ in existing }
    handlers.merge(makeMCPTokenHandlers(devRoot: devRoot)) { existing, _ in existing }
    handlers.merge(makeCorveilHandlers(appState: appState, devRoot: devRoot)) { existing, _ in existing }
    handlers.merge(
        makeCorveilConnectionHandlers(cache: corveilOrgCache, devRoot: devRoot)
    ) { existing, _ in existing }
    handlers.merge(
        makeCorveilProvisioningHandlers(cache: corveilOrgCache, devRoot: devRoot)
    ) { existing, _ in existing }
    handlers.merge(makeCorveilMigrationHandlers(devRoot: devRoot)) { existing, _ in existing }
    handlers.merge(makeBackfillHandlers(devRoot: devRoot)) { existing, _ in existing }
    return CommandRouter(handlers: handlers, fallback: fallback)
}
