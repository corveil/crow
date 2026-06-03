import Foundation
import CrowCore

/// `TaskBackend` stub for Corveil — present to prove the abstraction holds for a
/// third provider, not to ship behavior. Every method throws
/// `ProviderError.unimplemented`. See ADR 0005.
///
/// Corveil has no embedded git, so there is intentionally no `StubCorveilCodeBackend`:
/// a Corveil-tasked session pairs with a `.github` or `.gitlab` `CodeBackend`. Once a
/// real Corveil API integration lands, this stub is replaced; a `Session.codeProvider`
/// field (separate follow-up) lets the two halves come from different providers.
public struct StubCorveilTaskBackend: TaskBackend {
    public let provider: Provider = .corveil
    public let capabilities: Set<TaskCapability> = []

    public init() {}

    public func fetchTask(url: String) async throws -> TicketInfo {
        throw ProviderError.unimplemented("StubCorveilTaskBackend.fetchTask")
    }

    public func setLabels(url: String, add: [String], remove: [String]) async throws {
        throw ProviderError.unimplemented("StubCorveilTaskBackend.setLabels")
    }

    public func setTaskStatus(url: String, status: TicketStatus) async throws {
        throw ProviderError.unimplemented("StubCorveilTaskBackend.setTaskStatus")
    }
}
