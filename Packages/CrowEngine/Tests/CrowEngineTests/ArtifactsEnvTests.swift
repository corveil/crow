import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// The whole artifact loop only works if the path an agent is told to WRITE to
/// (the injected env) is the same path the daemon SERVES from. Both derive from
/// `CrowCore.ArtifactPaths`, so pin that they agree, and that the scaffolded
/// skill points at the same env var (CROW-593).
@Suite struct ArtifactsEnvTests {
    @Test func injectedEnvMatchesArtifactPaths() {
        let id = UUID()
        let env = SessionService.artifactsEnv(sessionID: id)
        #expect(env["CROW_SESSION_ID"] == id.uuidString)
        #expect(env["CROW_ARTIFACTS_DIR"] == ArtifactPaths.dir(sessionID: id).path)
    }

    @Test func showImageSkillIsBundledAndReferencesTheEnv() {
        let body = Scaffolder.bundledShowImageSkill()
        #expect(body.contains("name: crow-show-image"))
        #expect(body.contains("CROW_ARTIFACTS_DIR"))
    }
}
