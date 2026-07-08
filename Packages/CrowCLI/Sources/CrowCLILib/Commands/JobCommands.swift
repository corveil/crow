import ArgumentParser
import CrowIPC
import Foundation

/// Parent command for scheduled-job management: `crow job <subcommand>`.
///
/// Jobs are timed prompt-sets scoped to a repo (the Jobs sidebar feature).
/// Every subcommand goes through the running app's RPC socket so mutations hit
/// the app's live in-memory config — the scheduler and the Settings UI pick
/// them up immediately, with no app restart.
public struct Job: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "job",
        abstract: "Manage scheduled jobs",
        subcommands: [
            JobList.self,
            JobGet.self,
            JobAdd.self,
            JobEdit.self,
            JobEnable.self,
            JobDisable.self,
            JobRun.self,
            JobDelete.self,
            JobDuplicate.self,
        ]
    )

    public init() {}
}

public struct JobList: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list", abstract: "List all jobs")

    public init() {}

    public func run() throws {
        let result = try rpc("job-list")
        printJSON(result)
    }
}

public struct JobGet: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "get", abstract: "Show one job's full details")

    @Option(name: .long, help: "Job UUID") var id: String

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "job UUID")
    }

    public func run() throws {
        let result = try rpc("job-get", params: ["job_id": .string(id)])
        printJSON(result)
    }
}

public struct JobAdd: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a job",
        discussion: """
        Prompts are sent in order: every --prompt first, then the contents of \
        every --prompt-file. Exactly one schedule is required: --interval-seconds \
        or --daily-at HH:MM (optionally restricted with --weekdays).
        """
    )

    @Option(name: .long, help: "Job name (must be unique)") var name: String
    @Option(name: .long, help: "Workspace name (folder under the dev root)") var workspace: String
    @Option(name: .long, help: "Repository slug (owner/repo)") var repo: String
    @Option(name: .long, parsing: .singleValue, help: "Prompt text (repeatable; sent in order)")
    var prompt: [String] = []
    @Option(name: .customLong("prompt-file"), parsing: .singleValue,
            help: "Read a prompt from a file; '-' reads stdin (repeatable)")
    var promptFile: [String] = []
    @Option(name: .customLong("interval-seconds"), help: "Run every N seconds")
    var intervalSeconds: Int?
    @Option(name: .customLong("daily-at"), help: "Run daily at HH:MM (24-hour, local time)")
    var dailyAt: String?
    @Option(name: .long, help: "Comma-separated weekdays for --daily-at (sun,mon,… or 1-7); omit for every day")
    var weekdays: String?
    @Flag(name: .long, help: "Create the job disabled") var disabled: Bool = false

    public init() {}

    public func validate() throws {
        guard try JobScheduleArgs.scheduleJSON(
            intervalSeconds: intervalSeconds, dailyAt: dailyAt, weekdays: weekdays
        ) != nil else {
            throw ValidationError("A schedule is required: --interval-seconds or --daily-at.")
        }
        guard !prompt.isEmpty || !promptFile.isEmpty else {
            throw ValidationError("At least one --prompt or --prompt-file is required.")
        }
        guard promptFile.filter({ $0 == "-" }).count <= 1 else {
            throw ValidationError("At most one --prompt-file may read from stdin ('-').")
        }
    }

    public func run() throws {
        let schedule = try JobScheduleArgs.scheduleJSON(
            intervalSeconds: intervalSeconds, dailyAt: dailyAt, weekdays: weekdays
        )!
        let prompts = try prompt + promptFile.map(JobScheduleArgs.readPromptText)
        let result = try rpc("job-add", params: [
            "name": .string(name),
            "workspace": .string(workspace),
            "repo": .string(repo),
            "prompts": .array(prompts.map { .string($0) }),
            "schedule": schedule,
            "enabled": .bool(!disabled),
        ])
        printJSON(result)
    }
}

public struct JobEdit: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Update fields on an existing job",
        discussion: """
        Only the provided flags change; everything else keeps its value. Any \
        --prompt/--prompt-file replaces the job's whole prompt list, and any \
        schedule flag replaces the whole schedule. Use enable/disable to toggle \
        the enabled flag.
        """
    )

    @Option(name: .long, help: "Job UUID") var id: String
    @Option(name: .long, help: "New job name (must be unique)") var name: String?
    @Option(name: .long, help: "New workspace name") var workspace: String?
    @Option(name: .long, help: "New repository slug (owner/repo)") var repo: String?
    @Option(name: .long, parsing: .singleValue, help: "Replacement prompt text (repeatable; replaces all prompts)")
    var prompt: [String] = []
    @Option(name: .customLong("prompt-file"), parsing: .singleValue,
            help: "Read a replacement prompt from a file; '-' reads stdin (repeatable)")
    var promptFile: [String] = []
    @Option(name: .customLong("interval-seconds"), help: "Run every N seconds")
    var intervalSeconds: Int?
    @Option(name: .customLong("daily-at"), help: "Run daily at HH:MM (24-hour, local time)")
    var dailyAt: String?
    @Option(name: .long, help: "Comma-separated weekdays for --daily-at (sun,mon,… or 1-7); omit for every day")
    var weekdays: String?

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "job UUID")
        _ = try JobScheduleArgs.scheduleJSON(
            intervalSeconds: intervalSeconds, dailyAt: dailyAt, weekdays: weekdays
        )
        guard name != nil || workspace != nil || repo != nil
            || !prompt.isEmpty || !promptFile.isEmpty
            || intervalSeconds != nil || dailyAt != nil else {
            throw ValidationError("Nothing to edit — provide at least one field flag.")
        }
        guard promptFile.filter({ $0 == "-" }).count <= 1 else {
            throw ValidationError("At most one --prompt-file may read from stdin ('-').")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["job_id": .string(id)]
        if let name { params["name"] = .string(name) }
        if let workspace { params["workspace"] = .string(workspace) }
        if let repo { params["repo"] = .string(repo) }
        if !prompt.isEmpty || !promptFile.isEmpty {
            let prompts = try prompt + promptFile.map(JobScheduleArgs.readPromptText)
            params["prompts"] = .array(prompts.map { .string($0) })
        }
        if let schedule = try JobScheduleArgs.scheduleJSON(
            intervalSeconds: intervalSeconds, dailyAt: dailyAt, weekdays: weekdays
        ) {
            params["schedule"] = schedule
        }
        let result = try rpc("job-edit", params: params)
        printJSON(result)
    }
}

public struct JobEnable: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable a job")

    @Option(name: .long, help: "Job UUID") var id: String

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "job UUID")
    }

    public func run() throws {
        let result = try rpc("job-enable", params: ["job_id": .string(id)])
        printJSON(result)
    }
}

public struct JobDisable: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable a job")

    @Option(name: .long, help: "Job UUID") var id: String

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "job UUID")
    }

    public func run() throws {
        let result = try rpc("job-disable", params: ["job_id": .string(id)])
        printJSON(result)
    }
}

public struct JobRun: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a job now, regardless of its schedule or enabled flag",
        discussion: """
        Returns the launched session and terminal ids. The run continues in the \
        app even if the CLI times out waiting (e.g. while a repo is cloned on \
        demand).
        """
    )

    @Option(name: .long, help: "Job UUID") var id: String

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "job UUID")
    }

    public func run() throws {
        // Launching can clone a repo on demand — allow well past the default 30s.
        let result = try rpc("job-run", params: ["job_id": .string(id)], timeoutSeconds: 120)
        printJSON(result)
    }
}

public struct JobDelete: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a job")

    @Option(name: .long, help: "Job UUID") var id: String

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "job UUID")
    }

    public func run() throws {
        let result = try rpc("job-delete", params: ["job_id": .string(id)])
        printJSON(result)
    }
}

public struct JobDuplicate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "duplicate",
        abstract: "Duplicate a job (the copy starts disabled with a unique name)"
    )

    @Option(name: .long, help: "Job UUID") var id: String

    public init() {}

    public func validate() throws {
        try validateUUID(id, label: "job UUID")
    }

    public func run() throws {
        let result = try rpc("job-duplicate", params: ["job_id": .string(id)])
        printJSON(result)
    }
}
