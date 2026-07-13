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
            StatChip(icon: "dollarsign.circle", label: "Cost", value: formatCost(analytics.totalCost))
            StatChip(icon: "text.word.spacing", label: "Tokens", value: formatCount(analytics.totalTokens))
            StatChip(icon: "wrench", label: "Tools", value: "\(analytics.toolCallCount)")
            StatChip(icon: "clock", label: "Active", value: formatTime(analytics.activeTimeSeconds))
            if let wallClockDuration {
                StatChip(icon: "timer", label: "Duration", value: formatTime(wallClockDuration))
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

    // MARK: - Formatting

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 && cost > 0 {
            return "<$0.01"
        }
        return String(format: "$%.2f", cost)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func formatTime(_ seconds: Double) -> String {
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

/// A single stat chip with icon, label, and value.
private struct StatChip: View {
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
