import CrowCore
import CrowIPC
import Foundation

/// Maps between Crow sessions and the agent conversations they ran
/// (CROW-1476): the `agent_conversations` array on `get-session` /
/// `list-sessions` rows, and the `find-session` lookup that goes the other
/// way, from a conversation id (a transcript's file name) to its session.
///
/// A conversation id is the harness's own id (a Claude Code session UUID, a
/// Codex thread id, a Cursor chat id, …), which is also what a gateway's
/// request log records from the request body. Both RPCs are readable by remote
/// `/rpc` peers. That is deliberate: the id is no credential. It names a
/// transcript file on this host and grants nothing without local access (a
/// `--resume` needs the file), and it is the same id the gateway already logs.
public enum AgentConversationRPC {
    /// Shortest prefix `find-session` accepts. Anything shorter matches nearly
    /// everything, or worse, exactly one conversation by luck.
    public static let minimumPrefixLength = 4

    /// One conversation as JSON: `{id, agent_kind, started_at, last_active_at}`.
    /// The timestamps are null for a conversation recorded before Crow stamped
    /// them.
    public static func conversationJSON(_ ref: HarnessConversationRef) -> JSONValue {
        let fmt = ISO8601DateFormatter()
        return .object([
            "id": .string(ref.id),
            "agent_kind": .string(ref.agentKind.rawValue),
            "started_at": ref.startedAt.map { .string(fmt.string(from: $0)) } ?? .null,
            "last_active_at": ref.lastActiveAt.map { .string(fmt.string(from: $0)) } ?? .null,
        ])
    }

    /// `agent_conversations` for `session`, oldest first.
    public static func conversationsJSON(_ session: Session) -> JSONValue {
        .array(session.agentConversations.map(conversationJSON))
    }

    /// One session that ran a matching conversation.
    public struct Match: Equatable, Sendable {
        public var session: Session
        public var conversation: HarnessConversationRef

        public static func == (lhs: Match, rhs: Match) -> Bool {
            lhs.session.id == rhs.session.id && lhs.conversation == rhs.conversation
        }
    }

    public enum Outcome: Equatable, Sendable {
        case found(Match)
        case notFound
        /// More than one conversation (or one conversation in more than one
        /// session) matches. Sorted by conversation id, then session name.
        case ambiguous([Match])
    }

    /// The conversation id in `raw`: trimmed, and reduced to its file name
    /// without `.jsonl` / `.json` when it is a transcript path, so a pasted
    /// `~/.claude/projects/…/<id>.jsonl` works as is. Nil when nothing usable
    /// is left or it holds a control character.
    public static func normalizedQuery(_ raw: String) -> String? {
        var query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.contains("/") { query = (query as NSString).lastPathComponent }
        for ext in [".jsonl", ".json"] where query.lowercased().hasSuffix(ext) {
            query = String(query.dropLast(ext.count))
        }
        guard !query.isEmpty,
              query.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
        else { return nil }
        return query
    }

    /// Find the session that ran the conversation `query` names, a full id or
    /// a unique prefix, compared case-insensitively. An exact id wins over
    /// prefixes of longer ids. Pure, so it is unit-testable.
    public static func find(conversation query: String, in sessions: [Session]) -> Outcome {
        let needle = query.lowercased()
        var exact: [Match] = []
        var prefixed: [Match] = []
        for session in sessions {
            for ref in session.agentConversations {
                let id = ref.id.lowercased()
                if id == needle {
                    exact.append(Match(session: session, conversation: ref))
                } else if id.hasPrefix(needle) {
                    prefixed.append(Match(session: session, conversation: ref))
                }
            }
        }
        let matches = exact.isEmpty ? prefixed : exact
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default:
            return .ambiguous(matches.sorted {
                ($0.conversation.id, $0.session.name) < ($1.conversation.id, $1.session.name)
            })
        }
    }

    /// The `find-session` result for a match.
    public static func matchJSON(_ match: Match) -> [String: JSONValue] {
        [
            "session_id": .string(match.session.id.uuidString),
            "name": .string(match.session.name),
            "status": .string(match.session.status.rawValue),
            "kind": .string(match.session.kind.rawValue),
            "agent_kind": .string(match.session.agentKind.rawValue),
            "conversation": conversationJSON(match.conversation),
        ]
    }

    /// The whole `find-session` RPC body over `sessions`, given the raw
    /// `agent_session` param. Throws `invalidParams` for a missing or too-short
    /// query and `applicationError` for no match or an ambiguous prefix.
    public static func findSession(agentSession raw: String?, in sessions: [Session]) throws -> [String: JSONValue] {
        guard let raw, let query = normalizedQuery(raw) else {
            throw RPCError.invalidParams("agent_session required: an agent conversation id or a unique prefix")
        }
        guard query.count >= minimumPrefixLength else {
            throw RPCError.invalidParams(
                "agent_session '\(query)' is too short: give at least \(minimumPrefixLength) characters")
        }
        switch find(conversation: query, in: sessions) {
        case .found(let match):
            return matchJSON(match)
        case .notFound:
            throw RPCError.applicationError(
                "No Crow session has run agent conversation '\(query)'. Crow records a conversation id when "
                    + "the agent's first hook fires; work sessions recorded only their latest one before CROW-1476.")
        case .ambiguous(let matches):
            let shown = matches.prefix(5).map {
                "\($0.conversation.id) (session \($0.session.name), \($0.session.id.uuidString))"
            }
            let more = matches.count > shown.count ? ", and \(matches.count - shown.count) more" : ""
            throw RPCError.applicationError(
                "agent_session '\(query)' matches \(matches.count) conversations: "
                    + shown.joined(separator: "; ") + more + ". Give more characters.")
        }
    }
}
