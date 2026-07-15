import Foundation
import Testing
@testable import CrowCore

// CROW-733: changing the per-action agent (e.g. "Agent for scheduled jobs")
// must apply to the very next launched session without an app restart or a
// config reload from disk. Jobs resolve their agent live via
// `AppState.agentKind(for:)`, so the invariant under test is that
// `AppState.applyAgentConfig(_:)` — the single choke point every config→state
// sync site funnels through — makes the just-saved value observable immediately.

@MainActor @Test func applyAgentConfigPropagatesJobOverrideUpdateWithoutReload() {
    let state = AppState()
    var config = AppConfig()

    // First selection: Cursor for jobs.
    config.agentsByKind["job"] = .cursor
    state.applyAgentConfig(config)
    #expect(state.agentKind(for: .job) == .cursor)

    // Re-select in the same running app (no disk reload): Claude Code.
    config.agentsByKind["job"] = .claudeCode
    state.applyAgentConfig(config)
    #expect(state.agentKind(for: .job) == .claudeCode)
}

@MainActor @Test func applyAgentConfigClearingJobOverrideFallsBackToDefault() {
    let state = AppState()
    var config = AppConfig()

    // Override in place → resolves to the override.
    config.defaultAgentKind = .claudeCode
    config.agentsByKind["job"] = .cursor
    state.applyAgentConfig(config)
    #expect(state.agentKind(for: .job) == .cursor)

    // "Use default" removes the override → resolves to defaultAgentKind.
    config.agentsByKind.removeValue(forKey: "job")
    state.applyAgentConfig(config)
    #expect(state.agentKind(for: .job) == .claudeCode)
    #expect(state.agentsByKind["job"] == nil)
}

@MainActor @Test func applyAgentConfigPropagatesDefaultAgentChange() {
    let state = AppState()
    var config = AppConfig()

    // No per-kind override → resolution tracks defaultAgentKind.
    config.defaultAgentKind = .cursor
    state.applyAgentConfig(config)
    #expect(state.agentKind(for: .job) == .cursor)

    config.defaultAgentKind = .claudeCode
    state.applyAgentConfig(config)
    #expect(state.agentKind(for: .job) == .claudeCode)
}
