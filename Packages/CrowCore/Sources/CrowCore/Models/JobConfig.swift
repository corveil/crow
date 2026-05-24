import Foundation

/// A scheduled job: one or more prompts that fire automatically on a schedule,
/// scoped to a repo within a workspace.
///
/// When a job fires, the scheduler resolves the repo under
/// `{devRoot}/{workspace}/` — cloning it on demand if it isn't checked out yet —
/// then creates a fresh worktree + session + Claude Code terminal there and
/// sends `prompts` in order. Persisted as part of `AppConfig` in
/// `{devRoot}/.claude/config.json`.
///
/// Like `WorkspaceInfo`, decoding is forward-compatible: missing keys fall back
/// to defaults so older config files keep working.
public struct JobConfig: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    /// Workspace name (matches `WorkspaceInfo.name`); the repo's parent folder
    /// under the dev root and the source of its provider/host.
    public var workspace: String
    /// The repo as an `owner/repo` slug (chosen from the workspace's provider).
    /// Its last path component is the local folder name under the workspace.
    public var repo: String
    /// Ordered prompts. The first launches Claude; the rest are sent after launch.
    public var prompts: [String]
    public var schedule: JobSchedule
    public var enabled: Bool
    /// When the job last fired. Runtime state, persisted so restarts don't replay.
    public var lastRunAt: Date?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        workspace: String,
        repo: String,
        prompts: [String],
        schedule: JobSchedule,
        enabled: Bool = true,
        lastRunAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.workspace = workspace
        self.repo = repo
        self.prompts = prompts
        self.schedule = schedule
        self.enabled = enabled
        self.lastRunAt = lastRunAt
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace) ?? ""
        repo = try container.decodeIfPresent(String.self, forKey: .repo) ?? ""
        prompts = try container.decodeIfPresent([String].self, forKey: .prompts) ?? []
        schedule = try container.decodeIfPresent(JobSchedule.self, forKey: .schedule) ?? .interval(seconds: 86400)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, workspace, repo, prompts, schedule, enabled, lastRunAt, createdAt
    }

    /// Validate a job name, returning an error message or `nil` if valid.
    public static func validateName(_ name: String, existingNames: [String]) -> String? {
        if name.isEmpty {
            return "Name is required"
        }
        let lowercased = name.lowercased()
        if existingNames.contains(where: { $0.lowercased() == lowercased }) {
            return "A job with this name already exists"
        }
        return nil
    }

    /// A new job seeded from this one as the starting point for a duplicate:
    /// fresh `id` + `createdAt`, cleared `lastRunAt`, and `enabled = false` so it
    /// can't fire before the user reviews it. `workspace`, `repo`, `prompts`, and
    /// `schedule` are copied verbatim. The name is made unique against
    /// `existingNames` by appending " copy" (then " copy 2", " copy 3", …).
    public func duplicated(existingNames: [String]) -> JobConfig {
        JobConfig(
            id: UUID(),
            name: Self.uniqueCopyName(of: name, existingNames: existingNames),
            workspace: workspace,
            repo: repo,
            prompts: prompts,
            schedule: schedule,
            enabled: false,
            lastRunAt: nil,
            createdAt: Date()
        )
    }

    /// Builds a "<base> copy" name absent from `existingNames` (case-insensitive,
    /// matching `validateName`), escalating to " copy 2", " copy 3", … on collision.
    static func uniqueCopyName(of base: String, existingNames: [String]) -> String {
        let taken = Set(existingNames.map { $0.lowercased() })
        let first = "\(base) copy"
        if !taken.contains(first.lowercased()) { return first }
        var n = 2
        while taken.contains("\(base) copy \(n)".lowercased()) { n += 1 }
        return "\(base) copy \(n)"
    }

    /// The next time this job should fire strictly after `reference`.
    ///
    /// The scheduler treats the job as due when
    /// `nextRunDate(after: lastRunAt ?? createdAt) <= now`. Returns `nil` for an
    /// unsatisfiable schedule (e.g. a non-positive interval).
    public func nextRunDate(after reference: Date, calendar: Calendar = .current) -> Date? {
        schedule.nextRunDate(after: reference, calendar: calendar)
    }
}

/// How often a `JobConfig` fires.
///
/// Encoded with a `type` discriminator (`"interval"` / `"dailyAt"`) so the JSON
/// stays readable and tolerant of future cases.
public enum JobSchedule: Codable, Sendable, Equatable {
    /// Fire every `seconds` after the previous run (or after `createdAt`).
    case interval(seconds: Int)
    /// Fire daily at `hour`:`minute` (local time) on the given `weekdays`.
    /// Weekday integers follow `Calendar`'s convention (1 = Sunday … 7 = Saturday).
    /// An empty set means every day.
    case dailyAt(hour: Int, minute: Int, weekdays: Set<Int>)

    private enum CodingKeys: String, CodingKey {
        case type, seconds, hour, minute, weekdays
    }

    private enum Kind: String, Codable {
        case interval, dailyAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interval(let seconds):
            try c.encode(Kind.interval, forKey: .type)
            try c.encode(seconds, forKey: .seconds)
        case .dailyAt(let hour, let minute, let weekdays):
            try c.encode(Kind.dailyAt, forKey: .type)
            try c.encode(hour, forKey: .hour)
            try c.encode(minute, forKey: .minute)
            try c.encode(weekdays.sorted(), forKey: .weekdays)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(Kind.self, forKey: .type)
        switch type {
        case .interval:
            self = .interval(seconds: try c.decode(Int.self, forKey: .seconds))
        case .dailyAt:
            let hour = try c.decode(Int.self, forKey: .hour)
            let minute = try c.decode(Int.self, forKey: .minute)
            let weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? []
            self = .dailyAt(hour: hour, minute: minute, weekdays: Set(weekdays))
        }
    }

    /// Next fire time strictly after `reference`, or `nil` if unsatisfiable.
    public func nextRunDate(after reference: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .interval(let seconds):
            guard seconds > 0 else { return nil }
            return reference.addingTimeInterval(TimeInterval(seconds))
        case .dailyAt(let hour, let minute, let weekdays):
            var match = DateComponents()
            match.hour = hour
            match.minute = minute
            match.second = 0
            guard var candidate = calendar.nextDate(
                after: reference, matching: match, matchingPolicy: .nextTime
            ) else { return nil }
            guard !weekdays.isEmpty else { return candidate }
            // Advance day-by-day until the weekday matches (bounded to a week).
            var attempts = 0
            while !weekdays.contains(calendar.component(.weekday, from: candidate)) {
                guard let next = calendar.nextDate(
                    after: candidate, matching: match, matchingPolicy: .nextTime
                ) else { return nil }
                candidate = next
                attempts += 1
                if attempts > 7 { return nil }
            }
            return candidate
        }
    }
}
