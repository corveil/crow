import Foundation
import Testing
@testable import CrowCore

// #696: the normalized priority ladder and its Jira-name mapper.

@Test func ticketPriorityMapsModernJiraLadder() {
    #expect(TicketPriority(jiraName: "Highest") == .highest)
    #expect(TicketPriority(jiraName: "High") == .high)
    #expect(TicketPriority(jiraName: "Medium") == .medium)
    #expect(TicketPriority(jiraName: "Low") == .low)
    #expect(TicketPriority(jiraName: "Lowest") == .lowest)
}

@Test func ticketPriorityMapsClassicJiraScheme() {
    #expect(TicketPriority(jiraName: "Blocker") == .highest)
    #expect(TicketPriority(jiraName: "Critical") == .high)
    #expect(TicketPriority(jiraName: "Major") == .medium)
    #expect(TicketPriority(jiraName: "Minor") == .low)
    #expect(TicketPriority(jiraName: "Trivial") == .lowest)
}

@Test func ticketPriorityMappingIsCaseInsensitive() {
    #expect(TicketPriority(jiraName: "HIGHEST") == .highest)
    #expect(TicketPriority(jiraName: "critical") == .high)
    #expect(TicketPriority(jiraName: "mEdIuM") == .medium)
}

// Custom per-project priority schemes normalize to .unknown (neutral weight);
// the raw name is preserved separately on the models for inspection.
@Test func ticketPriorityUnrecognizedAndNilAreUnknown() {
    #expect(TicketPriority(jiraName: "P0 — Drop Everything") == .unknown)
    #expect(TicketPriority(jiraName: "") == .unknown)
    #expect(TicketPriority(jiraName: nil) == .unknown)
}

@Test func ticketPriorityRawValueRoundTrip() throws {
    for priority in TicketPriority.allCases {
        #expect(TicketPriority(rawValue: priority.rawValue) == priority)
        // The mapper also accepts raw values, so CLI input maps directly.
        if priority != .unknown {
            #expect(TicketPriority(jiraName: priority.rawValue) == priority)
        }
        let data = try JSONEncoder().encode([priority])
        let decoded = try JSONDecoder().decode([TicketPriority].self, from: data)
        #expect(decoded == [priority])
    }
}
