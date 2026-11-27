import ArgumentParser
import CrowCore
import CrowIPC
import Foundation

// `crow attribution` (CROW-1533): print the finished Crow footer line for a
// review or an authored artifact, naming the model as well as the harness.
//
// The agent name can be baked into a skill at scaffold time; the model can't.
// It isn't known yet when the skill is written, and it changes mid-session
// (`/model`, Codex config). So skills call this verb when they post, and it
// reads the session's transcript-derived `context.model` from `get-session`.
//
// Like `crow version`, this prints a plain line rather than JSON: the output is
// pasted verbatim into a review or issue body. It never fails because a model
// is missing. A daemon that can't be reached, an unknown session, a harness
// that reports no model, or a model that fails `CrowAttribution.sanitizedModel`
// all print the footer without a model, and exit 0. Only a bad `--kind` exits
// non-zero.

extension CrowAttribution.FooterKind: ExpressibleByArgument {}

public struct Attribution: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "attribution",
        abstract: "Print the Crow footer line for a review or an authored artifact",
        discussion: """
        Prints one line, for example:

          [🐦‍⬛ Reviewed by Crow via Claude Code · claude-opus-5-5](https://github.com/corveil/crow)

        --kind review prints the review footer; --kind created prints the footer \
        for issues, PR descriptions and other artifacts Crow wrote.

        The model is the session's context.model (see `crow get-session`), read \
        when you run this. Claude Code and Codex sessions report one; other \
        harnesses don't. --session defaults to $CROW_SESSION_ID.

        The model is left out when `crow automation set --attribution-model false` \
        is set, when --no-model is passed, when the session is unset or unknown, \
        when the harness reports no model, or when the model id is anything but \
        1-64 characters of A-Z, a-z, 0-9, '.', '_' and '-'. The footer is still \
        printed and the exit status is 0.

        Prints plain text, not JSON.
        """
    )

    @Option(name: .long, help: "Which footer to print: review or created")
    var kind: CrowAttribution.FooterKind

    @Option(name: .long, help: "Session UUID (default: $CROW_SESSION_ID)")
    var session: String?

    @Flag(name: .customLong("no-model"), help: "Leave the model out of this footer")
    var noModel = false

    public init() {}

    public func run() throws {
        print(Self.render(
            kind: kind,
            session: session,
            noModel: noModel,
            environment: ProcessInfo.processInfo.environment,
            call: { method, params in try rpc(method, params: params, timeoutSeconds: 10) }
        ))
    }

    /// Build the footer. `call` is the RPC transport, injected so tests run
    /// without a socket. Every failure path falls back to fewer parts, never to
    /// an error.
    ///
    /// Reads only `get-session`'s `agent_kind` and `context.model` and
    /// `automation-get`'s `attribution_model`. Gateway fields in the session
    /// payload, and gateway variables in `environment`, are never read.
    static func render(
        kind: CrowAttribution.FooterKind,
        session: String?,
        noModel: Bool,
        environment: [String: String],
        call: (String, [String: JSONValue]) throws -> [String: JSONValue]
    ) -> String {
        var agentName = CrowAttribution.agentDisplayName(fromEnvironment: environment)
        let sessionID = (session ?? environment["CROW_SESSION_ID"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A malformed id is treated like an unknown one: no lookup, no model.
        guard let sessionID, UUID(uuidString: sessionID) != nil,
              let info = try? call("get-session", ["session_id": .string(sessionID)])
        else {
            return CrowAttribution.footer(kind: kind, agentDisplayName: agentName)
        }

        // The session's own harness beats the caller's environment, so
        // `--session <other>` names the harness that session runs.
        if let raw = info["agent_kind"]?.stringValue, !raw.isEmpty {
            agentName = CrowAttribution.agentDisplayName(for: AgentKind(rawValue: raw))
        }

        guard !noModel,
              let model = CrowAttribution.sanitizedModel(
                  info["context"]?.objectValue?["model"]?.stringValue),
              modelEnabled(call: call)
        else {
            return CrowAttribution.footer(kind: kind, agentDisplayName: agentName)
        }
        return CrowAttribution.footer(kind: kind, agentDisplayName: agentName, model: model)
    }

    /// `attributionModel` from config. When it can't be read (the RPC fails,
    /// an older daemon omits the key, or config.json exists but won't decode),
    /// leave the model out: an operator who opted out must never see it come
    /// back because the setting couldn't be read.
    private static func modelEnabled(
        call: (String, [String: JSONValue]) throws -> [String: JSONValue]
    ) -> Bool {
        guard let automation = try? call("automation-get", [:])["automation"]?.objectValue,
              automation["config_readable"]?.boolValue != false,
              let enabled = automation["attribution_model"]?.boolValue
        else { return false }
        return enabled
    }
}
