import Foundation
import Testing
@testable import CrowCore

/// CROW-1439: a Manager's header analytics strip shows its current ISO-week
/// rollup — the same `managerUsageWeekly` row the Scorecard's Manager Usage
/// card renders — kept live by `applyLiveManagerWeek` on every datapoint.
@Suite("Manager live current-week analytics")
struct ManagerLiveWeekTests {

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Wed 2026-11-11 12:00 UTC — ISO week starting Mon 2026-11-09.
    private static let wednesday = Date(timeIntervalSince1970: 1_794_398_400)

    @Test func storeKeyIsCompositeDayAndSession() {
        let calendar = Self.utcCalendar()
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let week = ManagerWeeklyUsage.week(containing: Self.wednesday, calendar: calendar)
        #expect(week != nil)
        let key = ManagerWeeklyUsage.storeKey(weekStart: week!.start, sessionID: id, calendar: calendar)
        #expect(key == "2026-11-09|11111111-2222-3333-4444-555555555555")
    }

    @Test @MainActor func applyWritesTheWeekRowAndTheHookAggregate() {
        let appState = AppState()
        let id = UUID()
        let calendar = ManagerWeeklyUsage.weekCalendar()
        let week = ManagerWeeklyUsage.week(containing: Date(), calendar: calendar)!
        let analytics = SessionAnalytics(totalCost: 4.5, inputTokens: 300, promptCount: 6)

        appState.applyLiveManagerWeek(analytics, for: id, weekStart: week.start, calendar: calendar)

        // The live aggregate is the window, never lifetime.
        #expect(appState.existingHookState(for: id)?.analytics == analytics)
        let current = appState.currentManagerWeek(for: id)
        #expect(current?.analytics == analytics)
        #expect(current?.sessionID == id)
        #expect(current?.weekStart == week.start)
    }

    @Test @MainActor func applyCarriesTheAccumulatedCompactionCount() {
        let appState = AppState()
        let id = UUID()
        let calendar = ManagerWeeklyUsage.weekCalendar()
        let week = ManagerWeeklyUsage.week(containing: Date(), calendar: calendar)!
        let key = ManagerWeeklyUsage.storeKey(weekStart: week.start, sessionID: id, calendar: calendar)
        appState.managerUsageWeekly[key] = ManagerWeeklyUsage(
            weekStart: week.start, analytics: SessionAnalytics(totalCost: 1),
            sessionID: id, compactionCount: 3)

        appState.applyLiveManagerWeek(
            SessionAnalytics(totalCost: 2), for: id, weekStart: week.start, calendar: calendar)

        #expect(appState.managerUsageWeekly[key]?.analytics.totalCost == 2)
        #expect(appState.managerUsageWeekly[key]?.compactionCount == 3)
    }

    @Test @MainActor func emptyAggregateWritesNoRow() {
        let appState = AppState()
        let id = UUID()
        let calendar = ManagerWeeklyUsage.weekCalendar()
        let week = ManagerWeeklyUsage.week(containing: Date(), calendar: calendar)!

        appState.applyLiveManagerWeek(SessionAnalytics(), for: id, weekStart: week.start, calendar: calendar)

        #expect(appState.managerUsageWeekly.isEmpty)
        #expect(appState.currentManagerWeek(for: id) == nil)
    }

    /// Across an ISO-week boundary the strip resets: last week's row is not
    /// the current week, so nothing shows until the new week has data.
    @Test @MainActor func lastWeeksRowIsNotTheCurrentWeek() {
        let appState = AppState()
        let id = UUID()
        let calendar = ManagerWeeklyUsage.weekCalendar()
        let thisWeek = ManagerWeeklyUsage.week(containing: Date(), calendar: calendar)!
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start)!

        appState.applyLiveManagerWeek(
            SessionAnalytics(totalCost: 9), for: id, weekStart: lastWeekStart, calendar: calendar)

        #expect(appState.currentManagerWeek(for: id) == nil)
        let aWeekAgo = calendar.date(byAdding: .weekOfYear, value: -1, to: Date())!
        #expect(appState.currentManagerWeek(for: id, now: aWeekAgo)?.analytics.totalCost == 9)
    }

    @Test @MainActor func anotherManagersWeekIsNotMine() {
        let appState = AppState()
        let mine = UUID()
        let theirs = UUID()
        let calendar = ManagerWeeklyUsage.weekCalendar()
        let week = ManagerWeeklyUsage.week(containing: Date(), calendar: calendar)!

        appState.applyLiveManagerWeek(
            SessionAnalytics(totalCost: 5), for: theirs, weekStart: week.start, calendar: calendar)

        #expect(appState.currentManagerWeek(for: mine) == nil)
    }
}
