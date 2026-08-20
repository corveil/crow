import Foundation
import Testing
@testable import CrowCore

/// A `ShellRunner` that answers from an injected closure and counts calls, for
/// unit-testing subprocess-backed logic without a real `gh`/`glab`.
actor ScriptedShellRunner: ShellRunner {
    let answer: @Sendable ([String]) -> Result<String, Error>
    private(set) var callCount = 0

    init(_ answer: @escaping @Sendable ([String]) -> Result<String, Error>) {
        self.answer = answer
    }

    func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        await bump()
        switch answer(args) {
        case .success(let out): return out
        case .failure(let err): throw err
        }
    }

    private func bump() { callCount += 1 }
    func calls() -> Int { callCount }
}

@Suite struct TicketValidatorTests {
    private let ghRemote = RepoRemote(host: "github.com", owner: "corveil", repo: "crow")

    @Test func classifiesIssue() async {
        let runner = ScriptedShellRunner { _ in .success(#"{"number": 12, "title": "x"}"#) }
        let v = TicketValidator(runner: runner)
        #expect(await v.validate(remote: ghRemote, number: 12) == .issue)
    }

    @Test func classifiesPullRequest() async {
        let runner = ScriptedShellRunner { _ in
            .success(#"{"number": 12, "pull_request": {"url": "..."}}"#)
        }
        let v = TicketValidator(runner: runner)
        #expect(await v.validate(remote: ghRemote, number: 12) == .pullRequest)
    }

    @Test func cleanNotFoundIsNotFound() async {
        let runner = ScriptedShellRunner { _ in
            .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "gh: Not Found (HTTP 404)"))
        }
        let v = TicketValidator(runner: runner)
        #expect(await v.validate(remote: ghRemote, number: 999) == .notFound)
    }

    @Test func otherErrorIsInconclusive() async {
        // An auth/network failure must NOT be reported as not-found (that would
        // suppress a real link); it's inconclusive so the caller uploads repo-only.
        let runner = ScriptedShellRunner { _ in
            .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "error connecting to api.github.com"))
        }
        let v = TicketValidator(runner: runner)
        #expect(await v.validate(remote: ghRemote, number: 12) == .unvalidated)
    }

    @Test func cachesPerTicket() async {
        let runner = ScriptedShellRunner { _ in .success(#"{"number": 12}"#) }
        let v = TicketValidator(runner: runner)
        _ = await v.validate(remote: ghRemote, number: 12)
        _ = await v.validate(remote: ghRemote, number: 12)
        #expect(await runner.calls() == 1)
    }

    @Test func passesHostnameForEnterpriseHost() async {
        let runner = ScriptedShellRunner { args in
            // Enterprise host must be passed via --hostname.
            args.contains("--hostname") && args.contains("github.acme.com")
                ? .success(#"{"number": 5}"#)
                : .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "Not Found"))
        }
        let v = TicketValidator(runner: runner)
        let ent = RepoRemote(host: "github.acme.com", owner: "o", repo: "r")
        #expect(await v.validate(remote: ent, number: 5) == .issue)
    }

    @Test func classifyGitHubHelper() {
        #expect(TicketValidator.classifyGitHub(json: #"{"number": 1}"#) == .issue)
        #expect(TicketValidator.classifyGitHub(json: #"{"number": 1, "pull_request": {}}"#) == .pullRequest)
        #expect(TicketValidator.classifyGitHub(json: #"{"message": "Not Found"}"#) == .unvalidated)
        #expect(TicketValidator.classifyGitHub(json: "garbage") == .unvalidated)
    }
}
