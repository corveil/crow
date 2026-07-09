import ArgumentParser
import CrowIPC
import Foundation

/// Parsing for the `crow job add`/`edit` schedule and prompt flags.
///
/// Emits the canonical `JobSchedule` JSON shape
/// (`{"type":"interval","seconds":N}` /
/// `{"type":"dailyAt","hour":H,"minute":M,"weekdays":[...]}`) so the app can
/// decode it with the model's own `Codable` conformance.
enum JobScheduleArgs {
    /// Weekday names accepted by `--weekdays`, indexed by `Calendar` weekday
    /// number (1 = Sunday … 7 = Saturday).
    private static let weekdayNames = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    /// Build the schedule JSON from the raw flag values, or `nil` when no
    /// schedule flag was given (edit = "leave the schedule unchanged").
    ///
    /// - Throws: `ValidationError` when both schedule kinds are given, when
    ///   `--weekdays` is used without `--daily-at`, or when a value is malformed.
    static func scheduleJSON(intervalSeconds: Int?, dailyAt: String?, weekdays: String?) throws -> JSONValue? {
        if intervalSeconds != nil && dailyAt != nil {
            throw ValidationError("--interval-seconds and --daily-at are mutually exclusive.")
        }
        if weekdays != nil && dailyAt == nil {
            throw ValidationError("--weekdays requires --daily-at.")
        }
        if let seconds = intervalSeconds {
            guard seconds >= 1 else {
                throw ValidationError("--interval-seconds must be at least 1.")
            }
            return .object(["type": .string("interval"), "seconds": .int(seconds)])
        }
        if let dailyAt {
            let (hour, minute) = try parseHHMM(dailyAt)
            let days = try weekdays.map(parseWeekdays) ?? []
            return .object([
                "type": .string("dailyAt"),
                "hour": .int(hour),
                "minute": .int(minute),
                "weekdays": .array(days.map { .int($0) }),
            ])
        }
        return nil
    }

    /// Parse a "HH:MM" (24-hour) time; single-digit hours are accepted.
    static func parseHHMM(_ value: String) throws -> (hour: Int, minute: Int) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            throw ValidationError("'\(value)' is not a valid time. Expected HH:MM (24-hour), e.g. 09:30.")
        }
        return (hour, minute)
    }

    /// Parse a comma-separated weekday list into sorted, deduped `Calendar`
    /// weekday numbers. Accepts names ("mon", "monday", case-insensitive)
    /// or integers 1–7 (1 = Sunday … 7 = Saturday).
    static func parseWeekdays(_ value: String) throws -> [Int] {
        var days = Set<Int>()
        for token in value.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces).lowercased()
            if let n = Int(trimmed) {
                guard (1...7).contains(n) else {
                    throw ValidationError("'\(trimmed)' is not a valid weekday number (1 = Sunday … 7 = Saturday).")
                }
                days.insert(n)
            } else if trimmed.count >= 3,
                      let idx = weekdayNames.firstIndex(where: { $0.hasPrefix(trimmed) }) {
                days.insert(idx + 1)
            } else {
                throw ValidationError("'\(trimmed)' is not a valid weekday. Use names (sun…sat) or numbers 1–7.")
            }
        }
        guard !days.isEmpty else {
            throw ValidationError("--weekdays must list at least one weekday.")
        }
        return days.sorted()
    }

    /// Read a prompt from a file path, or from stdin when the path is "-".
    static func readPromptText(_ path: String) throws -> String {
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                throw ValidationError("stdin is not valid UTF-8.")
            }
            return text
        }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ValidationError("Could not read prompt file '\(path)': \(error.localizedDescription)")
        }
    }
}
