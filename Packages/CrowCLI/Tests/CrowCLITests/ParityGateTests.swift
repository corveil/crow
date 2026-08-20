import ArgumentParser
import CrowCore
import Foundation
import Testing

@testable import CrowCLILib

/// CLI control-plane parity gate (CROW-807, ADR 0016).
///
/// Holds `ParityLedger` to the two surfaces this target can actually see: the
/// `crow` verb tree and `AppConfig`. The third surface — the registered RPC
/// methods — is checked by `CrowDaemonTests/RPCLedgerParityTests` and by
/// `scripts/check-cli-parity.sh`, because CrowCLI cannot depend on CrowDaemon.
///
/// A failure here means someone shipped a config field or changed a verb without
/// deciding how the CLI reaches it. The fix is a ledger row, not a weakened test.
@Suite("CLI control-plane parity")
struct ParityGateTests {

    // MARK: - Verb tree

    /// Every `crow` verb as a full space-separated path — `"job add"`,
    /// `"web-password status"`. Group parents (`"job"`) are included too, so a
    /// ledger row may point at a group when that is genuinely the entry point.
    ///
    /// Keyed on the full path on purpose: six different leaf commands are named
    /// `set` and six are named `get`, so leaf names alone are ambiguous.
    static func verbPaths(
        of command: ParsableCommand.Type = CrowCommand.self,
        prefix: [String] = []
    ) -> Set<String> {
        var paths: Set<String> = []
        for sub in command.configuration.subcommands {
            let name = sub.configuration.commandName ?? String(describing: sub).lowercased()
            let path = prefix + [name]
            paths.insert(path.joined(separator: " "))
            paths.formUnion(verbPaths(of: sub, prefix: path))
        }
        return paths
    }

    // MARK: - AppConfig reflection

    /// Types that are structs underneath but are values to a user — recursing
    /// into them would yield noise like `jobs[].id.uuid`.
    static let opaqueLeafTypes: [Any.Type] = [
        UUID.self, Date.self, URL.self, Data.self,
    ]

    /// Containers the probe left empty, so the walk could not see through them.
    /// Collected rather than ignored: an unpopulated optional or collection is
    /// exactly how a subtree of new config fields would slip past this gate.
    struct WalkResult {
        var leaves: Set<String> = []
        var unpopulated: Set<String> = []
    }

    /// Recursively enumerate the leaf fields of a value as dotted paths.
    ///
    /// Collection and dictionary *elements* get a `[]` segment
    /// (`workspaces[].jiraJQL`); a collection or dictionary of scalars collapses
    /// to a single leaf at its own path (`defaults.excludeDirs`, `agentsByKind`),
    /// because there is nothing underneath worth addressing separately.
    static func walk(_ value: Any, prefix: String, into result: inout WalkResult) {
        let mirror = Mirror(reflecting: value)

        if opaqueLeafTypes.contains(where: { $0 == type(of: value) }) {
            result.leaves.insert(prefix)
            return
        }

        // `AgentKind` is a RawRepresentable *struct*, not an enum, so Mirror
        // reports it as a shape with a `rawValue` child. It is a value to the
        // user; recursing would yield `defaultAgentKind.rawValue`.
        if value is any RawRepresentable {
            result.leaves.insert(prefix)
            return
        }

        switch mirror.displayStyle {
        case .optional:
            guard let wrapped = mirror.children.first?.value else {
                result.unpopulated.insert(prefix)
                result.leaves.insert(prefix)
                return
            }
            walk(wrapped, prefix: prefix, into: &result)

        case .collection:
            guard let element = mirror.children.first?.value else {
                result.unpopulated.insert(prefix)
                result.leaves.insert(prefix)
                return
            }
            collapseOrKeep(element, prefix: prefix, into: &result)

        case .dictionary:
            // Each child of a dictionary mirror is a (key, value) pair.
            guard let pair = mirror.children.first?.value,
                  let element = Mirror(reflecting: pair).children.dropFirst().first?.value
            else {
                result.unpopulated.insert(prefix)
                result.leaves.insert(prefix)
                return
            }
            collapseOrKeep(element, prefix: prefix, into: &result)

        case .struct, .class:
            guard !mirror.children.isEmpty else {
                result.leaves.insert(prefix)
                return
            }
            for child in mirror.children {
                guard let label = child.label else { continue }
                let next = prefix.isEmpty ? label : "\(prefix).\(label)"
                walk(child.value, prefix: next, into: &result)
            }

        default:
            // Enums (JobSchedule) and primitives are values, not shapes.
            result.leaves.insert(prefix)
        }
    }

    /// Walk a container's element. If the element is itself a leaf, the whole
    /// container collapses to one path; if it has structure, keep the `[]` segment.
    private static func collapseOrKeep(_ element: Any, prefix: String, into result: inout WalkResult) {
        var inner = WalkResult()
        walk(element, prefix: "\(prefix)[]", into: &inner)
        if inner.leaves == ["\(prefix)[]"] {
            result.leaves.insert(prefix)
        } else {
            result.leaves.formUnion(inner.leaves)
            result.unpopulated.formUnion(inner.unpopulated)
        }
    }

    /// An `AppConfig` with **every** optional inhabited and every collection
    /// non-empty, so `Mirror` can see the whole tree — a default `AppConfig()`
    /// leaves `managerGateway`/`jiraCredential`/`webAuth` nil and the arrays
    /// empty, which would hide ~25 fields from the gate.
    ///
    /// `probeIsFullyPopulated` fails if this drifts, so a new nested field cannot
    /// hide behind an unpopulated container.
    static func parityProbeConfig() -> AppConfig {
        let gateway = WorkspaceGateway(baseURL: "https://gw.example", customHeaders: ["X-Probe": "1"])
        return AppConfig(
            workspaces: [
                WorkspaceInfo(
                    name: "probe",
                    host: "git.example",
                    alwaysInclude: ["owner/repo"],
                    autoReviewRepos: ["owner/repo"],
                    excludeReviewRepos: ["owner/repo"],
                    customInstructions: "probe",
                    reviewBlockingSeverities: [.red],
                    taskProvider: "jira",
                    jiraProjectKey: "PROBE",
                    jiraJQL: "project = PROBE",
                    jiraSite: "probe.atlassian.net",
                    jiraStatusMap: ["inProgress": "In Progress"],
                    sessionEnv: ["PROBE_ENV": "1"],
                    uploadSessionLogs: true,
                    gateway: gateway
                )
            ],
            defaults: ConfigDefaults(
                excludeReviewRepos: ["owner/repo"],
                excludeTicketRepos: ["owner/repo"],
                ignoreReviewLabels: ["wip"],
                binaries: ["claude": "/usr/local/bin/claude"]
            ),
            notifications: NotificationSettings(eventSettings: [.taskComplete: EventNotificationConfig()]),
            telemetry: TelemetryConfig(),
            terminal: TerminalSettings(),
            autoRespond: AutoRespondSettings(),
            cleanup: CleanupConfig(),
            versionUpdate: VersionUpdateConfig(),
            jobs: [
                JobConfig(
                    name: "probe",
                    workspace: "probe",
                    repo: "owner/repo",
                    prompts: ["probe"],
                    schedule: .interval(seconds: 3600),
                    lastRunAt: Date()
                )
            ],
            agentsByKind: ["work": .claudeCode],
            managerGateway: gateway,
            jiraCredential: JiraCredential(username: "probe", tokenRef: "op://probe/token"),
            webAuth: WebAuthConfig(hashB64: "aGFzaA==", saltB64: "c2FsdA==", iterations: 210_000),
            mcpTokens: [
                MCPTokenRecord(
                    name: "probe",
                    prefix: "AbCdEfGh",
                    hashB64: "aGFzaA==",
                    scopes: [.sessionsRead, .boardRead],
                    expiresAt: Date())
            ],
            logSync: LogSyncConfig(
                retentionDays: 30,
                quietPeriodMinutes: 30,
                maxUploadBytes: 8_000_000)
        )
    }

    static func walkProbe() -> WalkResult {
        var result = WalkResult()
        walk(parityProbeConfig(), prefix: "", into: &result)
        return result
    }

    static func report(_ title: String, _ items: some Collection<String>) -> String {
        "\(title) (\(items.count)):\n" + items.sorted().map { "  \($0)" }.joined(separator: "\n")
    }

    // MARK: - Ledger hygiene

    @Test("Ledger rows are unique")
    func ledgerRowsAreUnique() {
        let methods = ParityLedger.rpcMethods.map(\.method)
        let dupeMethods = Set(methods.filter { m in methods.filter { $0 == m }.count > 1 })
        #expect(dupeMethods.isEmpty, "Duplicate rpcMethods rows: \(dupeMethods.sorted())")

        let paths = ParityLedger.configFields.map(\.path)
        let dupePaths = Set(paths.filter { p in paths.filter { $0 == p }.count > 1 })
        #expect(dupePaths.isEmpty, "Duplicate configFields rows: \(dupePaths.sorted())")
    }

    /// An exemption is only a decision if it says something. A bare `""` or
    /// `"n/a"` would turn the ledger back into a rubber stamp.
    @Test("Every exemption carries a substantive reason")
    func exemptionsAreJustified() {
        let minimumReasonLength = 40
        var reasons: [(String, String)] = []
        for entry in ParityLedger.rpcMethods {
            if let reason = entry.coverage.exemptionReason { reasons.append((entry.method, reason)) }
        }
        for entry in ParityLedger.configFields {
            if let reason = entry.read.exemptionReason { reasons.append(("\(entry.path) (read)", reason)) }
            if let reason = entry.write.exemptionReason { reasons.append(("\(entry.path) (write)", reason)) }
        }

        for (subject, reason) in reasons {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(
                trimmed.count >= minimumReasonLength,
                """
                Exemption for \(subject) needs a real justification \
                (>= \(minimumReasonLength) chars, got \(trimmed.count)): "\(trimmed)"
                """)
        }
    }

    // MARK: - Write classification

    /// Names that read as queries: `get-…`, `list-…`, `…-get`, `…-list`.
    static func namePresumesRead(_ method: String) -> Bool {
        method.hasPrefix("get-") || method.hasPrefix("list-")
            || method.hasSuffix("-get") || method.hasSuffix("-list")
    }

    /// Rows whose deliberate `isWrite` classification disagrees with the name.
    ///
    /// The hand classification always wins — a method named `get-something` that
    /// mutates state is a write, full stop. This set only forces the disagreement
    /// to be *stated* rather than sitting unnoticed in a row nobody re-reads.
    static let namingExceptions: Set<String> = [
        // `backfill-scan` reconciles on-disk transcripts and returns them — a pure
        // read — but its name isn't `get-`/`list-` prefixed, so the heuristic
        // presumes a write (CROW-1075).
        "backfill-scan",
    ]

    /// `isWrite` is hand-set per row, deliberately, because a `get-`/`list-`
    /// heuristic would wave through a future write named `get-something`. But
    /// nothing checked the hand classification itself — so a write mislabelled
    /// `.read` would silently skip the write bar below. This cross-checks the two
    /// against each other without letting the heuristic overrule the decision.
    @Test("isWrite agrees with the method name, or the disagreement is declared")
    func writeClassificationMatchesNaming() {
        let disagreements = ParityLedger.rpcMethods
            .filter { Self.namePresumesRead($0.method) == $0.isWrite }
            .map(\.method)
            .filter { !Self.namingExceptions.contains($0) }
            .sorted()

        #expect(
            disagreements.isEmpty,
            """
            These rows classify against what their name suggests:
            \(disagreements.map { "  \($0)" }.joined(separator: "\n"))
            A `get-`/`list-` name marked .write, or any other name marked .read.
            If the classification is right, add the method to `namingExceptions`
            with a comment; if it's wrong, fix the row.
            """)
    }

    /// The un-CLI-able writes, pinned.
    ///
    /// This is the milestone's burn-down list: each per-area parity ticket
    /// deletes entries. Pinning the *set* — not just requiring a reason per row
    /// — is what makes adding one a deliberate, visible act instead of a single
    /// `.noCLI(…)` row lost among 85.
    static let knownWriteExemptions: Set<String> = [
        "batch-start-review",
        "run-job",
        "run-setup",
        "set-config",
        "set-pinned",
    ]

    @Test("The set of writes with no CLI path is exactly the pinned list")
    func writeExemptionsArePinned() {
        let actual = Set(
            ParityLedger.rpcMethods
                .filter { $0.isWrite && $0.coverage.exemptionReason != nil }
                .map(\.method))

        let added = actual.subtracting(Self.knownWriteExemptions)
        let closed = Self.knownWriteExemptions.subtracting(actual)

        #expect(
            added.isEmpty,
            """
            New write methods with no CLI path (\(added.count)):
            \(added.sorted().map { "  \($0)" }.joined(separator: "\n"))
            This is the drift CROW-807 exists to stop. Give the method a `crow`
            verb, or — if it genuinely cannot have one — add it to
            `knownWriteExemptions` so the widening is explicit in review.
            """)
        #expect(
            closed.isEmpty,
            """
            These writes now have a CLI path — remove them from
            `knownWriteExemptions` so the burn-down stays accurate (\(closed.count)):
            \(closed.sorted().map { "  \($0)" }.joined(separator: "\n"))
            """)
    }

    // MARK: - Ledger hygiene

    @Test("Every declared CLI path is a real verb")
    func declaredCLIPathsResolve() {
        let verbs = Self.verbPaths()
        var declared: [(String, String)] = []
        for entry in ParityLedger.rpcMethods {
            if let path = entry.coverage.cliPath { declared.append((entry.method, path)) }
        }
        for entry in ParityLedger.configFields {
            if let path = entry.read.cliPath { declared.append(("\(entry.path) (read)", path)) }
            if let path = entry.write.cliPath { declared.append(("\(entry.path) (write)", path)) }
        }

        let dangling = declared.filter { !verbs.contains($0.1) }
        #expect(
            dangling.isEmpty,
            """
            Ledger rows point at verbs that CrowCommand does not register:
            \(dangling.sorted { $0.0 < $1.0 }.map { "  \($0.0) -> \"\($0.1)\"" }.joined(separator: "\n"))
            Paths are full and space-separated, e.g. "job add", not "add".
            """)
    }

    // MARK: - AppConfig parity

    @Test("The reflection probe reaches every subtree")
    func probeIsFullyPopulated() {
        let result = Self.walkProbe()
        #expect(
            result.unpopulated.isEmpty,
            """
            parityProbeConfig() left these nil/empty, so Mirror could not walk into them
            and any fields underneath are invisible to this gate. Populate them:
            \(Self.report("unpopulated", result.unpopulated))
            """)
    }

    /// The gate proper: the ledger must name exactly the fields `AppConfig` has.
    /// Checked in both directions, so a removed field leaves a stale row that
    /// also fails — the ledger cannot rot in either direction.
    @Test("Ledger covers exactly AppConfig's fields")
    func configFieldsMatchAppConfig() {
        let actual = Self.walkProbe().leaves
        let ledgered = Set(ParityLedger.configFields.map(\.path))

        let missing = actual.subtracting(ledgered)
        let stale = ledgered.subtracting(actual)

        #expect(
            missing.isEmpty,
            """
            AppConfig fields with no ParityLedger.configFields row. Add one for each,
            stating how the CLI reads and writes it — or why it cannot:
            \(Self.report("missing from ledger", missing))
            """)
        #expect(
            stale.isEmpty,
            """
            ParityLedger.configFields rows for fields AppConfig no longer has.
            Delete them:
            \(Self.report("stale ledger rows", stale))
            """)
    }
}
