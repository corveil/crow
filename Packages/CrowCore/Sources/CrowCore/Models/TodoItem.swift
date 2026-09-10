import Foundation

/// Lifecycle of a pre-ticket idea (CROW-1231).
///
/// Capture is the intake; explore / ticket / work promote into Crow's existing
/// session and ticket flow; parked and dropped are the "this didn't earn a
/// ticket" exits. `done` is the terminal success state after a work session
/// ships. Items are never reaped by session cleanup — a parked idea must
/// survive until someone acts on it.
public enum TodoState: String, Codable, Sendable, CaseIterable {
    case captured
    case exploring
    case ticketed
    case working
    case done
    case parked
    case dropped
}

/// Provenance on a Scratch item: the Manager that explored it, the ticket it
/// became, the PR that shipped, or a free-form URL.
public enum TodoLinkType: String, Codable, Sendable, CaseIterable {
    case session
    case ticket
    case pr
    case custom
}

/// One link on a Scratch item. Session links carry the session UUID so a badge
/// can open the pane; ticket/PR/custom links carry a URL.
public struct TodoLink: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var type: TodoLinkType
    public var url: String?
    public var sessionID: UUID?
    public var label: String

    public init(
        id: UUID = UUID(),
        type: TodoLinkType,
        url: String? = nil,
        sessionID: UUID? = nil,
        label: String
    ) {
        self.id = id
        self.type = type
        self.url = url
        self.sessionID = sessionID
        self.label = label
    }
}

/// A durable pre-ticket idea captured in Crow (CROW-1231).
///
/// Lives in `StoreData.todos`, on the one injected `JSONStore`, and is exempt
/// from the session retention reaper. Decoding is forward-compatible: missing
/// keys fall back to defaults so older `store.json` files keep loading.
public struct TodoItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var note: String
    public var tags: [String]
    public var priority: String?
    public var state: TodoState
    public var links: [TodoLink]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        note: String = "",
        tags: [String] = [],
        priority: String? = nil,
        state: TodoState = .captured,
        links: [TodoLink] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.note = note
        self.tags = tags
        self.priority = priority
        self.state = state
        self.links = links
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        priority = try container.decodeIfPresent(String.self, forKey: .priority)
        state = try container.decodeIfPresent(TodoState.self, forKey: .state) ?? .captured
        links = try container.decodeIfPresent([TodoLink].self, forKey: .links) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, note, tags, priority, state, links, createdAt, updatedAt
    }

    /// Recognized priority tokens. Stored lowercase (`p1`…`p4`).
    public static let validPriorities: [String] = ["p1", "p2", "p3", "p4"]

    public static var invalidPriorityMessage: String {
        "priority must be one of: \(validPriorities.joined(separator: ", "))"
    }

    /// Normalize a priority string, or `nil` when it is blank.
    ///
    /// - Throws: ``NormalizeError/invalidPriority`` when the value is present
    ///   but not `p1`…`p4`.
    public static func normalizePriority(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return nil }
        guard validPriorities.contains(trimmed) else {
            throw NormalizeError.invalidPriority
        }
        return trimmed
    }

    public enum NormalizeError: Error, Equatable, CustomStringConvertible {
        case invalidPriority
        public var description: String { TodoItem.invalidPriorityMessage }
    }

    /// Trim, drop empties, and uniquify tags case-insensitively while preserving
    /// the first spelling seen.
    public static func normalizeTags(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for tag in raw {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }

    /// The most recently attached session link, if any.
    public var linkedSessionID: UUID? {
        links.reversed().first(where: { $0.type == .session })?.sessionID
    }

    /// The most recently attached ticket URL, if any.
    public var linkedTicketURL: String? {
        links.reversed().first(where: { $0.type == .ticket })?.url
    }
}
