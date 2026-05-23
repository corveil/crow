import Foundation
import Testing
@testable import CrowCore

@Test func jobConfigRoundTripInterval() throws {
    let config = AppConfig(jobs: [
        JobConfig(
            name: "Nightly Audit",
            workspace: "RadiusMethod",
            repo: "radiusmethod/api",
            prompts: ["Run the audit", "Summarize findings"],
            schedule: .interval(seconds: 3600),
            enabled: true
        )
    ])

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

    #expect(decoded.jobs.count == 1)
    let job = decoded.jobs[0]
    #expect(job.name == "Nightly Audit")
    #expect(job.workspace == "RadiusMethod")
    #expect(job.repo == "radiusmethod/api")
    #expect(job.prompts == ["Run the audit", "Summarize findings"])
    #expect(job.schedule == .interval(seconds: 3600))
    #expect(job.enabled == true)
}

@Test func jobConfigRoundTripDailyAt() throws {
    let job = JobConfig(
        name: "Standup",
        workspace: "Acme",
        repo: "acme/web",
        prompts: ["Generate the standup report"],
        schedule: .dailyAt(hour: 9, minute: 30, weekdays: [2, 3, 4, 5, 6]),
        lastRunAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let data = try JSONEncoder().encode(job)
    let decoded = try JSONDecoder().decode(JobConfig.self, from: data)

    #expect(decoded.workspace == "Acme")
    #expect(decoded.repo == "acme/web")
    #expect(decoded.schedule == .dailyAt(hour: 9, minute: 30, weekdays: [2, 3, 4, 5, 6]))
    #expect(decoded.lastRunAt == Date(timeIntervalSince1970: 1_700_000_000))
}

/// A job persisted before the workspace field returned (the brief free-form
/// `repo`-only era) must still decode: the missing `workspace` defaults to ""
/// and `repo` is preserved so it resolves by folder name at run time.
@Test func jobConfigBackCompatMissingWorkspaceKey() throws {
    let json = """
    {"id":"\(UUID().uuidString)","name":"FreeForm","repo":"api",
     "prompts":["go"],"schedule":{"type":"interval","seconds":3600},
     "enabled":true,"createdAt":0}
    """
    let decoded = try JSONDecoder().decode(JobConfig.self, from: Data(json.utf8))
    #expect(decoded.workspace == "")
    #expect(decoded.repo == "api")
    #expect(decoded.name == "FreeForm")
    #expect(decoded.prompts == ["go"])
    // createdAt:0 decodes as seconds since the reference date (2001-01-01).
    #expect(decoded.createdAt == Date(timeIntervalSinceReferenceDate: 0))
}

/// A config file written before jobs existed must still decode (jobs → []).
@Test func appConfigForwardCompatNoJobs() throws {
    let json = """
    {"remoteControlEnabled": true, "attributionTrailers": false}
    """
    let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    #expect(decoded.jobs.isEmpty)
    #expect(decoded.remoteControlEnabled == true)
}

@Test func jobScheduleIntervalNextRun() {
    let base = Date(timeIntervalSince1970: 1_000_000)
    let schedule = JobSchedule.interval(seconds: 600)
    #expect(schedule.nextRunDate(after: base) == base.addingTimeInterval(600))
}

@Test func jobScheduleIntervalRejectsNonPositive() {
    #expect(JobSchedule.interval(seconds: 0).nextRunDate(after: Date()) == nil)
}

@Test func jobScheduleDailyAtNextRunIsInFutureAtTime() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // Reference: 2024-01-01 08:00 UTC (a Monday). Daily at 09:00, every day.
    let reference = cal.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 8))!
    let schedule = JobSchedule.dailyAt(hour: 9, minute: 0, weekdays: [])
    let next = try #require(schedule.nextRunDate(after: reference, calendar: cal))

    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next)
    #expect(comps.hour == 9)
    #expect(comps.minute == 0)
    #expect(comps.day == 1) // same day, later that morning
    #expect(next > reference)
}

@Test func jobScheduleDailyAtSkipsToAllowedWeekday() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // 2024-01-05 is a Friday (weekday 6). Reference is that morning, after the
    // fire time. With weekdays = {Monday=2}, the next run is Monday 2024-01-08.
    let reference = cal.date(from: DateComponents(year: 2024, month: 1, day: 5, hour: 10))!
    let schedule = JobSchedule.dailyAt(hour: 9, minute: 0, weekdays: [2])
    let next = try #require(schedule.nextRunDate(after: reference, calendar: cal))

    #expect(cal.component(.weekday, from: next) == 2) // Monday
    let comps = cal.dateComponents([.year, .month, .day], from: next)
    #expect(comps.year == 2024)
    #expect(comps.month == 1)
    #expect(comps.day == 8)
}

@Test func jobConfigValidateName() {
    #expect(JobConfig.validateName("", existingNames: []) != nil)
    #expect(JobConfig.validateName("Audit", existingNames: ["audit"]) != nil) // case-insensitive dupe
    #expect(JobConfig.validateName("Audit", existingNames: ["Other"]) == nil)
}
