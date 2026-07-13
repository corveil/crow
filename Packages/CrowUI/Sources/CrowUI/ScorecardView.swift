import SwiftUI
import CrowCore

// MARK: - Scorecard View (ADR 0008 v1, #710)

/// Full-pane private efficiency scorecard: the weekly A–F grade with its
/// coachable deductions, the sessions-shipped throughput count, and the
/// self-comparison against the user's own trailing 4-week median. Read-only —
/// computed from the persisted snapshots mirrored on
/// `appState.analyticsSnapshots`. The grade and the shipped count are separate
/// surfaces; nothing on this screen combines them into one number.
public struct ScorecardView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    private var model: ScorecardModel {
        ScorecardModel.build(
            snapshots: Array(appState.analyticsSnapshots.values),
            now: Date(),
            calendar: .current
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            SectionHelpBanner(
                description: "Private efficiency scorecard — this week vs. your own trailing 4-week normal. Grade thresholds are starting heuristics under a 4-week calibration period; expect them to move.",
                storageKey: "helpDismissed_scorecard"
            )
            Divider()
            if appState.analyticsSnapshots.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Scorecard")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(CorveilTheme.gold)

            Spacer()

            Text(Self.weekRangeLabel(model.currentWeek.weekStart))
                .font(.caption)
                .foregroundStyle(CorveilTheme.textSecondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(CorveilTheme.bgSurface)
    }

    // MARK: Content

    private var content: some View {
        let model = self.model
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    gradeCard(model.currentWeek)
                    shippedCard(model.currentWeek)
                }

                baselineSection(model)
                displayedStatsSection(model.currentWeek)

                if !model.priorWeeks.isEmpty {
                    priorWeeksSection(model.priorWeeks)
                }

                if !model.currentWeekSessions.isEmpty {
                    sessionsSection(model.currentWeekSessions)
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Session Data Yet", systemImage: "chart.bar.xaxis")
        } description: {
            Text("The scorecard is computed from analytics snapshots written when sessions complete or archive. Snapshots require Claude Code telemetry, which is off by default — enable it in Settings, then finish a session.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Weekly grade card

    private func gradeCard(_ week: WeeklyScorecard) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("This Week's Grade")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)

                switch week.result {
                case .graded(let score, let letter, let deductions):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(letter.rawValue)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(Self.gradeColor(letter))
                        Text("\(score)/100")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(CorveilTheme.textSecondary)
                    }
                    if deductions.isEmpty {
                        Text("No deductions — clean week.")
                            .font(.caption)
                            .foregroundStyle(CorveilTheme.textMuted)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(deductions, id: \.metric) { deduction in
                                deductionRow(deduction)
                            }
                        }
                    }
                case .insufficientData(let prompts):
                    insufficientDataBlock(prompts: prompts)
                }
            }
        }
    }

    private func deductionRow(_ deduction: EfficiencyGrading.Deduction) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(deduction.label)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("−\(deduction.points)")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.red)
            }
            Text(Self.coachingHint(deduction.metric))
                .font(.caption2)
                .foregroundStyle(CorveilTheme.textMuted)
        }
    }

    private func insufficientDataBlock(prompts: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Insufficient data")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(CorveilTheme.textSecondary)
            Text("\(prompts) prompt\(prompts == 1 ? "" : "s") this week — grading starts at \(EfficiencyGrading.Tuning.minimumGradablePromptCount).")
                .font(.caption)
                .foregroundStyle(CorveilTheme.textMuted)
        }
    }

    // MARK: Sessions-shipped card (separate surface — never combined)

    private func shippedCard(_ week: WeeklyScorecard) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sessions Shipped")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)

                Text("\(week.sessionsShipped)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(CorveilTheme.gold)

                switch week.costPerShipped {
                case .graded(let cost):
                    Text("\(AnalyticsFormatting.cost(cost)) per shipped session")
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textSecondary)
                case .insufficientOutcomes:
                    Text("Insufficient outcomes — nothing shipped this week.")
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textMuted)
                }
            }
        }
    }

    // MARK: Baseline (vs. your normal)

    @ViewBuilder
    private func baselineSection(_ model: ScorecardModel) -> some View {
        let baseline = model.baseline
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("vs. Your Normal (trailing 4-week median)")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)

                if baseline.weeksAvailable < EfficiencyGrading.Tuning.minimumBaselineWeeks {
                    Text("Baseline building — \(baseline.weeksAvailable) of \(EfficiencyGrading.Tuning.baselineWeekCount) weeks of history.")
                        .font(.caption)
                        .foregroundStyle(CorveilTheme.textMuted)
                } else {
                    let input = model.currentWeek.input
                    VStack(alignment: .leading, spacing: 5) {
                        if case .graded(let score, _, _) = model.currentWeek.result,
                           let median = baseline.medianScore {
                            comparisonRow(
                                name: "Score", current: Double(score), baseline: median,
                                higherIsBetter: true) { String(format: "%.0f", $0) }
                        }
                        if let median = baseline.medianCompactionsPerActiveHour {
                            comparisonRow(
                                name: "Compactions/active hr",
                                current: input.compactionsPerActiveHour, baseline: median,
                                higherIsBetter: false) { String(format: "%.1f", $0) }
                        }
                        if let median = baseline.medianInputTokensPerPrompt {
                            comparisonRow(
                                name: "Input tokens/prompt",
                                current: input.inputTokensPerPrompt, baseline: median,
                                higherIsBetter: false) { AnalyticsFormatting.count(Int($0)) }
                        }
                        if let median = baseline.medianCacheHitRatio {
                            comparisonRow(
                                name: "Cache hit ratio",
                                current: input.cacheHitRatio, baseline: median,
                                higherIsBetter: true) { String(format: "%.0f%%", $0 * 100) }
                        }
                        if let median = baseline.medianApiErrorRate {
                            comparisonRow(
                                name: "API error rate",
                                current: input.apiErrorRate, baseline: median,
                                higherIsBetter: false) { String(format: "%.1f%%", $0 * 100) }
                        }
                        if let median = baseline.medianCostPerShipped,
                           case .graded(let cost) = model.currentWeek.costPerShipped {
                            comparisonRow(
                                name: "Cost/shipped", current: cost, baseline: median,
                                higherIsBetter: false) { AnalyticsFormatting.cost($0) }
                        }
                    }
                }
            }
        }
    }

    private func comparisonRow(
        name: String,
        current: Double,
        baseline: Double,
        higherIsBetter: Bool,
        format: (Double) -> String
    ) -> some View {
        let delta = current - baseline
        let isBetter = higherIsBetter ? delta > 0 : delta < 0
        let isFlat = abs(delta) < 0.0001
        return HStack {
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(CorveilTheme.textSecondary)
            Spacer()
            Text(format(current))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            Image(systemName: isFlat ? "minus" : (delta > 0 ? "arrow.up" : "arrow.down"))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isFlat ? CorveilTheme.textMuted : (isBetter ? .green : .red))
            Text(format(baseline))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(CorveilTheme.textMuted)
        }
    }

    // MARK: Displayed, not graded

    private func displayedStatsSection(_ week: WeeklyScorecard) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("This Week (context only — not graded)")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)
                HStack(spacing: 12) {
                    StatChip(icon: "dollarsign.circle", label: "Cost",
                             value: AnalyticsFormatting.cost(week.totalCost))
                    StatChip(icon: "clock", label: "Active",
                             value: AnalyticsFormatting.time(week.activeTimeSeconds))
                    StatChip(icon: "arrow.up.circle", label: "Commits",
                             value: "\(week.commitCount)")
                    StatChip(icon: "arrow.triangle.2.circlepath", label: "Churn",
                             value: String(format: "%.2f", week.churnHint))
                    Spacer()
                }
            }
        }
    }

    // MARK: Prior weeks

    private func priorWeeksSection(_ weeks: [WeeklyScorecard]) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Previous Weeks")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)
                ForEach(weeks, id: \.weekStart) { week in
                    HStack {
                        Text(Self.weekRangeLabel(week.weekStart))
                            .font(.system(size: 12))
                            .foregroundStyle(CorveilTheme.textSecondary)
                        gradeBadge(week.result)
                        Spacer()
                        Text("\(week.sessionsShipped) shipped")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(CorveilTheme.textSecondary)
                        Text(AnalyticsFormatting.cost(week.totalCost))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(CorveilTheme.textMuted)
                    }
                }
            }
        }
    }

    // MARK: Per-session drill-down

    private func sessionsSection(_ rows: [SessionGradeRow]) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("This Week's Sessions")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)
                ForEach(rows) { row in
                    sessionRow(row)
                }
            }
        }
    }

    private func sessionRow(_ row: SessionGradeRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                gradeBadge(row.result)
                Text(row.endedAt, style: .date)
                    .font(.system(size: 12))
                    .foregroundStyle(CorveilTheme.textSecondary)
                if row.shipped {
                    Text("Shipped")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(AnalyticsFormatting.cost(row.analytics.totalCost))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(CorveilTheme.textMuted)
                Text(AnalyticsFormatting.time(row.analytics.activeTimeSeconds))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(CorveilTheme.textMuted)
                if let wallClock = row.wallClockDurationSeconds {
                    Text("(\(AnalyticsFormatting.time(wallClock)) wall)")
                        .font(.system(size: 11))
                        .foregroundStyle(CorveilTheme.textMuted)
                }
            }
            if case .graded(_, _, let deductions) = row.result, !deductions.isEmpty {
                Text(deductions.map { "\($0.label) −\($0.points)" }.joined(separator: "  ·  "))
                    .font(.caption2)
                    .foregroundStyle(CorveilTheme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func gradeBadge(_ result: EfficiencyGrading.GradeResult) -> some View {
        switch result {
        case .graded(_, let letter, _):
            Text(letter.rawValue)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 22, height: 22)
                .background(Self.gradeColor(letter).opacity(0.15))
                .foregroundStyle(Self.gradeColor(letter))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        case .insufficientData:
            Text("—")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 22, height: 22)
                .background(CorveilTheme.bgSurface)
                .foregroundStyle(CorveilTheme.textMuted)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .help("Insufficient data (fewer than \(EfficiencyGrading.Tuning.minimumGradablePromptCount) prompts)")
        }
    }

    // MARK: Shared bits

    private func card(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(CorveilTheme.bgCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(CorveilTheme.borderSubtle, lineWidth: 1)
                    )
            )
    }

    static func gradeColor(_ letter: EfficiencyGrading.LetterGrade) -> Color {
        switch letter {
        case .a: return .green
        case .b: return .mint
        case .c: return .yellow
        case .d: return .orange
        case .f: return .red
        }
    }

    /// One coachable sentence per metric, rendered under its deduction. Lives
    /// in the view layer: the compute layer's labels state the measurement,
    /// these state what to do about it.
    static func coachingHint(_ metric: EfficiencyGrading.Metric) -> String {
        switch metric {
        case .compactions:
            return "Compacting mid-session means the context filled — clear between tasks or split unrelated work."
        case .contextPressure:
            return "Heavy input per prompt suggests bloated context — reset more often or narrow what gets loaded."
        case .cacheHitRatio:
            return "Low cache reuse means context is re-sent as fresh input — steadier sessions cache better."
        case .apiErrorRate:
            return "Frequent API errors burn time and tokens — check connectivity, rate limits, or the agent setup."
        case .costPerShipped:
            return "High spend per shipped session — smaller scoped sessions that finish tend to cost less per outcome."
        }
    }

    static func weekRangeLabel(_ weekStart: Date) -> String {
        let end = weekStart.addingTimeInterval(6 * 86_400)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "Week of \(formatter.string(from: weekStart)) – \(formatter.string(from: end))"
    }
}
