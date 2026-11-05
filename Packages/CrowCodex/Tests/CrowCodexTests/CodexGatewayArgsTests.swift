import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

/// CROW-1407: routing Codex through a workspace's Corveil gateway.
@Suite("CodexGatewayArgs")
struct CodexGatewayArgsTests {
    private static let key = "sk-citadel-SECRET-do-not-leak"

    private func gateway(
        base: String = "https://corveil.io",
        headers: [String: String] = ["x-citadel-api-key": key],
        codex: CodexUpstream? = .chatgptCodex
    ) -> WorkspaceGateway {
        WorkspaceGateway(baseURL: base, customHeaders: headers, codexUpstream: codex)
    }

    private func route(_ g: WorkspaceGateway?, auth: CodexGatewayArgs.AuthMode? = nil)
        -> Result<CodexGatewayArgs.Route, CodexGatewayArgs.Skip> {
        CodexGatewayArgs.route(for: g, authMode: { auth })
    }

    // MARK: - route

    @Test func optedInCorveilGatewayRoutesWithV1Suffix() {
        #expect(route(gateway()) == .success(.init(baseURL: "https://corveil.io/v1", upstream: "chatgpt_codex")))
        #expect(route(gateway(base: "https://corveil.io/")) == .success(.init(baseURL: "https://corveil.io/v1", upstream: "chatgpt_codex")))
        #expect(route(gateway(base: "https://corveil.io/v1/")) == .success(.init(baseURL: "https://corveil.io/v1", upstream: "chatgpt_codex")))
    }

    @Test func explicitUpstreamWinsOverAuthState() {
        #expect(route(gateway(codex: .openaiAPI), auth: .chatgpt)
            == .success(.init(baseURL: "https://corveil.io/v1", upstream: "openai_api")))
        #expect(route(gateway(codex: .chatgptCodex), auth: .apiKey)
            == .success(.init(baseURL: "https://corveil.io/v1", upstream: "chatgpt_codex")))
    }

    @Test func autoFollowsCodexSignInAndFallsBackToChatGPT() throws {
        #expect(try route(gateway(codex: .auto), auth: .apiKey).get().upstream == "openai_api")
        #expect(try route(gateway(codex: .auto), auth: .chatgpt).get().upstream == "chatgpt_codex")
        #expect(try route(gateway(codex: .auto), auth: nil).get().upstream == "chatgpt_codex")
    }

    @Test func notRoutedUnlessOptedInAndCorveil() {
        #expect(route(nil) == .failure(.noGateway))
        #expect(route(WorkspaceGateway(baseURL: "", customHeaders: [:])) == .failure(.noGateway))
        // The default for every existing gateway: Codex launches as before.
        #expect(route(gateway(codex: nil)) == .failure(.notOptedIn))
        // A non-Corveil gateway has no /v1/responses passthrough.
        #expect(route(gateway(headers: ["Authorization": "Bearer x"])) == .failure(.notCorveil))
        // Corveil's other accepted key header name, any case.
        #expect((try? route(gateway(headers: ["X-Corveil-Key": "k"])).get()) != nil)
        #expect((try? route(gateway(headers: ["X-Citadel-API-Key": "k"])).get()) != nil)
    }

    @Test func shellSpecialBaseURLIsRefused() {
        for bad in ["https://x/$(id)", "https://x/`id`", "https://x/\"", "https://x/a b",
                    "https://x/it's", "https://x/!1", "https://x/a\\b", "https://x/\n"] {
            #expect(route(gateway(base: bad)) == .failure(.unsafeBaseURL), "\(bad)")
        }
    }

    // MARK: - overrides

    @Test func overridesNeverCarryTheKeyOrADoubleQuote() throws {
        let r = try route(gateway(headers: ["x-citadel-api-key": Self.key])).get()
        let overrides = CodexGatewayArgs.configOverrides(r)
        #expect(overrides == " -c model_provider=crow-corveil"
            + " -c model_providers.crow-corveil.name=Corveil"
            + " -c model_providers.crow-corveil.base_url='https://corveil.io/v1'"
            + " -c model_providers.crow-corveil.wire_api=responses"
            + " -c model_providers.crow-corveil.requires_openai_auth=true"
            + " -c model_providers.crow-corveil.http_headers.X-Corveil-Upstream=chatgpt_codex"
            + " -c model_providers.crow-corveil.env_http_headers.X-Corveil-Key=CROW_CORVEIL_GATEWAY_KEY")
        #expect(!overrides.contains(Self.key))
        // Sits inside `eval "…"` on prompt-seeded launches.
        #expect(!overrides.contains("\""))
        #expect(CodexGatewayArgs.commandRequestsKey("codex" + overrides))
        #expect(CodexGatewayArgs.configOverrides(nil) == "")
        #expect(!CodexGatewayArgs.commandRequestsKey("codex --no-alt-screen"))
    }

    @Test func overridesSurviveTheEvalPromptLaunch() throws {
        // The base URL's single quotes must survive the eval's double-quote layer.
        let r = try route(gateway()).get()
        let line = ShellLaunchArgs.evalPromptLaunch(
            prefix: "codex" + CodexGatewayArgs.configOverrides(r) + " --no-alt-screen",
            promptPath: "/tmp/p.md")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Replace the eval'd binary with a printer of its argv, and the prompt
        // read with a fixed value, so the shell parse is what's under test.
        let script = line
            .replacingOccurrences(of: "$(< '/tmp/p.md')", with: "hello")
            .replacingOccurrences(of: "eval \"codex", with: "eval \"printf '%s\\n'")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let argv = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(argv.contains("model_providers.crow-corveil.base_url=https://corveil.io/v1\n"))
        #expect(argv.contains("model_providers.crow-corveil.http_headers.X-Corveil-Upstream=chatgpt_codex\n"))
        #expect(argv.hasSuffix("--no-alt-screen\nhello\n"))
    }

    // MARK: - key

    @Test func keyExportIsShellQuotedAndControlSafe() {
        #expect(CodexGatewayArgs.keyExportPrefix("sk-1") == "export CROW_CORVEIL_GATEWAY_KEY='sk-1' && ")
        #expect(CodexGatewayArgs.keyExportPrefix("a'b") == "export CROW_CORVEIL_GATEWAY_KEY='a'\\''b' && ")
        // A newline would submit the pasted line early — export empty instead.
        #expect(CodexGatewayArgs.keyExportPrefix("sk\n-1") == "export CROW_CORVEIL_GATEWAY_KEY='' && ")
    }

    @Test func resolveKeyReadsTheCorveilHeaderAndOpReferences() {
        #expect(CodexGatewayArgs.resolveKey(gateway(), resolveSecret: { _ in nil }) == Self.key)
        let ref = gateway(headers: ["X-Citadel-API-Key": "op://V/I/f", "x-other": "o"])
        #expect(CodexGatewayArgs.resolveKey(ref, resolveSecret: { $0 == "op://V/I/f" ? "resolved" : nil }) == "resolved")
        #expect(CodexGatewayArgs.resolveKey(ref, resolveSecret: { _ in nil }) == nil)
        #expect(CodexGatewayArgs.resolveKey(gateway(headers: ["Authorization": "x"])) == nil)
    }

    // MARK: - auth.json

    @Test func authModeReadsOnlyTheMode() {
        #expect(CodexGatewayArgs.authMode(fromAuthJSON: ["auth_mode": "chatgpt", "tokens": [:] as [String: Any]]) == .chatgpt)
        #expect(CodexGatewayArgs.authMode(fromAuthJSON: ["auth_mode": "apikey", "OPENAI_API_KEY": "sk"]) == .apiKey)
        #expect(CodexGatewayArgs.authMode(fromAuthJSON: ["tokens": ["id_token": "x"]]) == .chatgpt)
        #expect(CodexGatewayArgs.authMode(fromAuthJSON: ["OPENAI_API_KEY": "sk"]) == .apiKey)
        #expect(CodexGatewayArgs.authMode(fromAuthJSON: ["OPENAI_API_KEY": NSNull()]) == nil)
    }

    @Test func readAuthModeMissingFileIsNil() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString)").path
        #expect(CodexGatewayArgs.readAuthMode(codexHome: dir) == nil)
    }
}

/// CROW-1407: the gateway route reaches every Codex launch builder.
@Suite("OpenAICodexAgent gateway route")
struct OpenAICodexAgentGatewayTests {
    /// The stored thread was recorded under the routed provider (CROW-1409).
    private let agent = OpenAICodexAgent(threadProviders: .init(
        recorded: { _ in CodexGatewayArgs.providerID }, configured: { "openai" }))
    private let route = CodexGatewayArgs.Route(baseURL: "https://corveil.io/v1", upstream: "chatgpt_codex")
    private var overrides: String { CodexGatewayArgs.configOverrides(route) }

    @Test func nilRouteIsByteIdenticalToTheProtocolMethod() {
        for kind in [SessionKind.work, .job, .review] {
            let session = Session(name: "t", kind: kind, agentKind: .codex)
            let plain = agent.autoLaunchCommand(
                session: session, worktreePath: "/tmp/wt", remoteControlEnabled: false,
                autoPermissionMode: true, telemetryPort: nil)
            let routed = agent.autoLaunchCommand(
                session: session, worktreePath: "/tmp/wt", remoteControlEnabled: false,
                autoPermissionMode: true, telemetryPort: nil, gatewayRoute: nil)
            #expect(plain == routed)
        }
        #expect(agent.managerLaunchCommand(
            sessionName: "M", remoteControlEnabled: false, autoPermissionMode: false,
            telemetryPort: nil, conversationID: nil)
            == agent.managerLaunchCommand(
                sessionName: "M", remoteControlEnabled: false, autoPermissionMode: false,
                telemetryPort: nil, conversationID: nil, gatewayRoute: nil))
    }

    @Test func everyBranchPutsOverridesRightAfterTheBinary() {
        let binary = agent.launchBinary() ?? "codex"
        for kind in [SessionKind.work, .job, .review] {
            for dispatched in [false, true] {
                var session = Session(name: "t", kind: kind, agentKind: .codex)
                session.reviewPromptDispatched = dispatched
                let cmd = agent.autoLaunchCommand(
                    session: session, worktreePath: "/tmp/wt", remoteControlEnabled: false,
                    autoPermissionMode: true, telemetryPort: nil, gatewayRoute: route) ?? ""
                #expect(cmd.contains(binary + CodexStartupNotices.configOverrides + overrides + " "), "\(kind) dispatched=\(dispatched)")
                #expect(CodexGatewayArgs.commandRequestsKey(cmd))
            }
        }
    }

    @Test func managerResumeByIdKeepsTheRoute() {
        let binary = agent.launchBinary() ?? "codex"
        let cmd = agent.managerLaunchCommand(
            sessionName: "M", remoteControlEnabled: false, autoPermissionMode: false,
            telemetryPort: nil, conversationID: "019a0000-0000-7000-8000-000000000000",
            gatewayRoute: route)
        #expect(cmd == "\(binary)\(CodexStartupNotices.configOverrides)\(overrides) resume '019a0000-0000-7000-8000-000000000000' --no-alt-screen")
    }

    @Test func handoffLaunchCarriesOverridesButNoKey() async throws {
        let cmd = try await agent.launchCommand(
            sessionID: UUID(), worktreePath: "/tmp/wt", prompt: "hi", gatewayRoute: route)
        #expect(cmd.contains("eval \"codex\(CodexStartupNotices.configOverrides)\(overrides) --no-alt-screen "))
        #expect(!cmd.contains("CROW_CORVEIL_GATEWAY_KEY="))
    }
}
