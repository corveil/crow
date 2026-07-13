import Foundation
import Testing
@testable import CrowCore

// #696 (ADR 0008 follow-up 8, category C): the alignment-weight priors. The
// weight is the future v2 multiplicand — these tests lock in the rubric's
// required ordering and the no-regression neutral floor, not a live score.

// The ordering the rubric requires: demonstrated alignment beats weaker
// demonstrated alignment beats no alignment data at all.
@Test func alignmentWeightRequiredOrdering() {
    let highOnGoal = AlignmentWeight.weight(priority: .high, hasOrgGoal: true)
    let lowOffGoal = AlignmentWeight.weight(priority: .low, hasOrgGoal: false)
    let untagged = AlignmentWeight.weight(priority: nil, hasOrgGoal: false)
    #expect(highOnGoal > lowOffGoal)
    #expect(lowOffGoal > untagged)
    // The neutral floor is exact: every pre-#696 session computes this value,
    // so the capture cannot regress existing scores.
    #expect(untagged == AlignmentWeight.neutral)
    #expect(untagged == 1.0)
}

// nil priority and .unknown are the same neutral base — a tracker without a
// priority concept must not grade differently from an unrecognized name.
@Test func alignmentWeightNilAndUnknownAreNeutral() {
    #expect(AlignmentWeight.weight(priority: .unknown, hasOrgGoal: false) == AlignmentWeight.neutral)
    #expect(AlignmentWeight.weight(priority: nil, hasOrgGoal: false)
        == AlignmentWeight.weight(priority: .unknown, hasOrgGoal: false))
}

// Bonus-above-neutral scheme: any explicit priority signal sits above the
// untagged floor (absence of data is never punished, presence always counts).
@Test func alignmentWeightEveryExplicitRungBeatsNeutral() {
    for priority in TicketPriority.allCases where priority != .unknown {
        #expect(AlignmentWeight.weight(priority: priority, hasOrgGoal: false) > AlignmentWeight.neutral)
    }
}

// The priority ladder is strictly monotonic, on- and off-goal.
@Test func alignmentWeightLadderIsMonotonic() {
    let ladder: [TicketPriority] = [.lowest, .low, .medium, .high, .highest]
    for hasGoal in [false, true] {
        let weights = ladder.map { AlignmentWeight.weight(priority: $0, hasOrgGoal: hasGoal) }
        #expect(weights == weights.sorted())
        #expect(Set(weights).count == weights.count)
    }
}

// A goal tag alone (no priority signal — e.g. a GitHub-tasked session) earns
// exactly the on-goal multiplier over neutral.
@Test func alignmentWeightGoalOnlyEarnsMultiplier() {
    #expect(AlignmentWeight.weight(priority: nil, hasOrgGoal: true)
        == AlignmentWeight.neutral * AlignmentWeight.onGoalMultiplier)
}

// The weight is priorityBase × goalMultiplier — lock in the compositional
// shape the v2 score consumes (follow-up 11).
@Test func alignmentWeightComposesMultiplicatively() {
    for priority in TicketPriority.allCases {
        let off = AlignmentWeight.weight(priority: priority, hasOrgGoal: false)
        let on = AlignmentWeight.weight(priority: priority, hasOrgGoal: true)
        #expect(on == off * AlignmentWeight.onGoalMultiplier)
    }
}

// Session-level derivation: the computed property feeds from ticketPriority +
// orgGoal, and a blank/whitespace goal cannot buy the multiplier.
@Test func sessionAlignmentWeightDerivesFromPriorityAndGoal() {
    var session = Session(name: "s")
    #expect(session.alignmentWeight == AlignmentWeight.neutral)

    session.ticketPriority = .high
    session.orgGoal = "Q3 latency KPI"
    #expect(session.alignmentWeight
        == AlignmentWeight.weight(priority: .high, hasOrgGoal: true))

    session.orgGoal = "   "
    #expect(session.alignmentWeight
        == AlignmentWeight.weight(priority: .high, hasOrgGoal: false))
}
