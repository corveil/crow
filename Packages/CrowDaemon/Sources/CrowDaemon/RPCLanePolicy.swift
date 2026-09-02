import CrowCore
import CrowIPC

/// Which `/rpc` requests must not overtake each other (#931).
///
/// Stated per method, never inferred. A rule derived from "does it carry a
/// `session_id`" would silently hand full concurrency to the next write that
/// happens to key on something else — `launch-agent` keys on `terminal_id` and
/// `job-run` on `job_id`, and both were already in the surface when this was
/// written. ``RPCLanePolicyTests`` gates the table against
/// `ParityLedger.rpcMethods`, so a new write method fails the build until
/// somebody decides its lane.
///
/// Reads are absent by design: they take no lane. Lanes order *writes to a
/// resource*; putting `get-pr-status` behind a `delete-session` on the same
/// session would trade the bug for a smaller one.
enum RPCLanePolicy {

    /// How a method's lane is derived.
    enum Rule: Sendable, Equatable {
        /// Serialize on this parameter's value. A request that omits it gets no
        /// lane — the handler rejects it as `invalidParams` anyway, and an
        /// "absent" bucket would serialize every malformed request against
        /// every other one.
        case on(String)
        /// Serialize on a fixed resource lane.
        case fixed(RPCDispatcher.Lane)
        /// No ordering constraint. Stated explicitly rather than by omission so
        /// the ledger gate can tell "decided" from "forgotten".
        case concurrent
    }

    static let rules: [String: Rule] = [
        // MARK: Sessions
        // A brand-new id has nothing to order against, and the append is one
        // synchronous MainActor block.
        "new-session": .concurrent,
        "rename-session": .on("session_id"),
        "select-session": .on("session_id"),
        "set-status": .on("session_id"),
        "set-locked": .on("session_id"),
        "set-pinned": .on("session_id"),
        "delete-session": .on("session_id"),
        "handoff-agent": .on("session_id"),

        // MARK: Lifecycle
        // `mark-issue-done` is the one that makes this mandatory: it awaits a
        // provider CLI call and *then* writes the session's status in a second
        // MainActor hop. Unlaned, a `complete-session` could land in that gap.
        "mark-in-review": .on("session_id"),
        "complete-session": .on("session_id"),
        "set-session-active": .on("session_id"),
        "mark-issue-done": .on("session_id"),
        "add-merge-label": .on("session_id"),

        // MARK: Metadata & links
        "set-ticket": .on("session_id"),
        "set-goal": .on("session_id"),
        "add-link": .on("session_id"),
        "remove-link": .on("session_id"),
        "edit-link": .on("session_id"),
        "transition-ticket": .on("session_id"),
        // Walks every session and transitions its ticket; two at once would
        // double every provider call.
        "resync-jira": .fixed(.tracker),

        // MARK: Worktrees
        "add-worktree": .on("session_id"),

        // MARK: Terminals
        // Keyed on the session, not the terminal: these mutate the session's
        // terminal *list*. `send` in particular must never reorder — two lines
        // typed at one agent in the wrong order is a corrupt prompt.
        "new-terminal": .on("session_id"),
        "close-terminal": .on("session_id"),
        "recreate-terminal": .on("session_id"),
        "rename-terminal": .on("session_id"),
        "send": .on("session_id"),
        // These two carry only a `terminal_id`.
        "launch-agent": .on("terminal_id"),
        "retry-readiness": .on("terminal_id"),

        // MARK: Manager window + the tmux server it lives in
        // `work-on-issue` types into the Manager terminal; the restart verbs
        // create or destroy it. Typing into a Manager being restarted is a lost
        // prompt.
        "create-manager": .fixed(.manager),
        "restart-manager": .fixed(.manager),
        "restart-tmux-server": .fixed(.manager),
        "reload-tmux-config": .fixed(.manager),
        "work-on-issue": .fixed(.manager),
        "batch-work-on-issues": .fixed(.manager),

        // MARK: Host apps
        "open-in-vscode": .on("session_id"),
        "open-terminal": .on("session_id"),

        // MARK: Boards
        // `IssueTracker.refresh()` self-guards with `isRefreshing` and returns
        // early, which is the behaviour the web's manual-refresh path is written
        // against. Laning it would convert that early return into a wait and
        // make a timeout more likely, not less.
        "refresh-tickets": .concurrent,
        "start-review": .fixed(.reviewKickoff),
        "batch-start-review": .fixed(.reviewKickoff),
        "quick-action": .on("session_id"),
        // `ScorecardRebuilder` is already single-flight: a second caller awaits
        // the in-flight run instead of starting one.
        "rebuild-scorecard": .concurrent,

        // MARK: config.json
        "set-config": .fixed(.config),
        "run-setup": .fixed(.config),
        "defaults-set": .fixed(.config),
        "agents-set": .fixed(.config),
        "automation-set": .fixed(.config),
        "telemetry-set": .fixed(.config),
        "cleanup-set": .fixed(.config),
        "ui-set": .fixed(.config),
        "terminal-set": .fixed(.config),
        "notifications-set": .fixed(.config),
        "notifications-add-sound": .fixed(.config),
        "notifications-remove-sound": .fixed(.config),
        "workspace-add": .fixed(.config),
        "workspace-edit": .fixed(.config),
        "workspace-remove": .fixed(.config),
        "gateway-set": .fixed(.config),
        "web-password-set": .fixed(.config),
        "logsync-set": .fixed(.config),
        // MCP tokens live in config.json, so they share its lane — two concurrent
        // mints would otherwise read the same token array and one would lose its
        // append (CROW-1004).
        "mcp-token-mint": .fixed(.config),
        "mcp-token-revoke": .fixed(.config),
        // Corveil connection writes (CROW-1120) — they write config.json, so they
        // share its lane. The two reads (`corveil-status`/`corveil-orgs`) take no
        // lane, like every other read.
        "corveil-connect": .fixed(.config),
        "corveil-disconnect": .fixed(.config),
        // Org provisioning (CROW-1121) mints/revokes a per-org key over the
        // network before its small config write, so it must NOT sit on `.config`
        // (a slow round-trip would park every Settings save). Keyed on the org so
        // two selects for one org can't double-mint, while different orgs and
        // config writes proceed in parallel; the config write itself is still
        // serialized by `ConfigStore.withConfigLock`. `corveil-list-orgs` is a
        // read and takes no lane.
        "corveil-select-org": .on("org_id"),
        "corveil-deselect-org": .on("org_id"),
        // Gateway migration (CROW-1126). `corveil-link-gateway` adopts an existing
        // key into the connection — a small, offline config write (no network), so
        // it shares the config lane. `corveil-detect-gateways` is a read and takes
        // no lane.
        "corveil-link-gateway": .fixed(.config),
        "job-add": .fixed(.config),
        "job-edit": .fixed(.config),
        "job-enable": .fixed(.config),
        "job-disable": .fixed(.config),
        "job-delete": .fixed(.config),
        "job-duplicate": .fixed(.config),
        "version-update-set": .fixed(.config),
        // Long, user-initiated upload run — its own lane so it serializes against
        // itself (never two concurrent backfills) without blocking config writes
        // (CROW-1075).
        "backfill-upload": .fixed(.backfill),
        // Already single-flight: a second caller awaits the in-flight compare
        // instead of spawning another `gh auth token` subprocess + GitHub call.
        "version-update-check": .concurrent,

        // MARK: Corveil CLI binary (CROW-1011)
        // Both run `defaults.binaries["corveil"]` in a detached subprocess and
        // write nothing to config.json. `verify` orders nothing; `reinstall-skill`
        // writes the embedded skill files idempotently (same content each run) and
        // updates a MainActor warning, so two at once cannot corrupt state. Stated
        // concurrent rather than omitted, so the ledger gate can tell "decided"
        // from "forgotten" — these predate the gate and were the latter until
        // CROW-1120.
        "corveil-verify": .concurrent,
        "corveil-reinstall-skill": .concurrent,

        // MARK: Job runs
        // Not `.config`: these await a full worktree + tmux spawn, and parking
        // every settings write behind that would be a worse stall than the one
        // this change removes. Keyed on the job so one job cannot double-spawn.
        "job-run": .on("job_id"),
        "run-job": .on("job_id"),

        // MARK: Hooks
        // Never reaches `/rpc` — `RPCWebSocketHandler.localOnlyDenial` denies it
        // — but declared so the ledger gate stays complete rather than carrying
        // an exemption.
        "hook-event": .on("session_id"),
    ]

    /// The lane for `request`, or `nil` when it may run concurrently with
    /// everything else on the connection.
    static func lane(for request: JSONRPCRequest) -> RPCDispatcher.Lane? {
        switch rules[request.method] ?? .concurrent {
        case .concurrent:
            return nil
        case .fixed(let lane):
            return lane
        case .on(let param):
            guard let value = request.params?[param]?.stringValue, !value.isEmpty else {
                return nil
            }
            return .param(name: param, value: value)
        }
    }
}
