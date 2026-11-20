import CrowCore
import Foundation
import Testing

@testable import CrowIPC

/// The gate that keeps the MCP export set from drifting (CROW-1004).
///
/// The ticket's requirement is that "a new RPC cannot silently become a Grok tool".
/// Three things have to agree for that to hold: the tool catalog, the ledger's
/// per-row MCP flag, and the local-only denial list. Each of the assertions below
/// pins one edge of that triangle, in the direction that fails **closed**.
///
/// This suite lives in `CrowIPC` rather than `CrowDaemon` deliberately: `CrowIPC` is
/// in `ci.yml`'s `LINUX_PACKAGES`, so it runs on every pull request, whereas the
/// daemon's tests are macOS-only and do not (ADR 0007, ADR 0016).
@Suite("MCP ledger export parity")
struct MCPLedgerExportTests {

    private var ledgerByMethod: [String: ParityLedger.RPCEntry] {
        Dictionary(ParityLedger.rpcMethods.map { ($0.method, $0) }, uniquingKeysWith: { a, _ in a })
    }

    @Test("Every method a tool reads is flagged for MCP export in the ledger")
    func exportedMethodsAreLedgered() {
        for tool in MCPToolCatalog.all {
            for method in tool.backingMethods.sorted() {
                guard let entry = ledgerByMethod[method] else {
                    Issue.record("Tool \(tool.name) reads '\(method)', which has no ParityLedger row")
                    continue
                }
                #expect(
                    entry.mcp.isExported,
                    """
                    Tool \(tool.name) calls '\(method)', but that ledger row is not flagged \
                    for MCP export. Add `mcp: .read(scope: …)` (or `.write(scope: …)` for a \
                    mutating method) to the row in ParityLedger.swift, or stop calling the method.
                    """)
            }
        }
    }

    @Test("A tool's scope matches the scope its backing methods are exported at")
    func toolScopeMatchesLedgerScope() {
        for tool in MCPToolCatalog.all {
            for method in tool.backingMethods.sorted() {
                guard let entry = ledgerByMethod[method], let scope = entry.mcp.scope else { continue }
                #expect(
                    scope == tool.scope,
                    """
                    Tool \(tool.name) requires \(tool.scope.rawValue) but reads '\(method)', \
                    which the ledger exports at \(scope.rawValue). A caller holding only \
                    \(tool.scope.rawValue) would read data gated behind \(scope.rawValue).
                    """)
            }
        }
    }

    @Test("No ledger row is flagged for export without a tool that uses it")
    func noOrphanExportFlags() {
        let used = MCPToolCatalog.exportedMethods
        let flagged = Set(ParityLedger.rpcMethods.filter(\.mcp.isExported).map(\.method))
        let orphans = flagged.subtracting(used)
        #expect(
            orphans.isEmpty,
            """
            These ledger rows are flagged for MCP export but no tool reads them: \
            \(orphans.sorted()). An unused flag is a standing permission nobody asked for — \
            remove the flag, or add the tool.
            """)
    }

    @Test("An exported write is exposed as a write at a write scope; a read at a read scope")
    func exportedWritesCarryWriteScopes() {
        // ADR 0019 made the surface read-only; its CROW-1491 amendment allows
        // writes, but only under named write scopes. This is the rule that keeps
        // that true: a mutating method flagged `.read(scope:)`, or a write exported
        // at a read scope, would let a read-only token change Crow.
        for entry in ParityLedger.rpcMethods where entry.mcp.isExported {
            guard let scope = entry.mcp.scope else { continue }
            if entry.isWrite {
                #expect(
                    entry.mcp.isWrite,
                    """
                    '\(entry.method)' is a write but is exported as `.read(scope:)`. \
                    Use `.write(scope:)` with a write scope.
                    """)
                #expect(
                    scope.isWrite,
                    """
                    '\(entry.method)' is a write exported at \(scope.rawValue), a read scope. \
                    A read-only token would be able to change Crow.
                    """)
            } else {
                #expect(
                    !entry.mcp.isWrite,
                    "'\(entry.method)' is a read but is exported as `.write(scope:)`.")
                #expect(
                    !scope.isWrite,
                    """
                    '\(entry.method)' is a read exported at \(scope.rawValue), a write scope. \
                    Reads belong under a read scope so a read-only token can see them.
                    """)
            }
        }
    }

    @Test("Every tool's scope agrees with whether it writes")
    func toolScopeMatchesWriteness() {
        // A tool that calls any write must sit behind a write scope, and a tool
        // behind a write scope must actually write — otherwise the consent page's
        // "never pre-tick a write scope" protects nothing, or hides a read.
        for tool in MCPToolCatalog.all {
            let writes = tool.backingMethods.contains { ledgerByMethod[$0]?.isWrite == true }
            #expect(
                writes == tool.scope.isWrite,
                """
                Tool \(tool.name) is scoped \(tool.scope.rawValue) but \
                \(writes ? "calls a write" : "only reads").
                """)
        }
    }

    @Test("Every write scope is used by some tool")
    func writeScopesAreUsed() {
        // An unused write scope would be a mintable credential that grants
        // nothing today and something tomorrow, without a fresh decision.
        let used = Set(MCPToolCatalog.all.map(\.scope))
        for scope in MCPScope.allCases where scope.isWrite {
            #expect(used.contains(scope), "\(scope.rawValue) is a write scope no tool uses")
        }
    }

    @Test("No exported method is local-only")
    func exportedMethodsAreNotLocalOnly() {
        // The acceptance criterion "local-only RPCs remain unreachable over the
        // remote MCP path", asserted structurally rather than by inspection.
        let exported = MCPToolCatalog.exportedMethods
        let overlap = exported.intersection(ParityLedger.localOnlyRPCMethods)
        #expect(
            overlap.isEmpty,
            """
            These methods are both MCP-exported and local-only: \(overlap.sorted()). \
            A remote bearer token would reach a surface /rpc refuses for remote peers.
            """)
    }

    @Test("Every local-only method has a ledger row")
    func localOnlyMethodsAreLedgered() {
        // Keeps `localOnlyRPCMethods` honest from this side: a typo'd method name
        // would otherwise sit in the set forever, silently protecting nothing while
        // reading as though it did.
        let ledgered = Set(ParityLedger.rpcMethods.map(\.method))
        let unknown = ParityLedger.localOnlyRPCMethods.subtracting(ledgered)
        #expect(
            unknown.isEmpty,
            "localOnlyRPCMethods names methods with no ledger row: \(unknown.sorted()) — likely a typo.")
    }

    @Test("The exported set is exactly the methods currently approved")
    func exportedSetIsPinned() {
        // A snapshot, so *growing* the MCP surface is a deliberate edit to this
        // list and shows up in the diff a reviewer reads — which is the same
        // argument ADR 0016 makes for the ledger itself.
        #expect(
            MCPToolCatalog.exportedMethods == [
                "list-sessions", "list-sessions-live", "get-session",
                "list-tickets", "list-reviews",
                "todo-list", "todo-get",
                "todo-add",
            ])
    }

    @Test("The exported writes are exactly the ones ADR 0019's amendment approves")
    func exportedWritesArePinned() {
        // Pinned on its own so a new write cannot hide inside a bigger snapshot
        // edit. `todo-add` is capture only (CROW-1491). `todo-explore` and
        // `todo-ticket` launch a Manager with dev-root permissions and need their
        // own scope and ADR decision before they appear here.
        let writes = Set(ParityLedger.rpcMethods.filter { $0.mcp.isExported && $0.isWrite }.map(\.method))
        #expect(writes == ["todo-add"])
        let writeScopes = Set(MCPScope.allCases.filter(\.isWrite))
        #expect(writeScopes == [.todosWrite])
    }

    @Test("Tool names are unique and MCP-legal")
    func toolNamesAreWellFormed() {
        let names = MCPToolCatalog.all.map(\.name)
        #expect(Set(names).count == names.count, "Duplicate tool names: \(names)")
        let legal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        for name in names {
            #expect(!name.isEmpty && name.count <= 128, "Tool name out of length bounds: \(name)")
            #expect(
                name.unicodeScalars.allSatisfy(legal.contains),
                "Tool name '\(name)' uses characters outside the MCP-recommended set")
        }
    }

    @Test("Every tool declares at least one backing method and a non-empty schema")
    func toolsAreComplete() {
        for tool in MCPToolCatalog.all {
            #expect(!tool.backingMethods.isEmpty, "Tool \(tool.name) declares no backing methods")
            #expect(!tool.description.isEmpty, "Tool \(tool.name) has no description")
            #expect(
                tool.inputSchema.objectValue?["type"]?.stringValue == "object",
                "Tool \(tool.name)'s inputSchema must be a JSON Schema object")
        }
    }

    @Test("Scope filtering hides tools rather than only refusing them")
    func scopeFilteringIsExhaustive() {
        // Every tool must be reachable by *some* scope set, and no tool may leak
        // into a scope set that does not include its own.
        for tool in MCPToolCatalog.all {
            #expect(MCPToolCatalog.tools(for: [tool.scope]).contains { $0.name == tool.name })
            let others = Set(MCPScope.allCases).subtracting([tool.scope])
            #expect(!MCPToolCatalog.tools(for: others).contains { $0.name == tool.name })
        }
        #expect(MCPToolCatalog.tools(for: []).isEmpty)
        #expect(MCPToolCatalog.tools(for: MCPScope.all).count == MCPToolCatalog.all.count)
    }

    @Test("The tool catalog's status and kind vocabularies match the real enums")
    func vocabulariesMatchEnums() {
        // The schemas restate these so the JSON Schema stays stable, which only works
        // if something notices when the enums move.
        #expect(Set(MCPToolCatalog.sessionStatuses) == Set(SessionStatus.allCases.map(\.rawValue)))
        #expect(Set(MCPToolCatalog.sessionKinds) == Set(SessionKind.allCases.map(\.rawValue)))
        #expect(Set(MCPToolCatalog.reviewGroups) == Set(ReviewGroup.allCases.map(\.rawValue)))
        #expect(Set(MCPToolCatalog.todoStates) == Set(TodoState.allCases.map(\.rawValue)))
    }
}
