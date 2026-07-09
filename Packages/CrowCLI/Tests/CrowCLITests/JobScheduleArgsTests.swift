import Foundation
import Testing
import CrowIPC
@testable import CrowCLILib

// MARK: - HH:MM parsing

@Test func parseHHMMAcceptsPaddedAndBareHours() throws {
    var t = try JobScheduleArgs.parseHHMM("09:30")
    #expect(t.hour == 9 && t.minute == 30)
    t = try JobScheduleArgs.parseHHMM("9:05")
    #expect(t.hour == 9 && t.minute == 5)
    t = try JobScheduleArgs.parseHHMM("23:59")
    #expect(t.hour == 23 && t.minute == 59)
    t = try JobScheduleArgs.parseHHMM("0:00")
    #expect(t.hour == 0 && t.minute == 0)
}

@Test func parseHHMMRejectsMalformedTimes() {
    for bad in ["25:00", "9:60", "930", "9", "9:3:0", "", "ab:cd", "-1:30"] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            _ = try JobScheduleArgs.parseHHMM(bad)
        }
    }
}

// MARK: - Weekday parsing

@Test func parseWeekdaysAcceptsNamesAndNumbers() throws {
    #expect(try JobScheduleArgs.parseWeekdays("mon,wed,fri") == [2, 4, 6])
    #expect(try JobScheduleArgs.parseWeekdays("Sunday,saturday") == [1, 7])
    #expect(try JobScheduleArgs.parseWeekdays("1,7") == [1, 7])
    #expect(try JobScheduleArgs.parseWeekdays("tue, thu") == [3, 5])
}

@Test func parseWeekdaysDedupesAndSorts() throws {
    #expect(try JobScheduleArgs.parseWeekdays("fri,mon,fri,2") == [2, 6])
}

@Test func parseWeekdaysRejectsInvalidTokens() {
    for bad in ["0", "8", "funday", "mo", ""] {
        #expect(throws: (any Error).self, "expected '\(bad)' to be rejected") {
            _ = try JobScheduleArgs.parseWeekdays(bad)
        }
    }
}

// MARK: - Schedule JSON

@Test func scheduleJSONEmitsCanonicalInterval() throws {
    let json = try JobScheduleArgs.scheduleJSON(intervalSeconds: 3600, dailyAt: nil, weekdays: nil)
    #expect(json == .object(["type": .string("interval"), "seconds": .int(3600)]))
}

@Test func scheduleJSONEmitsCanonicalDailyAt() throws {
    let json = try JobScheduleArgs.scheduleJSON(intervalSeconds: nil, dailyAt: "09:30", weekdays: "fri,mon")
    #expect(json == .object([
        "type": .string("dailyAt"),
        "hour": .int(9),
        "minute": .int(30),
        "weekdays": .array([.int(2), .int(6)]),
    ]))
}

@Test func scheduleJSONDailyAtWithoutWeekdaysMeansEveryDay() throws {
    let json = try JobScheduleArgs.scheduleJSON(intervalSeconds: nil, dailyAt: "6:00", weekdays: nil)
    #expect(json?.objectValue?["weekdays"] == .array([]))
}

@Test func scheduleJSONReturnsNilWhenNoScheduleFlags() throws {
    #expect(try JobScheduleArgs.scheduleJSON(intervalSeconds: nil, dailyAt: nil, weekdays: nil) == nil)
}

@Test func scheduleJSONRejectsBothKinds() {
    #expect(throws: (any Error).self) {
        _ = try JobScheduleArgs.scheduleJSON(intervalSeconds: 60, dailyAt: "09:00", weekdays: nil)
    }
}

@Test func scheduleJSONRejectsWeekdaysWithoutDailyAt() {
    #expect(throws: (any Error).self) {
        _ = try JobScheduleArgs.scheduleJSON(intervalSeconds: 60, dailyAt: nil, weekdays: "mon")
    }
    #expect(throws: (any Error).self) {
        _ = try JobScheduleArgs.scheduleJSON(intervalSeconds: nil, dailyAt: nil, weekdays: "mon")
    }
}

@Test func scheduleJSONRejectsNonPositiveInterval() {
    for bad in [0, -5] {
        #expect(throws: (any Error).self) {
            _ = try JobScheduleArgs.scheduleJSON(intervalSeconds: bad, dailyAt: nil, weekdays: nil)
        }
    }
}

// MARK: - Prompt files

@Test func readPromptTextReadsFileContents() throws {
    let path = NSTemporaryDirectory() + "crow-prompt-\(UUID().uuidString).md"
    try "triage the error store\n".write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(try JobScheduleArgs.readPromptText(path) == "triage the error store\n")
}

@Test func readPromptTextRejectsMissingFile() {
    #expect(throws: (any Error).self) {
        _ = try JobScheduleArgs.readPromptText("/nonexistent/prompt-\(UUID().uuidString).md")
    }
}
