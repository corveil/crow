import SwiftUI
import CrowCore

/// Compact horizontal strip of session analytics metrics shown in the session header.
struct SessionAnalyticsStrip: View {
    let analytics: SessionAnalytics
    /// Wall-clock span from agent SessionStart to SessionEnd (#692). Display-only
    /// context beside "Active" — never a grading input. Nil hides the chip
    /// (open-ended session or agent that never sends SessionEnd).
    var wallClockDuration: TimeInterval? = nil

    var body: some View {
        HStack(spacing: 12) {
            StatChip(icon: "dollarsign.circle", label: "Cost", value: AnalyticsFormatting.cost(analytics.totalCost))
            StatChip(icon: "text.word.spacing", label: "Tokens", value: AnalyticsFormatting.count(analytics.totalTokens))
            StatChip(icon: "wrench", label: "Tools", value: "\(analytics.toolCallCount)")
            StatChip(icon: "clock", label: "Active", value: AnalyticsFormatting.time(analytics.activeTimeSeconds))
            if let wallClockDuration {
                StatChip(icon: "timer", label: "Duration", value: AnalyticsFormatting.time(wallClockDuration))
            }
            if analytics.linesAdded > 0 || analytics.linesRemoved > 0 {
                StatChip(
                    icon: "chevron.left.forwardslash.chevron.right",
                    label: "Lines",
                    value: "+\(analytics.linesAdded) −\(analytics.linesRemoved)"
                )
            }
            if analytics.apiErrorCount > 0 {
                StatChip(
                    icon: "exclamationmark.triangle",
                    label: "Errors",
                    value: "\(analytics.apiErrorCount)",
                    valueColor: .red
                )
            }
            Spacer()
        }
    }

}

/// A single stat chip with icon, label, and value.
struct StatChip: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = CorveilTheme.gold

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(CorveilTheme.textMuted)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(CorveilTheme.textMuted)
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(valueColor)
        }
    }
}
