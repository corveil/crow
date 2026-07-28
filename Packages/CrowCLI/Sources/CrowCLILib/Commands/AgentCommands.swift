import ArgumentParser
import CrowCore
import CrowIPC
import Foundation

/// Lets `--clear` parse straight into the model enum: ArgumentParser derives
/// `init?(argument:)` from the `String` raw value and — because `SessionKind` is
/// `CaseIterable` — `allValueStrings`, so the four roles appear in `--help` and in
/// the rejection message, and shell completion works, without the CLI keeping its
/// own copy of the role list.
extension SessionKind: @retroactive ExpressibleByArgument {}

/// Parent command for agent selection: `crow agents <subcommand>`.
///
/// Reads and writes `AppConfig.defaultAgentKind` + `AppConfig.agentsByKind` — the
/// same fields the web Settings → General "Agent" group edits — over the daemon's
/// RPC socket, so the change lands under the shared config lock and an open web
/// tab picks it up within a couple of seconds (CROW-811).
public struct Agents: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract: "Show and change which coding agent Crow launches",
        discussion: """
        Resolution is agentsByKind[<role>] falling back to defaultAgentKind. The \
        four roles are work (coding sessions), review (PR reviews), job \
        (scheduled jobs), and manager (the Manager session).

        Only agents whose CLI binary crowd found at startup can be selected — run \
        `crow agents list` for the set. Changes apply within about one board poll; \
        no restart.
        """,
        subcommands: [AgentsList.self, AgentsSet.self]
    )

    public init() {}
}

public struct AgentsList: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show known agents, the configured default, and the agent each role resolves to",
        discussion: """
        `known` lists every agent Crow ships, each flagged `available` — an agent \
        whose binary wasn't on PATH when crowd started is listed but not \
        selectable, so it reads as "not installed" rather than vanishing. \
        `default_agent_kind` and `by_kind` are what you configured; `effective` is \
        what a new session of each role would get.

        `config_readable` is false when config.json exists but could not be \
        decoded — the values shown are then defaults, not your settings.
        """
    )

    public init() {}

    public func run() throws {
        let result = try rpc("agents-get")
        printJSON(result)
        warnAboutStrandedRoles(result)
    }
}

public struct AgentsSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change the default agent or a per-role override",
        discussion: """
        Only the flags you pass change; at least one is required.

        --clear <role> removes that role's override so the role falls back to the \
        default; repeat the flag per role. Setting and clearing the same role in \
        one call is rejected.

        An agent kind that is not currently available is rejected and nothing is \
        written — run `crow agents list` for the set. Note availability is decided \
        when crowd starts, so a newly installed agent needs a daemon restart before \
        it can be selected.
        """
    )

    // `default` is a Swift keyword, so the property can't carry the flag name.
    @Option(name: .customLong("default"), help: "Agent for sessions with no per-role override")
    var defaultAgent: String?

    @Option(name: .long, help: "Agent for new coding sessions")
    var work: String?
    @Option(name: .long, help: "Agent for PR-review sessions")
    var review: String?
    @Option(name: .long, help: "Agent for scheduled-job sessions")
    var job: String?
    @Option(name: .long, help: "Agent for the Manager session")
    var manager: String?

    @Option(
        name: .long, parsing: .singleValue,
        help: "Role whose override to remove, falling back to the default (repeatable)")
    var clear: [SessionKind] = []

    public init() {}

    /// The four role flags as (role, kind) pairs, in `SessionKind` declaration
    /// order so messages and the emitted payload are stable.
    ///
    /// Kinds are trimmed here so a shell-quoting slip (`--work "codex "`) is
    /// treated as the kind the user meant rather than sent verbatim and bounced
    /// by the daemon as "'codex ' is not an available agent" — an error that
    /// points at availability when the real problem is a stray space. The
    /// trimmed value is what `validate()` blank-checks and what `run()` sends,
    /// so the two can't disagree.
    private var overrides: [(role: SessionKind, kind: String)] {
        [(SessionKind.work, work), (.review, review), (.job, job), (.manager, manager)]
            .compactMap { role, kind in
                kind.map { (role, $0.trimmingCharacters(in: .whitespaces)) }
            }
    }

    /// `--default`, trimmed on the same rationale as `overrides`.
    private var trimmedDefaultAgent: String? {
        defaultAgent?.trimmingCharacters(in: .whitespaces)
    }

    public func validate() throws {
        // Conflict first: `--review codex --clear review` satisfies the emptiness
        // check below, so checking that first would bury the real mistake behind a
        // message that never mentions --clear.
        let clearing = Set(clear)
        let conflicts = overrides.map(\.role).filter(clearing.contains).map(\.rawValue)
        guard conflicts.isEmpty else {
            throw ValidationError(
                "Cannot set and clear the same role: "
                    + conflicts.map { "--\($0) conflicts with --clear \($0)" }
                        .joined(separator: ", ") + ".")
        }
        guard defaultAgent != nil || !overrides.isEmpty || !clear.isEmpty else {
            throw ValidationError(
                "Nothing to set — provide --default, one of --work/--review/--job/--manager, or --clear <role>.")
        }
        // A blank kind would reach the daemon as "" and come back as "'' is not an
        // available agent", which points at the wrong thing. Deliberately NOT
        // validating the kind itself here: the valid set is whatever crowd
        // registered at boot (binary-dependent), and `AgentKind` is an open struct
        // with no closed case list to check against. The daemon's registry is the
        // single gate, same as `crow new-session --agent`.
        if let trimmedDefaultAgent, trimmedDefaultAgent.isEmpty {
            throw ValidationError("--default must not be blank.")
        }
        for (role, kind) in overrides where kind.isEmpty {
            throw ValidationError("--\(role.rawValue) must not be blank.")
        }
    }

    /// The `agents-set` payload these flags produce. Split out of `run()` so the
    /// wire shape — trimming, the role->kind map, clear dedup — is assertable
    /// without a socket.
    func sentParams() -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let trimmedDefaultAgent { params["default_agent_kind"] = .string(trimmedDefaultAgent) }
        if !overrides.isEmpty {
            var byKind: [String: JSONValue] = [:]
            for (role, kind) in overrides { byKind[role.rawValue] = .string(kind) }
            params["by_kind"] = .object(byKind)
        }
        if !clear.isEmpty {
            // Deduped and re-ordered to declaration order: `--clear work --clear
            // work` sends one entry. The server is idempotent either way, but a
            // duplicated echo in an error message reads like a bug.
            let unique = Set(clear)
            params["clear"] = .array(
                SessionKind.allCases.filter(unique.contains).map { .string($0.rawValue) })
        }
        return params
    }

    public func run() throws {
        let result = try rpc("agents-set", params: sentParams())
        printJSON(result)
        warnAboutStrandedRoles(result)
    }
}

/// Warn when a role resolves to an agent this daemon can't launch.
///
/// The resolution itself is honest — that kind is exactly what a new session of
/// that role would persist. But nothing will start it: `AgentRegistry.registeredKind`
/// gates only *requested* kinds, so a **configured** kind whose binary left PATH
/// (or that was set before a daemon restart dropped it) sails through and the
/// session lands unlaunchable. Goes to stderr so stdout stays pure JSON.
func warnAboutStrandedRoles(_ result: [String: JSONValue]) {
    guard let agents = result["agents"]?.objectValue,
        let known = agents["known"]?.arrayValue,
        let effective = agents["effective"]?.objectValue
    else { return }
    // Only the launchable rows: `known` now also carries agents the daemon knows
    // about but couldn't find on PATH (#879/#880), and resolving to one of those
    // is exactly the case worth warning about.
    let kinds = Set(
        known
            .filter { $0.objectValue?["available"]?.boolValue == true }
            .compactMap { $0.objectValue?["kind"]?.stringValue })
    // An empty registry means the daemon registered nothing at all (or is an older
    // build); warning on all four roles then is noise, not signal.
    guard !kinds.isEmpty else { return }
    for (role, value) in effective.sorted(by: { $0.key < $1.key }) {
        guard let kind = value.stringValue, !kinds.contains(kind) else { continue }
        warn(
            "\(role) resolves to '\(kind)', which is not available on this daemon — "
                + "sessions of that kind will not launch. Install its CLI and restart crowd, "
                + "or run: crow agents set --\(role) <kind>")
    }
}
