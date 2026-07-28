import CrowCore
import CrowEngine
import CrowGit
import CrowIPC
import CrowPersistence
import Foundation
import Testing

@testable import CrowDaemon

/// CLI control-plane parity gate, RPC half (CROW-807, ADR 0016).
///
/// `ParityLedger.rpcMethods` must name exactly the methods the live router pair
/// answers. A new RPC method that nobody ledgered — and so nobody decided
/// whether to give a `crow` verb — fails here.
///
/// This is the authoritative form of the check: it asks the real
/// `CommandRouter`, composed exactly as `CrowDaemon` composes it (daemon
/// handlers with the engine router as fallback), rather than pattern-matching
/// source. `scripts/check-cli-parity.sh` makes the same assertion by text
/// because CrowDaemon depends on the Darwin-only CrowTelemetry and therefore
/// cannot run in the Linux PR lane (see `ci.yml`'s `LINUX_PACKAGES`) — the two
/// exist together so the gate runs on every PR *and* cannot be fooled by a
/// router refactor the regex would under-report.
///
/// Only assertions that need a live router live here. The ledger's internal
/// invariants — CLI paths resolving, `isWrite` classification, the write
/// exemption set — are in `CrowCLITests/ParityGateTests` so they run on PRs
/// too; this suite does not.
///
/// Router construction is side-effect free: `makeCommandRouter` only allocates
/// before its dictionary literal, and every handler's I/O lives inside a closure
/// that is never invoked here.
@Suite("RPC ledger parity")
@MainActor
struct RPCLedgerParityTests {

    /// Build the daemon router wired to the engine fallback, mirroring
    /// `CrowDaemon.swift`, and hand it to `body`.
    ///
    /// Scoped rather than returned so the temp dev root is removed afterwards —
    /// `makeCommandRouter` never touches it, but leaving a directory per test
    /// run behind is the kind of litter that compounds once a pattern spreads.
    private func withLiveRouter<T>(_ body: (CommandRouter) throws -> T) rethrows -> T {
        let devRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-parity-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: devRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let appState = AppState()
        let store = JSONStore.temporary()
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())

        let engine = makeEngineRouter(
            EngineContext(
                appState: appState,
                store: store,
                sessionService: service,
                issueTracker: nil,
                telemetryPort: nil,
                devRoot: devRoot,
                hostBridge: NoopHostBridge(),
                loadConfig: { nil },
                applyConfig: { _ in nil }
            ))

        let router = makeCommandRouter(
            appState: appState, store: store, git: GitManager(),
            devRoot: devRoot, cockpit: nil, fallback: engine)

        return try body(router)
    }

    @Test("Ledger names exactly the registered RPC methods")
    func ledgerMatchesRegisteredMethods() {
        let registered = withLiveRouter { $0.methodNames }
        let ledgered = Set(ParityLedger.rpcMethods.map(\.method))

        let missing = registered.subtracting(ledgered)
        let stale = ledgered.subtracting(registered)

        #expect(
            missing.isEmpty,
            """
            RPC methods with no ParityLedger.rpcMethods row (\(missing.count)):
            \(missing.sorted().map { "  \($0)" }.joined(separator: "\n"))
            Add a row for each, either
              .write("your-method", cli: "your verb")   — it has a crow verb, or
              .write("your-method", noCLI: "why not, and the ticket that closes it")
            """)
        #expect(
            stale.isEmpty,
            """
            ParityLedger.rpcMethods rows for methods no router registers (\(stale.count)):
            \(stale.sorted().map { "  \($0)" }.joined(separator: "\n"))
            Delete them.
            """)
    }

    /// Guards the text-based stand-in: if `methodNames` ever stopped walking the
    /// fallback chain, both this suite and the script would compare a truncated
    /// surface against a truncated ledger and agree.
    @Test("Router surface is the daemon/engine union, not just the daemon")
    func fallbackChainIsIncluded() {
        let names = withLiveRouter { $0.methodNames }
        // Registered only by the daemon router...
        #expect(names.contains("telemetry-set"))
        // ...and only by the engine router it falls back to.
        #expect(names.contains("set-goal"))
        #expect(names.count > 70, "Expected the union of both routers, got \(names.count) methods")
    }
}
