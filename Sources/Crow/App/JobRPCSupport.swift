import CrowCore
import CrowIPC
import Foundation

/// Pure decode/encode helpers for the `job-*` RPC handlers (CROW-604).
///
/// Kept out of AppDelegate so the param validation and response shapes are
/// unit-testable without a socket (same pattern as `JobScheduler.finishDecision`).
enum JobRPC {
    /// Decode the canonical `JobSchedule` JSON (`{"type":"interval",...}` /
    /// `{"type":"dailyAt",...}`) and range-check it.
    ///
    /// - Throws: `RPCError.invalidParams` on a malformed shape or out-of-range
    ///   values (seconds < 1, hour ∉ 0–23, minute ∉ 0–59, weekdays ⊄ 1–7).
    static func decodeSchedule(_ value: JSONValue) throws -> JobSchedule {
        let schedule: JobSchedule
        do {
            let data = try JSONEncoder().encode(value)
            schedule = try JSONDecoder().decode(JobSchedule.self, from: data)
        } catch {
            throw RPCError.invalidParams(
                "Malformed schedule. Expected {\"type\":\"interval\",\"seconds\":N} or {\"type\":\"dailyAt\",\"hour\":H,\"minute\":M,\"weekdays\":[1-7]}"
            )
        }
        switch schedule {
        case .interval(let seconds):
            guard seconds >= 1 else {
                throw RPCError.invalidParams("Schedule interval must be at least 1 second")
            }
        case .dailyAt(let hour, let minute, let weekdays):
            guard (0...23).contains(hour), (0...59).contains(minute) else {
                throw RPCError.invalidParams("Schedule time out of range (hour 0-23, minute 0-59)")
            }
            guard weekdays.allSatisfy({ (1...7).contains($0) }) else {
                throw RPCError.invalidParams("Schedule weekdays must be 1-7 (1 = Sunday)")
            }
        }
        return schedule
    }

    /// Extract a prompts array, requiring at least one non-empty prompt.
    ///
    /// - Throws: `RPCError.invalidParams` when missing, not an array of
    ///   strings, or all prompts are blank.
    static func decodePrompts(_ value: JSONValue?) throws -> [String] {
        guard let items = value?.arrayValue else {
            throw RPCError.invalidParams("prompts must be an array of strings")
        }
        let prompts = items.compactMap(\.stringValue)
        guard prompts.count == items.count else {
            throw RPCError.invalidParams("prompts must be an array of strings")
        }
        guard prompts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw RPCError.invalidParams("At least one non-empty prompt is required")
        }
        return prompts
    }

    /// Canonical job JSON for RPC responses: snake_case keys, ISO8601 dates,
    /// the model's own `schedule` encoding, plus a computed `next_run_at`
    /// (`null` when the schedule is unsatisfiable). `last_run_at` is omitted
    /// for a job that has never run.
    static func jobJSON(_ job: JobConfig) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(job),
              var object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else {
            return .object(["id": .string(job.id.uuidString)])
        }
        if let next = job.nextRunDate(after: job.lastRunAt ?? job.createdAt) {
            object["next_run_at"] = .string(ISO8601DateFormatter().string(from: next))
        } else {
            object["next_run_at"] = .null
        }
        return .object(object)
    }
}
