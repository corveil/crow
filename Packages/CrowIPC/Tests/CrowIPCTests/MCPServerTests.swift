import CrowCore
import Foundation
import Testing

@testable import CrowIPC

/// Records what the tools asked the daemon for, so a test can assert that a tool
/// reached exactly the methods its ledger row approves.
private actor InvokeSpy {
    private(set) var calls: [String] = []
    private let responses: [String: [String: JSONValue]]
    private let failure: Error?

    init(responses: [String: [String: JSONValue]] = [:], failure: Error? = nil) {
        self.responses = responses
        self.failure = failure
    }

    func record(_ method: String) throws -> [String: JSONValue] {
        calls.append(method)
        if let failure { throw failure }
        return responses[method] ?? [:]
    }

    nonisolated var invoke: MCPInvoke {
        { method, _ in try await self.record(method) }
    }
}

private struct DaemonDown: Error, LocalizedError {
    var errorDescription: String? { "connection refused" }
}

@Suite("MCP server")
struct MCPServerTests {
    let server = MCPServer(serverVersion: "1.2.3")

    private func send(
        _ method: String,
        id: MCPRequestID = .number(1),
        params: [String: JSONValue] = [:],
        modern: Bool = false,
        scopes: Set<MCPScope> = MCPScope.all,
        invoke: @escaping MCPInvoke = { _, _ in [:] }
    ) async -> MCPOutcome {
        var allParams = params
        if modern {
            allParams["_meta"] = .object([
                MCPProtocol.metaVersionKey: .string(MCPProtocol.modernVersion),
            ])
        }
        return await server.handle(
            MCPRequest(id: id, method: method, params: allParams), scopes: scopes, invoke: invoke)
    }

    private func result(_ outcome: MCPOutcome) throws -> [String: JSONValue] {
        guard case .reply(let response) = outcome, case .result(let result) = response.payload else {
            Issue.record("expected a successful reply, got \(outcome)")
            throw CancellationError()
        }
        return result
    }

    // MARK: - Discovery and handshake

    @Test("server/discover reports versions, capabilities and identity")
    func discover() async throws {
        let result = try result(await send("server/discover", modern: true))
        #expect(result["resultType"]?.stringValue == "complete")
        let versions = try #require(result["supportedVersions"]?.arrayValue).compactMap(\.stringValue)
        #expect(versions.first == MCPProtocol.modernVersion)
        #expect(result["capabilities"]?.objectValue?["tools"] != nil)
        let info = try #require(
            result["_meta"]?.objectValue?["io.modelcontextprotocol/serverInfo"]?.objectValue)
        #expect(info["name"]?.stringValue == "crow")
        #expect(info["version"]?.stringValue == "1.2.3")
    }

    @Test("server/discover answers even without modern _meta")
    func discoverIsAlwaysAvailable() async throws {
        // A dual-era client probes with `server/discover` before it knows which era
        // we speak; refusing the probe for lacking _meta would defeat the probe.
        let result = try result(await send("server/discover"))
        #expect(result["supportedVersions"] != nil)
    }

    @Test("initialize echoes a supported legacy version")
    func initializeEchoesVersion() async throws {
        let result = try result(await send(
            "initialize", params: ["protocolVersion": .string("2025-06-18")]))
        #expect(result["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(result["serverInfo"]?.objectValue?["name"]?.stringValue == "crow")
        #expect(result["capabilities"]?.objectValue?["tools"] != nil)
    }

    @Test("initialize answers an unknown version with one we support, not an error")
    func initializeFallsBack() async throws {
        // Legacy negotiation: the server offers its own version and the *client*
        // decides whether to disconnect. An error here would be wrong.
        let result = try result(await send(
            "initialize", params: ["protocolVersion": .string("1999-01-01")]))
        #expect(result["protocolVersion"]?.stringValue == MCPProtocol.legacyVersion)
    }

    @Test("notifications get 202 and no body")
    func notificationsAreAccepted() async {
        let outcome = await send("notifications/initialized", id: .absent)
        #expect(outcome == .accepted)
        #expect(outcome.responseData == nil)
    }

    @Test("ping answers with an empty result")
    func ping() async throws {
        #expect(try result(await send("ping")).isEmpty)
    }

    // MARK: - Version negotiation

    @Test("A modern request naming an unsupported version is a 400 with -32022")
    func unsupportedModernVersion() async throws {
        let outcome = await server.handle(
            MCPRequest(id: .number(1), method: "tools/list", params: [
                "_meta": .object([MCPProtocol.metaVersionKey: .string("1900-01-01")]),
            ]),
            scopes: MCPScope.all,
            invoke: { _, _ in [:] })
        guard case .badRequest(let response) = outcome,
              case .error(let code, _, let data) = response.payload
        else {
            Issue.record("expected a badRequest, got \(outcome)")
            return
        }
        #expect(code == MCPProtocol.ErrorCode.unsupportedProtocolVersion)
        #expect(data?["supported"] != nil)
    }

    @Test("Malformed JSON is a 400 parse error rather than a crash")
    func malformedJSON() async {
        let outcome = await server.handle(
            Data("{not json".utf8), scopes: MCPScope.all, invoke: { _, _ in [:] })
        guard case .badRequest(let response) = outcome,
              case .error(let code, _, _) = response.payload
        else {
            Issue.record("expected a badRequest, got \(outcome)")
            return
        }
        #expect(code == MCPProtocol.ErrorCode.parseError)
    }

    @Test("An unknown method is reported as unknownMethod so HTTP can 404 it")
    func unknownMethod() async {
        let outcome = await send("resources/list")
        guard case .unknownMethod(let response) = outcome,
              case .error(let code, _, _) = response.payload
        else {
            Issue.record("expected unknownMethod, got \(outcome)")
            return
        }
        #expect(code == MCPProtocol.ErrorCode.methodNotFound)
    }

    // MARK: - tools/list

    @Test("tools/list is filtered by the caller's scopes")
    func toolsListIsScoped() async throws {
        // The ticket's requirement: a deny-after-call still teaches the model that
        // write tools exist, so the *list* has to be filtered too.
        let boardOnly = try result(await send("tools/list", scopes: [.boardRead]))
        let names = try #require(boardOnly["tools"]?.arrayValue)
            .compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(Set(names) == ["list_tickets", "list_reviews"])
        #expect(!names.contains("list_sessions"))
        #expect(!names.contains("get_session"))
    }

    @Test("A scopeless caller sees no tools at all")
    func toolsListEmptyWithoutScopes() async throws {
        let result = try result(await send("tools/list", scopes: []))
        #expect(result["tools"]?.arrayValue?.isEmpty == true)
    }

    @Test("tools/list carries resultType only on the modern era")
    func resultTypeIsEraDependent() async throws {
        #expect(try result(await send("tools/list", modern: true))["resultType"]?.stringValue == "complete")
        #expect(try result(await send("tools/list"))["resultType"] == nil)
    }

    @Test("Every advertised tool has a name, description and object schema")
    func toolDefinitionsAreWellFormed() async throws {
        let result = try result(await send("tools/list"))
        let tools = try #require(result["tools"]?.arrayValue)
        #expect(tools.count == MCPToolCatalog.all.count)
        for tool in tools {
            let object = try #require(tool.objectValue)
            #expect(object["name"]?.stringValue?.isEmpty == false)
            #expect(object["description"]?.stringValue?.isEmpty == false)
            #expect(object["inputSchema"]?.objectValue?["type"]?.stringValue == "object")
        }
    }

    // MARK: - tools/call

    @Test("Calling a tool outside the caller's scopes is indistinguishable from unknown")
    func outOfScopeToolIsHidden() async throws {
        // Distinguishing the two would let a narrow token enumerate what it cannot
        // see — the same leak filtering tools/list closes. Both are protocol errors
        // (`-32602`), which is what the spec prescribes for an unknown tool: the
        // model cannot fix it by adjusting arguments.
        func errorFor(_ toolName: String) async throws -> (code: Int, message: String) {
            let outcome = await send(
                "tools/call", params: ["name": .string(toolName)], scopes: [.boardRead])
            guard case .reply(let response) = outcome,
                  case .error(let code, let message, _) = response.payload
            else {
                Issue.record("expected an error reply for \(toolName), got \(outcome)")
                throw CancellationError()
            }
            return (code, message)
        }

        let hidden = try await errorFor("list_sessions")
        let missing = try await errorFor("no_such_tool")
        #expect(hidden.code == MCPProtocol.ErrorCode.invalidParams)
        #expect(hidden.code == missing.code)
        // Same wording, so the message itself does not disclose that the tool exists.
        #expect(hidden.message == "Unknown tool: list_sessions")
        #expect(missing.message == "Unknown tool: no_such_tool")
    }

    @Test("tools/call without a name is invalidParams")
    func toolCallNeedsName() async {
        let outcome = await send("tools/call")
        guard case .reply(let response) = outcome, case .error(let code, _, _) = response.payload else {
            Issue.record("expected an error reply, got \(outcome)")
            return
        }
        #expect(code == MCPProtocol.ErrorCode.invalidParams)
    }

    @Test("A tool result carries both structuredContent and JSON text")
    func toolResultShape() async throws {
        let spy = InvokeSpy(responses: ["list-sessions": ["sessions": .array([])]])
        let result = try result(await send(
            "tools/call",
            params: ["name": .string("get_board_summary"), "arguments": .object([:])],
            invoke: spy.invoke))
        #expect(result["isError"]?.boolValue == false)
        #expect(result["structuredContent"]?.objectValue?["total"]?.intValue == 0)
        let content = try #require(result["content"]?.arrayValue).first?.objectValue
        #expect(content?["type"]?.stringValue == "text")
        #expect(content?["text"]?.stringValue?.contains("\"total\"") == true)
    }

    @Test("A downed daemon is a tool execution error, not a dropped connection")
    func daemonDownIsRecoverable() async throws {
        let spy = InvokeSpy(failure: DaemonDown())
        let result = try result(await send(
            "tools/call",
            params: ["name": .string("list_sessions"), "arguments": .object([:])],
            invoke: spy.invoke))
        #expect(result["isError"]?.boolValue == true)
        let text = try #require(result["content"]?.arrayValue).first?.objectValue?["text"]?.stringValue
        #expect(text?.contains("connection refused") == true)
    }

    @Test("A bad argument is a tool execution error the model can correct")
    func badArgumentIsRecoverable() async throws {
        let result = try result(await send(
            "tools/call",
            params: [
                "name": .string("list_sessions"),
                "arguments": .object(["status": .string("nonsense")]),
            ],
            invoke: { _, _ in ["sessions": .array([])] }))
        #expect(result["isError"]?.boolValue == true)
        let text = try #require(result["content"]?.arrayValue).first?.objectValue?["text"]?.stringValue
        // The message names the legal values, which is what makes a retry possible.
        #expect(text?.contains("inReview") == true)
    }

    @Test("get_session rejects a name where a UUID belongs")
    func getSessionValidatesUUID() async throws {
        let result = try result(await send(
            "tools/call",
            params: [
                "name": .string("get_session"),
                "arguments": .object(["session_id": .string("my-feature")]),
            ]))
        #expect(result["isError"]?.boolValue == true)
    }

    // MARK: - Backing methods

    @Test("Each tool reaches exactly the methods its ledger row approves")
    func toolsReachOnlyDeclaredMethods() async throws {
        for tool in MCPToolCatalog.all {
            let spy = InvokeSpy(responses: [
                "list-sessions": ["sessions": .array([])],
                "list-sessions-live": ["sessions": .object([:])],
                "list-tickets": ["issues": .array([])],
                "list-reviews": ["reviews": .array([])],
                "get-session": ["id": .string(UUID().uuidString)],
            ])
            var arguments: [String: JSONValue] = [:]
            if tool.name == "get_session" {
                arguments["session_id"] = .string(UUID().uuidString)
            }
            _ = await send(
                "tools/call",
                params: ["name": .string(tool.name), "arguments": .object(arguments)],
                invoke: spy.invoke)
            let called = Set(await spy.calls)
            #expect(
                called.isSubset(of: tool.backingMethods),
                "\(tool.name) called \(called.sorted()) but declares \(tool.backingMethods.sorted())")
        }
    }

    @Test("list_stuck_sessions joins both session payloads")
    func stuckSessionsJoinsBothPayloads() async throws {
        // The two payloads are disjoint, so a tool reading only one cannot answer
        // the question. Pin that it reads both.
        let spy = InvokeSpy(responses: [
            "list-sessions": ["sessions": .array([])],
            "list-sessions-live": ["sessions": .object([:])],
        ])
        _ = await send(
            "tools/call",
            params: ["name": .string("list_stuck_sessions"), "arguments": .object([:])],
            invoke: spy.invoke)
        #expect(Set(await spy.calls) == ["list-sessions", "list-sessions-live"])
    }

    @Test("list_tickets drops the unbounded issue body")
    func ticketBodyIsDropped() async throws {
        let spy = InvokeSpy(responses: [
            "list-tickets": ["issues": .array([.object([
                "id": .string("1"),
                "number": .int(7),
                "title": .string("A ticket"),
                "body": .string(String(repeating: "x", count: 50_000)),
            ])])],
        ])
        let result = try result(await send(
            "tools/call",
            params: ["name": .string("list_tickets"), "arguments": .object([:])],
            invoke: spy.invoke))
        let issues = try #require(result["structuredContent"]?.objectValue?["issues"]?.arrayValue)
        let first = try #require(issues.first?.objectValue)
        #expect(first["body"] == nil)
        #expect(first["title"]?.stringValue == "A ticket")
    }
}
