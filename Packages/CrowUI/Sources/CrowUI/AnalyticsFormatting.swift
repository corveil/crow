import Foundation

/// Shared display formatting for analytics values (cost, token counts,
/// durations) — used by the session analytics strip and the scorecard.
enum AnalyticsFormatting {
    static func cost(_ cost: Double) -> String {
        if cost < 0.01 && cost > 0 {
            return "<$0.01"
        }
        return String(format: "$%.2f", cost)
    }

    static func count(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    static func time(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds >= 3600 {
            let hours = totalSeconds / 3600
            let mins = (totalSeconds % 3600) / 60
            return "\(hours)h \(mins)m"
        } else if totalSeconds >= 60 {
            return "\(totalSeconds / 60)m"
        } else {
            return "\(totalSeconds)s"
        }
    }
}
