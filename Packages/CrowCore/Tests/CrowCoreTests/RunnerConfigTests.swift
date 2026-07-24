import Foundation
import Testing
@testable import CrowCore

/// `RunnerConfig` (corveil/crow#801): forward-compatible decoding, the
/// env-sourced API key (never a config field), worker-id defaulting, and the
/// clamped concurrency/poll knobs.
@Suite("RunnerConfig")
struct RunnerConfigTests {
    @Test func decodesWithDefaultsForMissingKeys() throws {
        let json = Data("{}".utf8)
        let config = try JSONDecoder().decode(RunnerConfig.self, from: json)
        #expect(config.enabled == false)
        #expect(config.corveilURL == "")
        #expect(config.caps.isEmpty)
        #expect(config.kinds.isEmpty)
        #expect(config.maxConcurrentRuns == 1)
        #expect(config.pollIntervalSeconds == 30)
    }

    @Test func decodesProvidedFields() throws {
        let json = Data(#"""
        {"enabled":true,"corveilURL":"https://corveil.acme.io","workerID":"crow-box-2",
         "caps":["ontology-write"],"kinds":["tend","summarize"],
         "maxConcurrentRuns":4,"pollIntervalSeconds":15}
        """#.utf8)
        let config = try JSONDecoder().decode(RunnerConfig.self, from: json)
        #expect(config.enabled)
        #expect(config.corveilURL == "https://corveil.acme.io")
        #expect(config.workerID == "crow-box-2")
        #expect(config.caps == ["ontology-write"])
        #expect(config.kinds == ["tend", "summarize"])
        #expect(config.maxConcurrentRuns == 4)
        #expect(config.pollIntervalSeconds == 15)
    }

    @Test func hasNoAPIKeyField() throws {
        // The org secret must never round-trip through config.json.
        let config = RunnerConfig(enabled: true, corveilURL: "u")
        let data = try JSONEncoder().encode(config)
        let json = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!json.contains("apikey"))
        #expect(!json.contains("api_key"))
        #expect(!json.contains("corveil_api_key"))
    }

    @Test func resolvedWorkerIDUsesConfiguredValue() {
        let config = RunnerConfig(workerID: "  crow-custom-7  ")
        #expect(config.resolvedWorkerID(hostName: "ignored") == "crow-custom-7")
    }

    @Test func resolvedWorkerIDDefaultsFromHostname() {
        let config = RunnerConfig(workerID: "")
        #expect(config.resolvedWorkerID(hostName: "Janes-MacBook.local") == "crow-janes-macbook-1")
    }

    @Test func slugHostNormalizes() {
        #expect(RunnerConfig.slugHost("Build.Box_02.local") == "build-box-02")
        #expect(RunnerConfig.slugHost("") == "host")
    }

    @Test func concurrencyAndPollAreClamped() {
        let config = RunnerConfig(maxConcurrentRuns: 0, pollIntervalSeconds: 1)
        #expect(config.effectiveMaxConcurrentRuns == 1)   // never below 1
        #expect(config.effectivePollIntervalSeconds == 5) // never below 5
    }

    @Test func decodesAsPartOfAppConfig() throws {
        let json = Data(#"{"runner":{"enabled":true,"kinds":["tend"]}}"#.utf8)
        let appConfig = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(appConfig.runner?.enabled == true)
        #expect(appConfig.runner?.kinds == ["tend"])
    }

    @Test func appConfigWithoutRunnerBlockDecodesNil() throws {
        let appConfig = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(appConfig.runner == nil)
    }
}
