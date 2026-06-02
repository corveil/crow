import Foundation

/// A normalized hook event delivered from an agent's runtime (e.g. a Claude
/// Code hook) into the state pipeline.
///
/// Only the fields the state machine and notification layer actually consume
/// are modeled here; the raw payload lives in the RPC layer and is flattened
/// into this struct before it crosses the `StateSignalSource` boundary. Keeps
/// `CrowCore` free of a JSON-value dependency.
public struct AgentHookEvent: Sendable {
    public let sessionID: UUID
    public let eventName: String
    public let toolName: String?
    public let source: String?
    public let message: String?
    public let notificationType: String?
    public let agentType: String?
    public let summary: String

    public init(
        sessionID: UUID,
        eventName: String,
        toolName: String? = nil,
        source: String? = nil,
        message: String? = nil,
        notificationType: String? = nil,
        agentType: String? = nil,
        summary: String
    ) {
        self.sessionID = sessionID
        self.eventName = eventName
        self.toolName = toolName
        self.source = source
        self.message = message
        self.notificationType = notificationType
        self.agentType = agentType
        self.summary = summary
    }
}
