import Foundation

/// Alignment-weight priors (ADR 0008 follow-up 8, category C: does the work
/// ladder up to an org KPI/goal). The weight is the alignment multiplicand of
/// the v2 combined score (follow-up 11, #699): `CombinedScore` sums it over a
/// week's shipped snapshots to form the alignment-weighted throughput factor.
/// This type only *produces* the value.
///
/// Scheme: bonus-above-neutral. Untagged/unknown work scores exactly
/// `neutral` (1.0), so every pre-existing session is unaffected; any explicit
/// priority signal sits above the neutral floor, and an org-goal tag
/// multiplies on top. That yields the ordering the rubric requires:
/// high-priority on-goal (1.3 × 1.5 = 1.95) > low-priority off-goal (1.1) >
/// untagged-neutral (1.0). Demonstrated alignment is rewarded; absence of
/// data is never punished (trackers without priorities shouldn't grade worse).
///
/// These constants are tunable priors in the ADR 0008 sense, not gospel —
/// revisit once real scorecard data exists.
public enum AlignmentWeight {
    /// Weight for work with no priority and no org-goal tag. Also the exact
    /// value every session created before #696 computes to.
    public static let neutral: Double = 1.0
    /// Multiplier applied when the session carries an org-goal tag.
    public static let onGoalMultiplier: Double = 1.5

    public static let lowestPriorityBase: Double = 1.05
    public static let lowPriorityBase: Double = 1.1
    public static let mediumPriorityBase: Double = 1.2
    public static let highPriorityBase: Double = 1.3
    public static let highestPriorityBase: Double = 1.4

    /// Compute the alignment weight for a piece of work.
    /// `nil` priority and `.unknown` are both the neutral base.
    public static func weight(priority: TicketPriority?, hasOrgGoal: Bool) -> Double {
        base(for: priority) * (hasOrgGoal ? onGoalMultiplier : 1.0)
    }

    private static func base(for priority: TicketPriority?) -> Double {
        switch priority {
        case .highest: return highestPriorityBase
        case .high: return highPriorityBase
        case .medium: return mediumPriorityBase
        case .low: return lowPriorityBase
        case .lowest: return lowestPriorityBase
        case .unknown, .none: return neutral
        }
    }
}
