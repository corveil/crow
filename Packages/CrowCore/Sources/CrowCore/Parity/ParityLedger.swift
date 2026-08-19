import Foundation

/// The checked-in CLI control-plane parity ledger (CROW-807, ADR 0016).
///
/// Crow's control plane exists three times over: the JSON-RPC methods `crowd`
/// registers, the `crow` verbs that call them, and the ``AppConfig`` fields both
/// mutate. Nothing in the compiler ties those together, so a capability can ship
/// as an RPC method plus a web control and quietly never grow a CLI path. This
/// ledger is the one place that states, per method and per config field, whether
/// a CLI path exists — and when it doesn't, *why*.
///
/// **It is not documentation; it is a gate.** Three checks keep it honest:
///
/// - `CrowCLITests/ParityGateTests` — every ``Coverage/cli(_:)`` path resolves
///   against `CrowCommand`'s subcommand tree, and ``configFields`` matches the
///   `Mirror` walk of `AppConfig` exactly, in both directions.
/// - `CrowDaemonTests/RPCLedgerParityTests` — ``rpcMethods`` matches
///   `CommandRouter.methodNames` for the live daemon+engine router pair.
/// - `scripts/check-cli-parity.sh` — the same RPC assertion by text, because
///   CrowDaemon is Darwin-only and cannot run in the Linux PR lane.
///
/// Adding a ``Coverage/noCLI(reason:)`` row is the review gate: the reason is a
/// required associated value, so an exemption cannot be added silently. Each
/// per-area parity ticket closes its gap by *deleting* rows from the exempt set.
///
/// ``Coverage/noCLI(reason:)`` is CROW-807's `KNOWN_UI_ONLY` allowlist, named for
/// what it asserts rather than what usually causes it — most exemptions are indeed
/// web-UI-only, but a few surfaces (the web-password hash) are readable nowhere.
public enum ParityLedger {

    // MARK: - Coverage

    /// Whether a surface is reachable from the `crow` CLI, or deliberately isn't.
    public enum Coverage: Sendable, Equatable {
        /// Reachable, via this full verb path — e.g. `"job add"`, `"web-password status"`.
        /// Leaf command names collide across groups (six commands are named `set`),
        /// so this is always the *full* path, never the leaf.
        case cli(String)

        /// Deliberately not reachable from the CLI. The reason is required and is
        /// checked for substance by `ParityGateTests`; state what drives the surface
        /// instead and, where one exists, the ticket that will close the gap.
        case noCLI(reason: String)

        public var cliPath: String? {
            if case .cli(let path) = self { return path }
            return nil
        }

        public var exemptionReason: String? {
            if case .noCLI(let reason) = self { return reason }
            return nil
        }
    }

    // MARK: - RPC methods

    /// Whether an RPC method may be read through the MCP server (CROW-1004).
    ///
    /// The default is ``none`` and the factories below default to it, so a newly
    /// registered RPC is **not** exported unless somebody types the flag. That
    /// direction is the whole point: a method that quietly becomes a Grok-reachable
    /// tool is the failure this exists to prevent, and "forgot to add the flag"
    /// must fail closed.
    ///
    /// There is no `write` case. v1 is read-only, and `MCPLedgerExportTests` fails
    /// the build if an exported row is also `isWrite` — so adding a write tool means
    /// coming here and deciding, not just registering a handler.
    public enum MCPExposure: Sendable, Equatable {
        /// Not reachable from MCP.
        case none
        /// Readable by an MCP caller holding this scope.
        case read(scope: MCPScope)

        public var scope: MCPScope? {
            if case .read(let scope) = self { return scope }
            return nil
        }

        public var isExported: Bool { scope != nil }
    }

    /// One registered JSON-RPC method.
    public struct RPCEntry: Sendable, Equatable {
        public let method: String
        /// `false` for pure queries; `true` for anything that mutates state or
        /// performs an action. Stated per row rather than inferred from a `get-`/
        /// `list-` prefix — a heuristic would wave through a future write named
        /// `get-something`.
        public let isWrite: Bool
        public let coverage: Coverage
        /// Whether the MCP server may read this method, and at what scope.
        public let mcp: MCPExposure

        public init(method: String, isWrite: Bool, coverage: Coverage, mcp: MCPExposure = .none) {
            self.method = method
            self.isWrite = isWrite
            self.coverage = coverage
            self.mcp = mcp
        }

        public static func read(
            _ method: String, cli path: String, mcp: MCPExposure = .none
        ) -> RPCEntry {
            RPCEntry(method: method, isWrite: false, coverage: .cli(path), mcp: mcp)
        }

        public static func read(
            _ method: String, noCLI reason: String, mcp: MCPExposure = .none
        ) -> RPCEntry {
            RPCEntry(method: method, isWrite: false, coverage: .noCLI(reason: reason), mcp: mcp)
        }

        public static func write(_ method: String, cli path: String) -> RPCEntry {
            RPCEntry(method: method, isWrite: true, coverage: .cli(path))
        }

        public static func write(_ method: String, noCLI reason: String) -> RPCEntry {
            RPCEntry(method: method, isWrite: true, coverage: .noCLI(reason: reason))
        }
    }

    /// Methods `RPCWebSocketHandler.localOnlyDenial` refuses outright for a non-local
    /// `/rpc` peer — the unconditional cases only.
    ///
    /// Hoisted here so the export gate can assert `MCP ∩ local-only = ∅` from
    /// `CrowCore`, which runs in the Linux PR lane; `CrowDaemon` (where the real
    /// gate lives) is Darwin-only and its tests do not run on PRs. This is the same
    /// split ADR 0016 already makes for the RPC ledger itself: the authoritative
    /// check lives beside the truth, and a mirror runs where CI can see it.
    ///
    /// `LocalOnlyRPCGateTests` pins this set against `localOnlyDenial` in both
    /// directions, so the mirror cannot drift from the boundary it mirrors.
    /// `set-config` and `defaults-set` are deliberately absent: they are denied
    /// *conditionally*, on payload inspection, and neither is MCP-exported.
    public static let localOnlyRPCMethods: Set<String> = [
        "run-setup",
        "hook-event",
        "open-in-vscode",
        "open-terminal",
        "gateway-get",
        "gateway-set",
        "web-password-get",
        "web-password-set",
        "mcp-token-list",
        "mcp-token-mint",
        "mcp-token-revoke",
        "corveil-verify",
        "corveil-reinstall-skill",
        "logsync-get",
        "logsync-set",
    ]

    /// Every method reachable through the live router pair — the daemon's
    /// `makeCommandRouter` unioned with the `makeEngineRouter` it falls back to.
    public static let rpcMethods: [RPCEntry] = [
        // Sessions
        .write("new-session", cli: "new-session"),
        .write("rename-session", cli: "rename-session"),
        .write("select-session", cli: "select-session"),
        .read("list-sessions", cli: "list-sessions", mcp: .read(scope: .sessionsRead)),
        .read("get-session", cli: "get-session", mcp: .read(scope: .sessionsRead)),
        .write("set-status", cli: "set-status"),
        .write("set-locked", cli: "set-locked"),
        .write("delete-session", cli: "delete-session"),
        .write("handoff-agent", cli: "handoff-agent"),
        .read(
            "list-sessions-live",
            noCLI: """
                Web-board streaming read: the same rows as `list-sessions` plus live \
                terminal/agent state, shaped for the browser's poll loop. `crow \
                list-sessions` and `crow get-session` cover the CLI's needs.
                """,
            // MCP-exported despite having no CLI verb: the two axes are independent.
            // `list_stuck_sessions` needs the auto-merge / auto-rebase / PR-check
            // state that rides only here, joined against `list-sessions` (CROW-1004).
            mcp: .read(scope: .sessionsRead)),
        .write(
            "set-pinned",
            noCLI: """
                Engine method with no caller: `crow set-pinned` in fact sends the \
                `set-locked` RPC (SessionCommands.swift). Either the verb is \
                misrouted or this method is dead — resolve before removing this row.
                """),

        // Session lifecycle
        .write("mark-in-review", cli: "mark-in-review"),
        .write("complete-session", cli: "complete-session"),
        .write("set-session-active", cli: "set-session-active"),
        .write("mark-issue-done", cli: "mark-issue-done"),
        .write("add-merge-label", cli: "add-merge-label"),

        // Metadata & links
        .write("set-ticket", cli: "set-ticket"),
        .write("set-goal", cli: "set-goal"),
        .write("add-link", cli: "add-link"),
        .read("list-links", cli: "list-links"),
        .write("remove-link", cli: "remove-link"),
        .write("edit-link", cli: "edit-link"),
        .write("transition-ticket", cli: "transition-ticket"),
        .write("resync-jira", cli: "resync-jira"),

        // Worktrees
        .write("add-worktree", cli: "add-worktree"),
        .read("list-worktrees", cli: "list-worktrees"),

        // Terminals
        .write("new-terminal", cli: "new-terminal"),
        .read("list-terminals", cli: "list-terminals"),
        .write("close-terminal", cli: "close-terminal"),
        .write("recreate-terminal", cli: "recreate-terminal"),
        .write("rename-terminal", cli: "rename-terminal"),
        .write("send", cli: "send"),

        // Maintenance
        .write("launch-agent", cli: "launch-agent"),
        .write("retry-readiness", cli: "retry-readiness"),
        .write("restart-manager", cli: "restart-manager"),
        .write("restart-tmux-server", cli: "restart-tmux-server"),
        .write("reload-tmux-config", cli: "reload-tmux-config"),
        .write("open-in-vscode", cli: "open-in-vscode"),
        .write("open-terminal", cli: "open-terminal"),

        // Board & workflow
        .read("list-tickets", cli: "list-tickets", mcp: .read(scope: .boardRead)),
        .read("list-reviews", cli: "list-reviews", mcp: .read(scope: .boardRead)),
        .write("refresh-tickets", cli: "refresh-tickets"),
        .write("work-on-issue", cli: "work-on-issue"),
        .write("batch-work-on-issues", cli: "batch-work-on-issues"),
        .write("start-review", cli: "start-review"),
        .write("create-manager", cli: "create-manager"),
        .write("quick-action", cli: "quick-action"),
        .read(
            "get-pr-status",
            noCLI: """
                Per-row PR badge fetch for the web Reviews board, called once per \
                visible card. `crow list-reviews` already returns the same PR state \
                for every review in one payload, which is the shape a script wants.
                """),
        .read(
            "list-agents",
            noCLI: """
                Populates the agent picker in the web session-create sheet. `crow \
                agents list` covers the CLI's need to enumerate agents via \
                `agents-get`, whose `known` array is a superset of this payload \
                (CROW-811) — this method is the older, picker-shaped read.
                """),
        .write(
            "batch-start-review",
            noCLI: """
                Backs the Reviews board's multi-select "Start Review (N)" button \
                (#869). The CLI equivalent is looping `crow start-review --url`, \
                which reports per-URL failures instead of one batch result.
                """),

        // Allowlist
        .read("list-allowlist", cli: "list-allowlist"),
        .write("promote-allowlist", cli: "promote-allowlist"),
        .write("refresh-allowlist", cli: "refresh-allowlist"),

        // Analytics
        .read("get-scorecard", cli: "get-scorecard"),
        .write("rebuild-scorecard", cli: "rebuild-scorecard"),
        .read("get-state", cli: "get-state"),
        .read("list-artifacts", cli: "list-artifacts"),
        .read(
            "get-session-terminal-preview",
            noCLI: """
                Web session-switcher preview: best-effort tmux pane tail for the \
                highlighted card (CROW-976). No CLI verb — the switcher is \
                browser-only and fetches on demand.
                """),

        // Settings
        // `defaults-get` is deliberately un-gated on `/rpc`; `defaults-set` is
        // local-only when the request carries `binaries` (CROW-810).
        .read("defaults-get", cli: "defaults get"),
        .write("defaults-set", cli: "defaults set"),
        .read("agents-get", cli: "agents list"),
        .write("agents-set", cli: "agents set"),
        // CROW-812. Ledgered here rather than in #884 because that PR and the
        // gate itself (#883) landed concurrently, so neither saw the other —
        // `main` fails this check without these two rows.
        .read("automation-get", cli: "automation get"),
        .write("automation-set", cli: "automation set"),
        // CROW-809. Un-gated on `/rpc`: the payloads carry no credential, since
        // the per-workspace gateway is excluded from them rather than gated.
        .read("workspace-list", cli: "workspace list"),
        .read("workspace-get", cli: "workspace get"),
        .write("workspace-add", cli: "workspace add"),
        .write("workspace-edit", cli: "workspace edit"),
        .write("workspace-remove", cli: "workspace remove"),
        .read("telemetry-get", cli: "telemetry get"),
        .write("telemetry-set", cli: "telemetry set"),
        .read("cleanup-get", cli: "cleanup get"),
        .write("cleanup-set", cli: "cleanup set"),
        .read("logsync-get", cli: "logsync get"),
        .write("logsync-set", cli: "logsync set"),
        .read("ui-get", cli: "ui get"),
        .write("ui-set", cli: "ui set"),
        .read("version-update-get", cli: "version get"),
        .write("version-update-set", cli: "version set"),
        .write("version-update-check", cli: "version check"),
        .read("notifications-get", cli: "notifications get"),
        .write("notifications-set", cli: "notifications set"),
        .read(
            "get-config",
            noCLI: """
                Ships the whole AppConfig as one opaque JSON blob to the web Settings \
                modal. The CLI reads config per area instead (`telemetry get`, \
                `cleanup get`, `ui get`, `notifications get`, `gateway get`), which is \
                what `configFields` below tracks field by field.
                """),
        .write(
            "set-config",
            noCLI: """
                Whole-config write behind the web Settings modal — it replaces every \
                field at once, so exposing it as a verb would hand scripts a \
                read-modify-write race against the daemon. The CLI writes per area; \
                `configFields` below is the ledger of which fields still lack a verb.
                """),
        .write(
            "run-setup",
            noCLI: """
                Runs the workspace `setup.sh` on the daemon host with the caller's \
                environment; local-only on `/rpc` for that reason \
                (RPCWebSocketHandler.localOnlyDenial). `crow setup` is the CLI path \
                and runs the wizard in-process rather than over the socket.
                """),

        // Secrets — local-socket only (CROW-815); see RPCWebSocketHandler.localOnlyDenial.
        .read("gateway-get", cli: "gateway get"),
        // `gateway clear` and `web-password clear` reuse the same write RPC with a
        // clearing payload, so only the `set` verb is named here.
        .write("gateway-set", cli: "gateway set"),
        .read("web-password-get", cli: "web-password status"),
        .write("web-password-set", cli: "web-password set"),

        // MCP bearer tokens — local-socket only (CROW-1004), for the same reason as
        // the two blocks above: `mcp-token-mint` returns the plaintext token exactly
        // once, and a remote peer that could mint one would be issuing itself the
        // credential that gates remote access. `mcp-token-list` is gated alongside
        // them even though it returns no secret, matching `web-password-get`.
        //
        // These methods are NOT MCP-exported. They are writes plus a secret read,
        // and the MCP surface is read-only — `MCPLedgerExportTests` enforces both.
        .read("mcp-token-list", cli: "mcp token list"),
        .write("mcp-token-mint", cli: "mcp token mint"),
        .write("mcp-token-revoke", cli: "mcp token revoke"),

        // Corveil CLI (CROW-1011). Local-only, because both execute
        // `defaults.binaries["corveil"]` on the daemon host.
        //
        // Both are `.write` despite neither touching config: `isWrite` means
        // "performs an action", and spawning a process on the host is the most
        // action a row here describes. Reading them as `.read` would make them
        // candidates for MCP export, which is exactly wrong.
        .write("corveil-verify", cli: "corveil verify"),
        .write("corveil-reinstall-skill", cli: "corveil reinstall-skill"),

        // Jobs
        .read("job-list", cli: "job list"),
        .read("job-get", cli: "job get"),
        .write("job-add", cli: "job add"),
        .write("job-edit", cli: "job edit"),
        .write("job-enable", cli: "job enable"),
        .write("job-disable", cli: "job disable"),
        .write("job-delete", cli: "job delete"),
        .write("job-duplicate", cli: "job duplicate"),
        .write("job-run", cli: "job run"),
        .write(
            "run-job",
            noCLI: """
                Internal scheduler entry point: fires a job on the daemon's own \
                timer path, bypassing the enabled/schedule checks a user-initiated \
                run must honour. `crow job run` is the user-facing verb.
                """),

        // Agent hooks — emitted by agent hook processes over the 0600 Unix
        // socket only; local-only on `/rpc` (RPCWebSocketHandler.localOnlyDenial,
        // #903) so a remote peer can't forge session state or poison the
        // unresolved-drop log's dedup cap.
        .write("hook-event", cli: "hook-event"),
    ]

    // MARK: - Config fields

    /// One leaf field of ``AppConfig``, addressed by dotted path. Collection and
    /// dictionary elements are addressed with a `[]` segment — e.g.
    /// `workspaces[].jiraJQL`, `notifications.eventSettings[].soundName`.
    public struct ConfigEntry: Sendable, Equatable {
        public let path: String
        /// How a user reads this field back without opening the web UI.
        public let read: Coverage
        /// How a user changes it.
        public let write: Coverage

        public static func field(_ path: String, read: String, write: String) -> ConfigEntry {
            ConfigEntry(path: path, read: .cli(read), write: .cli(write))
        }

        /// Neither readable nor writable from the CLI — one reason covers both.
        public static func field(_ path: String, noCLI reason: String) -> ConfigEntry {
            ConfigEntry(path: path, read: .noCLI(reason: reason), write: .noCLI(reason: reason))
        }

        public static func field(_ path: String, read: String, writeNoCLI: String) -> ConfigEntry {
            ConfigEntry(path: path, read: .cli(read), write: .noCLI(reason: writeNoCLI))
        }

        public static func field(_ path: String, readNoCLI: String, write: String) -> ConfigEntry {
            ConfigEntry(path: path, read: .noCLI(reason: readNoCLI), write: .cli(write))
        }
    }

    /// Every leaf field of ``AppConfig``, as produced by the `Mirror` walk in
    /// `ParityGateTests`. The two sets must match exactly, so a new config field
    /// fails the build until someone decides whether it gets a verb.
    ///
    /// The rows below are the honest state of the milestone. The settings blocks
    /// that already have verbs are covered: `telemetry`, `cleanup`, `sidebar`,
    /// `notifications`, gateways and jobs, `defaults` since CROW-810, agent
    /// selection since CROW-811, `workspaces[].*` since CROW-809 and the
    /// automation toggles since CROW-812. What the web Settings tab still owns
    /// exclusively is `terminal.*` and `jiraCredential.*`; the `webAuth` hash and
    /// salt are writable but readable nowhere.
    ///
    /// Coverage is per-direction, so a covered block can still hold a read-only
    /// row — the server-assigned `jobs[].id`/`createdAt`/`lastRunAt`,
    /// `workspaces[].id`/`cli`, `defaults.excludeDirs` and
    /// `defaults.mirrorClaudeMCPToCodex` all carry a write exemption. Read the
    /// row, not the `MARK` above it.
    public static let configFields: [ConfigEntry] = [
        // MARK: Covered — settings blocks with dedicated verbs

        .field("telemetry.enabled", read: "telemetry get", write: "telemetry set"),
        .field("telemetry.port", read: "telemetry get", write: "telemetry set"),
        .field("telemetry.retentionDays", read: "telemetry get", write: "telemetry set"),

        .field("cleanup.enabled", read: "cleanup get", write: "cleanup set"),
        .field("cleanup.retentionHours", read: "cleanup get", write: "cleanup set"),

        .field("versionUpdate.enabled", read: "version get", write: "version set"),
        .field("versionUpdate.intervalHours", read: "version get", write: "version set"),

        .field("sidebar.hideSessionDetails", read: "ui get", write: "ui set"),

        .field("switcher.enabled", read: "ui get", write: "ui set"),
        .field("switcher.binding", read: "ui get", write: "ui set"),
        .field("switcher.captureInTerminal", read: "ui get", write: "ui set"),
        .field("switcher.order", read: "ui get", write: "ui set"),
        .field("switcher.preview", read: "ui get", write: "ui set"),
        .field("switcher.include.managers", read: "ui get", write: "ui set"),
        .field("switcher.include.jobs", read: "ui get", write: "ui set"),
        .field("switcher.include.reviews", read: "ui get", write: "ui set"),
        .field("switcher.include.active", read: "ui get", write: "ui set"),
        .field("switcher.include.paused", read: "ui get", write: "ui set"),
        .field("switcher.include.inReview", read: "ui get", write: "ui set"),
        .field("switcher.include.completed", read: "ui get", write: "ui set"),
        .field("switcher.include.archived", read: "ui get", write: "ui set"),

        .field("notifications.globalMute", read: "notifications get", write: "notifications set"),
        .field("notifications.soundEnabled", read: "notifications get", write: "notifications set"),
        .field(
            "notifications.systemNotificationsEnabled",
            read: "notifications get", write: "notifications set"),
        .field(
            "notifications.eventSettings[].enabled",
            read: "notifications get", write: "notifications set"),
        .field(
            "notifications.eventSettings[].soundEnabled",
            read: "notifications get", write: "notifications set"),
        .field(
            "notifications.eventSettings[].systemNotificationEnabled",
            read: "notifications get", write: "notifications set"),
        .field(
            "notifications.eventSettings[].soundName",
            read: "notifications get", write: "notifications set"),

        // Gateways and the web password are local-socket only (CROW-815).
        .field("managerGateway.baseURL", read: "gateway get", write: "gateway set"),
        .field("managerGateway.customHeaders", read: "gateway get", write: "gateway set"),
        .field("workspaces[].gateway.baseURL", read: "gateway get", write: "gateway set"),
        .field("workspaces[].gateway.customHeaders", read: "gateway get", write: "gateway set"),

        // Session-log collector (CROW-1056). Local-socket only, like the gateway
        // block: `logsync get`/`logsync set` are refused on the remote /rpc path.
        .field("logSync.enabled", read: "logsync get", write: "logsync set"),
        .field("logSync.baseURL", read: "logsync get", write: "logsync set"),
        .field("logSync.apiKeyRef", read: "logsync get", write: "logsync set"),
        .field("logSync.enabledWorkspaces", read: "logsync get", write: "logsync set"),
        .field("logSync.retentionDays", read: "logsync get", write: "logsync set"),
        .field("logSync.quietPeriodMinutes", read: "logsync get", write: "logsync set"),
        .field("logSync.maxUploadBytes", read: "logsync get", write: "logsync set"),

        .field("webAuth.iterations", read: "web-password status", write: "web-password set"),
        .field(
            "webAuth.hashB64",
            readNoCLI: """
                The PBKDF2 hash is never read back by anything — not the CLI, not the \
                web UI. `crow web-password status` reports only that a password is \
                set. Exposing it would defeat storing a hash rather than the password.
                """,
            write: "web-password set"),
        .field(
            "webAuth.saltB64",
            readNoCLI: """
                Salt for the password hash above; never read back by any surface, for \
                the same reason. Written as a unit with the hash by `web-password set`.
                """,
            write: "web-password set"),

        // MARK: Covered — MCP bearer tokens (CROW-1004)

        // Local-socket only, like the two blocks above. Every field is minted
        // server-side by `mcp token mint`; the only other write is deletion via
        // `mcp token revoke`, so each row's write verb is the mint.
        .field("mcpTokens[].name", read: "mcp token list", write: "mcp token mint"),
        .field("mcpTokens[].scopes", read: "mcp token list", write: "mcp token mint"),
        .field("mcpTokens[].expiresAt", read: "mcp token list", write: "mcp token mint"),
        .field(
            "mcpTokens[].id",
            read: "mcp token list",
            writeNoCLI: """
                Server-assigned UUID, minted by `mcp token mint` and thereafter the \
                handle `mcp token revoke --id` takes. Not user-settable by design.
                """),
        .field(
            "mcpTokens[].prefix",
            read: "mcp token list",
            writeNoCLI: """
                The first 8 characters of the minted token, stored so a human can \
                tell two tokens apart in a listing. Derived from the secret at mint \
                time; setting it independently would make the listing lie.
                """),
        .field(
            "mcpTokens[].createdAt",
            read: "mcp token list",
            writeNoCLI: """
                Server-assigned mint timestamp. Not user-settable — a token that \
                could claim to be older than it is would defeat any audit of when \
                access was granted.
                """),
        .field(
            "mcpTokens[].hashB64",
            readNoCLI: """
                The SHA-256 of the token is never read back by anything — not the \
                CLI, not the web UI. `mcp token list` reports the name, prefix, \
                scopes and expiry only. Exposing it would defeat storing a hash \
                rather than the token.
                """,
            write: "mcp token mint"),

        // MARK: Covered — jobs

        .field("jobs[].name", read: "job get", write: "job add"),
        .field("jobs[].workspace", read: "job get", write: "job add"),
        .field("jobs[].repo", read: "job get", write: "job add"),
        .field("jobs[].prompts", read: "job get", write: "job add"),
        .field("jobs[].schedule", read: "job get", write: "job add"),
        .field("jobs[].enabled", read: "job get", write: "job enable"),
        .field(
            "jobs[].id",
            read: "job get",
            writeNoCLI: """
                Server-assigned UUID, minted by `job add` and thereafter the handle \
                every other job verb takes. Not user-settable by design.
                """),
        .field(
            "jobs[].createdAt",
            read: "job get",
            writeNoCLI: """
                Stamped by the daemon when `job add` succeeds. Runtime provenance, \
                not a setting — there is nothing for a user to write here.
                """),
        .field(
            "jobs[].lastRunAt",
            read: "job get",
            writeNoCLI: """
                Scheduler bookkeeping, written when a job fires so a daemon restart \
                does not replay it. Not a setting; `job run` is how a user forces one.
                """),

        // MARK: Covered — global defaults (CROW-810)

        .field("defaults.provider", read: "defaults get", write: "defaults set"),
        .field("defaults.cli", read: "defaults get", write: "defaults set"),
        .field("defaults.branchPrefix", read: "defaults get", write: "defaults set"),
        .field("defaults.excludeReviewRepos", read: "defaults get", write: "defaults set"),
        .field("defaults.excludeTicketRepos", read: "defaults get", write: "defaults set"),
        .field("defaults.ignoreReviewLabels", read: "defaults get", write: "defaults set"),
        .field("defaults.binaries", read: "defaults get", write: "defaults set"),
        .field(
            "defaults.excludeDirs",
            read: "defaults get",
            writeNoCLI: """
                Returned by `defaults get` but `defaults set` has no flag for it \
                (CROW-810 shipped seven of the nine fields writable). Directory-scan \
                exclusions for repo discovery; web Settings tab is still the only \
                way to change them.
                """),
        .field(
            "defaults.mirrorClaudeMCPToCodex",
            read: "defaults get",
            writeNoCLI: """
                Returned by `defaults get` but `defaults set` has no flag for it \
                (CROW-810 shipped seven of the nine fields writable). Whether Codex \
                sessions inherit Claude's MCP servers; web Settings tab only.
                """),

        // MARK: Covered — agent selection (CROW-811)

        .field("defaultAgentKind", read: "agents list", write: "agents set"),
        .field("agentsByKind", read: "agents list", write: "agents set"),

        // MARK: Workspaces — `crow workspace` (CROW-809)
        //
        // Every field below was exempt as "no CLI surface whatsoever" until these
        // verbs existed. `workspace get`/`list` read the block; `workspace add`
        // and `edit` write it. `cli` is the one exception: it is derived from
        // `provider` on every write rather than being separately settable.
        //
        // The per-workspace `gateway` is NOT here — it lives with the credential
        // rows above, is excluded from every `workspace-*` payload, and is
        // authored only by the local-only `gateway set`.

        .field("workspaces[].id", read: "workspace get", writeNoCLI: """
            Workspace identity, minted on `workspace add` and never rewritten: \
            `SettingsSecrets.preservingSecrets` matches stored gateways by it, so \
            an editable id would silently orphan a workspace's credential.
            """),
        .field("workspaces[].name", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].provider", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].cli", read: "workspace get", writeNoCLI: """
            Derived from `provider` (`gh`/`glab`) on every write and kept only for \
            config-file compatibility, so there is no flag to set it directly. \
            `WorkspaceRPC.applyPatch` re-derives it, which also repairs a stale \
            value written by an older build.
            """),
        .field("workspaces[].host", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].alwaysInclude", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].autoReviewRepos", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].excludeReviewRepos", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].customInstructions", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].reviewBlockingSeverities", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].taskProvider", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].jiraProjectKey", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].jiraJQL", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].jiraSite", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].jiraStatusMap", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].corveilHost", read: "workspace get", write: "workspace edit"),
        .field("workspaces[].sessionEnv", read: "workspace get", write: "workspace edit"),
        // Per-workspace session-log opt-in (CROW-1066). Unlike the `logSync` block
        // above, this rides on the workspace record and is intentionally writable
        // from the same surfaces as every other workspace field — `workspace edit`
        // over the socket, `set-config` from an authenticated browser — because it
        // only reuses a credential the workspace already holds and `logSync.enabled`
        // stays the local-only kill switch.
        .field("workspaces[].uploadSessionLogs", read: "workspace get", write: "workspace edit"),

        // MARK: Automation toggles (web Settings tab + `crow automation`)

        // Covered since CROW-812 (#884): `crow automation get` reads all twelve
        // and `crow automation set` patches them. Neither method is on
        // `RPCWebSocketHandler.localOnlyDenial`, so an authenticated remote
        // `/rpc` peer can write these fields too — deliberately, because that
        // same peer already reaches every one of them through the whole-blob
        // `set-config`, and the granular verb is the smaller surface
        // (`DaemonSecurityTests.settingsRPCsAreAllowedRemotely` pins it).
        // `remoteControlEnabled` is no exception to that: it decides whether
        // coding-agent sessions launch with `--rc` (claude.ai / mobile control),
        // not who may reach `crowd`.
        .field("remoteControlEnabled", read: "automation get", write: "automation set"),
        .field("managerAutoPermissionMode", read: "automation get", write: "automation set"),
        .field("jobsAutoPermissionMode", read: "automation get", write: "automation set"),
        .field("reviewAutoPermissionMode", read: "automation get", write: "automation set"),
        .field("coderViewAutoPermissionMode", read: "automation get", write: "automation set"),
        .field("attributionTrailers", read: "automation get", write: "automation set"),
        .field("autoMergeWatcherEnabled", read: "automation get", write: "automation set"),
        .field("autoCreateWatcherEnabled", read: "automation get", write: "automation set"),
        .field("autoRespond.respondToChangesRequested", read: "automation get", write: "automation set"),
        .field("autoRespond.respondToFailedChecks", read: "automation get", write: "automation set"),
        .field("autoRespond.autoRebaseAndResolveConflicts", read: "automation get", write: "automation set"),
        .field("autoRespond.autoReRequestReview", read: "automation get", write: "automation set"),

        // MARK: Exempt — terminal tuning and Jira credential

        .field(
            "terminal.wheelScrollLines",
            noCLI: """
                Scrollback lines per wheel notch on plain-shell surfaces (CROW-835, \
                ADR 0013). Web Settings only — the `ui` verb covers the sidebar block, \
                not this one.
                """),
        .field(
            "terminal.agentWheelNotches",
            noCLI: """
                Wheel notches forwarded per physical notch on agent surfaces \
                (CROW-835, ADR 0013). Web Settings only — see \
                `terminal.wheelScrollLines`.
                """),
        .field(
            "jiraCredential.username",
            noCLI: """
                Jira REST account for the in-app status fetch (CROW-528). Carries a \
                credential, so any verb must be local-socket only like `crow gateway`; \
                today it is written in the web Settings tab only.
                """),
        .field(
            "jiraCredential.tokenRef",
            noCLI: """
                `op://` reference to the Jira API token — resolved on demand so the \
                secret never lands in config.json. Same local-only constraint as \
                `jiraCredential.username`; no verb exists yet.
                """),
    ]
}
