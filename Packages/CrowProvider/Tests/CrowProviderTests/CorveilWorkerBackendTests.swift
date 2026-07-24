import XCTest
import CrowCore
@testable import CrowProvider

/// Exercises `CorveilWorkerBackend` against `FakeShellRunner` (reused from
/// `BackendsTests`) — the ADR 0005 testability bar. Asserts the exact `corveil
/// worker-run` argv + env for each verb plus JSON parsing and the typed error
/// mapping, without spawning real `corveil` (corveil/crow#801).
final class CorveilWorkerBackendTests: XCTestCase {

    private let config = CorveilWorkerConfig(url: "https://corveil.acme.io", apiKey: "sk-test-123")

    private func backend(_ fake: FakeShellRunner) -> CorveilWorkerBackend {
        CorveilWorkerBackend(shellRunner: fake, config: config)
    }

    // MARK: - Credentials as env

    func testPassesCorveilURLAndAPIKeyAsEnv() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("[]")]
        _ = try await backend(fake).listClaimable(kind: nil, caps: [])
        let call = try XCTUnwrap(fake.calls.first)
        XCTAssertEqual(call.env["CORVEIL_URL"], "https://corveil.acme.io")
        XCTAssertEqual(call.env["CORVEIL_API_KEY"], "sk-test-123")
    }

    func testEmptyCredentialsAreOmittedFromEnv() {
        let empty = CorveilWorkerConfig(url: "", apiKey: "")
        XCTAssertTrue(empty.env.isEmpty)
        XCTAssertFalse(empty.hasAPIKey)
        XCTAssertTrue(CorveilWorkerConfig(url: "u", apiKey: "k").hasAPIKey)
    }

    // MARK: - list

    func testListClaimableBuildsClaimableArgvWithKindAndCaps() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"[{"id":"r1","kind":"tend-ontology","status":"queued"}]"#)]
        let runs = try await backend(fake).listClaimable(kind: "tend-ontology", caps: ["ontology-write", "search"])

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.id, "r1")
        XCTAssertEqual(runs.first?.kind, "tend-ontology")

        let args = try XCTUnwrap(fake.calls.first?.args)
        XCTAssertEqual(Array(args.prefix(4)), ["corveil", "worker-run", "list", "--claimable"])
        XCTAssertTrue(args.contains("--json"))
        XCTAssertEqual(args[args.firstIndex(of: "--kind")! + 1], "tend-ontology")
        // caps are comma-joined into a single flag value.
        XCTAssertEqual(args[args.firstIndex(of: "--caps")! + 1], "ontology-write,search")
    }

    func testListClaimableOmitsKindAndCapsWhenEmpty() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("[]")]
        _ = try await backend(fake).listClaimable(kind: nil, caps: [])
        let args = try XCTUnwrap(fake.calls.first?.args)
        // Passing an empty caps array must NOT send `--caps` (that would opt into
        // the "no-cap runs only" subset filter).
        XCTAssertFalse(args.contains("--caps"))
        XCTAssertFalse(args.contains("--kind"))
    }

    func testListToleratesRunsWrapperObject() {
        let runs = CorveilWorkerBackend.parseRuns(#"{"runs":[{"id":"a"},{"id":"b"}]}"#)
        XCTAssertEqual(runs.map(\.id), ["a", "b"])
    }

    // MARK: - get / claim

    func testGetParsesFullSnapshot() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"""
        {"id":"r7","kind":"tend","prompt_title":"Tidy","prompt_body":"Do the thing",
         "required_caps":["ontology-write"],
         "writeback_policy":{"ontology":{"allowed":["ontology_update_entity"],"dry_run":false}},
         "status":"claimed","claim":{"worker_id":"crow-host-1","lease_expires_at":"2026-07-24T00:00:00Z"}}
        """#)]
        let run = try await backend(fake).get("r7")
        XCTAssertEqual(run.promptBody, "Do the thing")
        XCTAssertEqual(run.requiredCaps, ["ontology-write"])
        XCTAssertEqual(run.writebackPolicy?["ontology"]?.allowed, ["ontology_update_entity"])
        XCTAssertEqual(run.writebackPolicy?["ontology"]?.dryRun, false)
        XCTAssertEqual(run.claim?.workerID, "crow-host-1")

        let args = try XCTUnwrap(fake.calls.first?.args)
        XCTAssertEqual(Array(args.prefix(3)), ["corveil", "worker-run", "get"])
        XCTAssertTrue(args.contains("r7"))
    }

    func testClaimBuildsArgvWithWorkerIDAndLease() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"{"id":"r1","status":"claimed","claim":{"worker_id":"w1"}}"#)]
        let run = try await backend(fake).claim("r1", workerID: "w1", leaseSeconds: 1800)
        XCTAssertEqual(run.status, "claimed")

        let args = try XCTUnwrap(fake.calls.first?.args)
        XCTAssertEqual(Array(args.prefix(3)), ["corveil", "worker-run", "claim"])
        XCTAssertEqual(args[args.firstIndex(of: "--worker-id")! + 1], "w1")
        XCTAssertEqual(args[args.firstIndex(of: "--lease-seconds")! + 1], "1800")
    }

    func testClaimMapsConflictToUnclaimable() async {
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: #"{"code":"conflict","message":"already claimed"}"#))]
        do {
            _ = try await backend(fake).claim("r1", workerID: "w1", leaseSeconds: 1800)
            XCTFail("expected throw")
        } catch WorkerRunError.unclaimable {
            // expected
        } catch {
            XCTFail("expected unclaimable, got \(error)")
        }
    }

    // MARK: - heartbeat

    func testHeartbeatBuildsArgv() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("{}")]
        try await backend(fake).heartbeat("r1", workerID: "w1", leaseSeconds: 900)
        let args = try XCTUnwrap(fake.calls.first?.args)
        XCTAssertEqual(Array(args.prefix(3)), ["corveil", "worker-run", "heartbeat"])
        XCTAssertEqual(args[args.firstIndex(of: "--worker-id")! + 1], "w1")
        XCTAssertEqual(args[args.firstIndex(of: "--lease-seconds")! + 1], "900")
    }

    // MARK: - complete

    func testCompleteSuccessSendsTitleContentOutputNotError() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("{}")]
        try await backend(fake).complete(
            "r1", workerID: "w1",
            title: "Did it", content: "changed 3 entities", output: #"{"entities_written":3}"#, error: nil
        )
        let args = try XCTUnwrap(fake.calls.first?.args)
        XCTAssertEqual(Array(args.prefix(3)), ["corveil", "worker-run", "complete"])
        XCTAssertEqual(args[args.firstIndex(of: "--title")! + 1], "Did it")
        XCTAssertEqual(args[args.firstIndex(of: "--content")! + 1], "changed 3 entities")
        XCTAssertEqual(args[args.firstIndex(of: "--output")! + 1], #"{"entities_written":3}"#)
        XCTAssertFalse(args.contains("--error"))
    }

    func testCompleteWithErrorSendsErrorAndSkipsTitle() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("{}")]
        try await backend(fake).complete(
            "r1", workerID: "w1",
            title: "ignored", content: "ignored", output: "{}", error: "it broke"
        )
        let args = try XCTUnwrap(fake.calls.first?.args)
        XCTAssertEqual(args[args.firstIndex(of: "--error")! + 1], "it broke")
        XCTAssertFalse(args.contains("--title"))
        XCTAssertFalse(args.contains("--content"))
    }

    // MARK: - error classification

    func testClassifyFeatureDisabled() {
        XCTAssertEqual(CorveilWorkerBackend.classify(#"{"code":"feature_disabled"}"#), .featureDisabled)
    }

    func testClassifyUnauthenticated() {
        XCTAssertEqual(CorveilWorkerBackend.classify("please run corveil login"), .unauthenticated)
        XCTAssertEqual(CorveilWorkerBackend.classify("HTTP 401 unauthorized"), .unauthenticated)
    }

    func testClassifyFallsBackToCommandFailed() {
        XCTAssertEqual(CorveilWorkerBackend.classify("some other boom"), .commandFailed("some other boom"))
    }

    func testFeatureDisabledSurfacesFromList() async {
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "feature_disabled"))]
        do {
            _ = try await backend(fake).listClaimable(kind: nil, caps: [])
            XCTFail("expected throw")
        } catch WorkerRunError.featureDisabled {
            // expected
        } catch {
            XCTFail("expected featureDisabled, got \(error)")
        }
    }
}
