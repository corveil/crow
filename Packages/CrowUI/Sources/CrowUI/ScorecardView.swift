import SwiftUI
import CrowCore

// MARK: - Scorecard View (ADR 0008, #710 v1 + #699 v2 combined score)

/// Full-pane private efficiency scorecard: the weekly A–F grade with its
/// coachable deductions, the sessions-shipped throughput count, the v2
/// combined multiplicative score, and the self-comparison against the user's
/// own trailing 4-week median. Read-only — computed from the persisted
/// snapshots mirrored on `appState.analyticsSnapshots` plus the PR
/// attributions on `appState.prAttributions`. The grade and the shipped count
/// remain separate surfaces; the combined score is an additional card that
/// decomposes into its factors rather than replacing either.
public struct ScorecardView: View {
    @Bindable var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    private var model: ScorecardModel {
        ScorecardModel.build(
            snapshots: Array(appState.analyticsSnapshots.values),
            attributions: Array(appState.prAttributions.values),
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
            // Manager-only data still shows the content pane: the grade card
            // renders "insufficient data" gracefully with zero snapshots, and
            // hiding captured Manager usage behind the empty state would
            // repeat the invisibility this gate is meant to fix (#745).
            if appState.analyticsSnapshots.isEmpty && appState.managerUsageWeekly.isEmpty {
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

            Text(captureStatusText)
                .font(.caption)
                .foregroundStyle(CorveilTheme.textMuted)

            Spacer()

            Text(Self.weekRangeLabel(model.currentWeek.weekStart))
                .font(.caption)
                .foregroundStyle(CorveilTheme.textSecondary)

            rebuildButton
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(CorveilTheme.bgSurface)
    }

    /// One-line telemetry capture health (#745), shared by the header and the
    /// empty state. Nil `telemetryCaptureStatus` means telemetry is disabled
    /// or hasn't started this launch.
    private var captureStatusText: String {
        guard let status = appState.telemetryCaptureStatus else {
            return "Telemetry not capturing — enable it in Settings, then restart Crow"
        }
        return "Telemetry capturing — \(status.sessionCount) session\(status.sessionCount == 1 ? "" : "s") recorded"
    }

    /// Manual backfill from telemetry.db (#745): rebuilds snapshots for
    /// sessions recorded before snapshotting existed, without re-running them.
    @ViewBuilder
    private var rebuildButton: some View {
        if appState.onRebuildScorecard != nil {
            Button {
                Task { await appState.onRebuildScorecard?() }
            } label: {
                if appState.isRebuildingScorecard {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Rebuild", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
            }
            .disabled(appState.isRebuildingScorecard)
            .help("Rebuild scorecard data from the local telemetry database")
        }
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

                combinedCard(model.currentWeek)
                baselineSection(model)
                displayedStatsSection(model.currentWeek)

                if !appState.managerUsageWeekly.isEmpty {
                    managerUsageSection
                }

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
            Label("No Scorecard Data Yet", systemImage: "chart.bar.xaxis")
        } description: {
            VStack(spacing: 8) {
                Text("The scorecard grades regular sessions from analytics snapshots. To get data here: enable Claude Code telemetry in Settings and restart Crow, run a non-Manager session, then mark it Completed or Archived. A weekly grade needs at least \(EfficiencyGrading.Tuning.minimumGradablePromptCount) prompts. The Manager session is never graded — its usage appears in its own ungraded section once captured.")
                Text(captureStatusText)
                    .foregroundStyle(CorveilTheme.textSecondary)
                if appState.analyticsSnapshotSkipCount > 0 {
                    Text("\(appState.analyticsSnapshotSkipCount) session completion\(appState.analyticsSnapshotSkipCount == 1 ? "" : "s") this launch had no telemetry data to snapshot.")
                        .foregroundStyle(CorveilTheme.textMuted)
                }
            }
        } actions: {
            if appState.onRebuildScorecard != nil {
                VStack(spacing: 6) {
                    rebuildButton
                    Text("Sessions already recorded in the local telemetry database can be rebuilt into the scorecard without re-running them.")
                        .font(.caption2)
                        .foregroundStyle(CorveilTheme.textMuted)
                }
            }
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

    // MARK: Combined score (ADR 0008 v2, #699)

    /// The v2 multiplicative score, always shown WITH its decomposition —
    /// the number is only trustworthy while it stays explainable.
    private func combinedCard(_ week: WeeklyScorecard) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Combined Score (v2)")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)

                switch week.combined {
                case .scored(let factors):
                    Text(String(format: "%.1f", factors.value))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(CorveilTheme.gold)

                    Text("\(factors.shippedCount) shipped × \(String(format: "%.2f", factors.alignmentFactor)) alignment × \(String(format: "%.2f", factors.efficiencyMultiplier)) efficiency")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()

                    Text("efficiency = grade \(factors.gradeScore)/100 × hygiene \(String(format: "%.2f", factors.hygieneFactor))\(Self.hygieneDetail(factors.rework))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(CorveilTheme.textMuted)

                    Text("Alignment-weighted throughput × efficiency, weekly grain — bad hygiene multiplies the score down and can't be bought back with volume. Same private self-comparison posture and tunable priors as the grade.")
                        .font(.caption2)
                        .foregroundStyle(CorveilTheme.textMuted)
                case .insufficientData(let prompts):
                    insufficientDataBlock(prompts: prompts)
                }
            }
        }
    }

    /// Compact rework readout appended to the hygiene line — empty when the
    /// week has no rework signals, so a clean week reads clean.
    static func hygieneDetail(_ rework: CombinedScore.WeeklyRework) -> String {
        var parts: [String] = []
        if rework.revertCount > 0 {
            parts.append("\(rework.revertCount) revert\(rework.revertCount == 1 ? "" : "s")")
        }
        if rework.postMergeFixCount > 0 {
            parts.append("\(rework.postMergeFixCount) post-merge fix\(rework.postMergeFixCount == 1 ? "" : "es")")
        }
        if let mergeRate = rework.mergeRate, mergeRate < 1 {
            parts.append(String(format: "%.0f%% merge rate", mergeRate * 100))
        }
        return parts.isEmpty ? "" : "  (\(parts.joined(separator: ", ")))"
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
                        if let median = baseline.medianCombinedScore,
                           case .scored(let factors) = model.currentWeek.combined {
                            comparisonRow(
                                name: "Combined score", current: factors.value, baseline: median,
                                higherIsBetter: true) { String(format: "%.1f", $0) }
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

    // MARK: Manager usage (ungraded bucket, #745)

    /// Weekly telemetry rollups for the always-on Manager session, shown for
    /// visibility only — never graded and never part of the baseline
    /// (ADR 0008 addendum). View-local formatting over the persisted mirror;
    /// deliberately not routed through `ScorecardModel`, which stays pure
    /// over completion snapshots.
    private var managerUsageSection: some View {
        let weeks = appState.managerUsageWeekly.values
            .sorted { $0.weekStart > $1.weekStart }
        return card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Manager Usage (ungraded)")
                    .font(.caption)
                    .foregroundStyle(CorveilTheme.textSecondary)
                ForEach(weeks, id: \.weekStart) { week in
                    HStack {
                        Text(Self.weekRangeLabel(week.weekStart))
                            .font(.system(size: 12))
                            .foregroundStyle(CorveilTheme.textSecondary)
                        Spacer()
                        Text("\(week.analytics.promptCount) prompt\(week.analytics.promptCount == 1 ? "" : "s")")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(CorveilTheme.textSecondary)
                        Text("\(AnalyticsFormatting.count(week.analytics.totalTokens)) tokens")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(CorveilTheme.textMuted)
                        Text(AnalyticsFormatting.cost(week.analytics.totalCost))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(CorveilTheme.textMuted)
                    }
                }
                Text("The always-on Manager session never completes, so its usage is tracked here directly from telemetry — visibility only, never graded.")
                    .font(.caption2)
                    .foregroundStyle(CorveilTheme.textMuted)
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
                        Text({
                            if case .scored(let factors) = week.combined {
                                return String(format: "%.1f", factors.value)
                            }
                            return "—"
                        }())
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(CorveilTheme.textMuted)
                            .help("Combined score (v2)")
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
