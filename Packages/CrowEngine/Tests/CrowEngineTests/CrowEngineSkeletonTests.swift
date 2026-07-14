import Testing
@testable import CrowEngine

// Placeholder so the CrowEngineTests target compiles from the package skeleton
// on. Real engine tests move in here in lockstep as their types migrate
// (CROW-581 Milestone A). The daemon-side smoke test (makeEngineRouter +
// NoopHostBridge) lands in A7.
@Suite("CrowEngine skeleton")
@MainActor
struct CrowEngineSkeletonTests {
    @Test("NoopHostBridge is constructible and inert")
    func noopHostBridge() {
        _ = NoopHostBridge()
    }
}
