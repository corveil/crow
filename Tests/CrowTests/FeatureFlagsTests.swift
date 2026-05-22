import Foundation
import Testing
@testable import Crow

/// Pin the env-var policy for `FeatureFlags.tmuxBackend`. As of #301 the tmux
/// backend is the default; the env var is parsed only as an explicit opt-out
/// (`0`/`false`/`no`/`off`). Anything else — including unset — means tmux is
/// on.
/// `.serialized` because `tmuxBackendOffWhenEnvExplicitlyOff` mutates the
/// process-global `CROW_TMUX_BACKEND` env var (setenv/unsetenv). Swift Testing
/// runs `@Test`s in parallel by default, so without serialization that mutation
/// can race `tmuxBackendDefaultIsOn` — which reads the same flag — and flip it
/// to `false` mid-assertion.
@Suite("FeatureFlags tmux backend default", .serialized)
struct FeatureFlagsTests {

    /// Mirror of the parsing rule in `FeatureFlags.envExplicitlyOff`. If the
    /// production rule changes, this helper must change too — that's the
    /// point: the test pins the policy.
    private func isExplicitlyOff(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.lowercased() {
        case "0", "false", "no", "off": return true
        default: return false
        }
    }

    @Test func recognizesCanonicalOffValues() {
        #expect(isExplicitlyOff("0"))
        #expect(isExplicitlyOff("false"))
        #expect(isExplicitlyOff("False"))
        #expect(isExplicitlyOff("FALSE"))
        #expect(isExplicitlyOff("no"))
        #expect(isExplicitlyOff("off"))
    }

    @Test func treatsEverythingElseAsDefault() {
        // Anything not in the explicit-off set keeps tmux on (default).
        #expect(!isExplicitlyOff(nil))
        #expect(!isExplicitlyOff(""))
        #expect(!isExplicitlyOff("1"))
        #expect(!isExplicitlyOff("true"))
        #expect(!isExplicitlyOff("yes"))
        #expect(!isExplicitlyOff("on"))
        #expect(!isExplicitlyOff(" 0 "))   // intentional: whitespace not trimmed
    }

    @Test func tmuxBackendDefaultIsOn() {
        // When the env var is unset (the common case in CI), the tmux
        // backend is on by default — that's the load-bearing policy
        // introduced in #301.
        if ProcessInfo.processInfo.environment["CROW_TMUX_BACKEND"] == nil {
            #expect(FeatureFlags.tmuxBackend)
        }
    }

    @Test func tmuxBackendOffWhenEnvExplicitlyOff() {
        // The env var is the escape hatch: an explicit-off value disables
        // the backend for the launch. We can't reliably mutate the live
        // environment from Swift Testing in CI, so skip when the env is
        // preset and only assert when we can write it ourselves.
        guard ProcessInfo.processInfo.environment["CROW_TMUX_BACKEND"] == nil else { return }
        setenv("CROW_TMUX_BACKEND", "0", 1)
        defer { unsetenv("CROW_TMUX_BACKEND") }
        #expect(!FeatureFlags.tmuxBackend)
    }
}
