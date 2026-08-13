import CrowCore
import Foundation
import Testing

@testable import CrowIPC

@Suite("MCP protocol envelope")
struct MCPProtocolTests {

    private func request(_ json: String) -> MCPRequest? {
        MCPRequest.decode(Data(json.utf8))
    }

    // MARK: - Ids

    @Test("A string id round-trips")
    func stringID() throws {
        let decoded = try #require(request(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#))
        #expect(decoded.id == .string("abc"))
        #expect(!decoded.id.isNotification)
    }

    @Test("A numeric id round-trips")
    func numberID() throws {
        let decoded = try #require(request(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#))
        #expect(decoded.id == .number(7))
    }

    @Test("An absent id is a notification, a null id is not")
    func notificationVsNull() throws {
        // The distinction matters: a notification must be answered with 202 and no
        // body, while a null id is a normal (if unidentifiable) request.
        let notification = try #require(request(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        #expect(notification.id == .absent)
        #expect(notification.id.isNotification)

        let nullID = try #require(request(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#))
        #expect(nullID.id == .null)
        #expect(!nullID.id.isNotification)
    }

    @Test("A message with no method is not a request")
    func rejectsNonRequests() {
        // A JSON-RPC *response*, which clients are forbidden from POSTing.
        #expect(request(#"{"jsonrpc":"2.0","id":1,"result":{}}"#) == nil)
        #expect(request("not json") == nil)
        #expect(request("[]") == nil)
    }

    @Test("A fractional id is rejected rather than truncated")
    func rejectsFractionalID() {
        #expect(request(#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#) == nil)
    }

    @Test("Non-object params decode as empty rather than failing")
    func positionalParamsDegradeGracefully() throws {
        let decoded = try #require(request(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[1,2]}"#))
        #expect(decoded.params.isEmpty)
    }

    // MARK: - Era detection

    @Test("A body carrying _meta protocolVersion is modern")
    func modernEra() throws {
        let decoded = try #require(request("""
            {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":
            {"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}
            """))
        #expect(MCPProtocol.era(of: decoded) == .modern(version: "2026-07-28"))
        #expect(decoded.metaProtocolVersion == "2026-07-28")
    }

    @Test("A body without _meta is legacy")
    func legacyEra() throws {
        let decoded = try #require(request(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#))
        #expect(MCPProtocol.era(of: decoded) == .legacy)
    }

    @Test("An initialize handshake is legacy even with params present")
    func initializeIsLegacy() throws {
        let decoded = try #require(request("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":
            {"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}
            """))
        #expect(MCPProtocol.era(of: decoded) == .legacy)
    }

    // MARK: - Errors

    @Test("UnsupportedProtocolVersion carries the supported list")
    func unsupportedVersionShape() throws {
        let response = MCPResponse.unsupportedVersion(id: .number(1), requested: "1900-01-01")
        let object = try #require(response.jsonValue.objectValue)
        let error = try #require(object["error"]?.objectValue)
        #expect(error["code"]?.intValue == -32022)
        let data = try #require(error["data"]?.objectValue)
        #expect(data["requested"]?.stringValue == "1900-01-01")
        // The client uses this list to retry rather than give up, so its presence
        // is the whole point of the error.
        let supported = try #require(data["supported"]?.arrayValue).compactMap(\.stringValue)
        #expect(supported.contains("2026-07-28"))
        #expect(supported.contains("2025-11-25"))
    }

    @Test("A result response has no error key, and vice versa")
    func responseShapesAreExclusive() throws {
        let ok = try #require(MCPResponse.result(id: .number(1), ["a": .int(1)]).jsonValue.objectValue)
        #expect(ok["result"] != nil)
        #expect(ok["error"] == nil)
        #expect(ok["jsonrpc"]?.stringValue == "2.0")

        let bad = try #require(
            MCPResponse.error(id: .number(1), code: -32601, message: "nope").jsonValue.objectValue)
        #expect(bad["error"] != nil)
        #expect(bad["result"] == nil)
    }

    @Test("Encoding is deterministic")
    func deterministicEncoding() {
        let response = MCPResponse.result(id: .string("x"), ["b": .int(2), "a": .int(1)])
        #expect(response.encoded() == response.encoded())
        let text = String(data: response.encoded(), encoding: .utf8) ?? ""
        #expect(text.range(of: #""a""#)?.lowerBound ?? text.endIndex
            < text.range(of: #""b""#)?.lowerBound ?? text.startIndex)
    }

    // MARK: - Header mirroring

    private func modernRequest(method: String, params: [String: JSONValue] = [:]) -> MCPRequest {
        var withMeta = params
        withMeta["_meta"] = .object([MCPProtocol.metaVersionKey: .string(MCPProtocol.modernVersion)])
        return MCPRequest(id: .number(1), method: method, params: withMeta)
    }

    @Test("Matching headers pass")
    func headersMatch() {
        let request = modernRequest(method: "tools/call", params: ["name": .string("list_sessions")])
        #expect(MCPServer.headerMismatch(
            request: request,
            methodHeader: "tools/call",
            nameHeader: "list_sessions",
            versionHeader: MCPProtocol.modernVersion) == nil)
    }

    @Test("A header that disagrees with the body is rejected")
    func headerBodyDisagreement() throws {
        // The vulnerability this closes: a load balancer routes on the header while
        // the server executes the body.
        let request = modernRequest(method: "tools/call", params: ["name": .string("list_sessions")])
        let mismatch = try #require(MCPServer.headerMismatch(
            request: request,
            methodHeader: "tools/call",
            nameHeader: "get_session",
            versionHeader: MCPProtocol.modernVersion))
        guard case .error(let code, _, _) = mismatch.payload else {
            Issue.record("expected an error payload")
            return
        }
        #expect(code == -32020)
    }

    @Test("Missing required headers are rejected on a modern request")
    func missingHeaders() {
        let request = modernRequest(method: "tools/call", params: ["name": .string("list_sessions")])
        #expect(MCPServer.headerMismatch(
            request: request, methodHeader: nil, nameHeader: "list_sessions",
            versionHeader: MCPProtocol.modernVersion) != nil)
        #expect(MCPServer.headerMismatch(
            request: request, methodHeader: "tools/call", nameHeader: nil,
            versionHeader: MCPProtocol.modernVersion) != nil)
        #expect(MCPServer.headerMismatch(
            request: request, methodHeader: "tools/call", nameHeader: "list_sessions",
            versionHeader: nil) != nil)
    }

    @Test("A legacy request is exempt from header validation")
    func legacyExemptFromHeaders() {
        // Rejecting a legacy client for omitting headers it has never heard of
        // would break the compatibility this server exists to provide.
        let request = MCPRequest(id: .number(1), method: "tools/list")
        #expect(MCPServer.headerMismatch(
            request: request, methodHeader: nil, nameHeader: nil, versionHeader: nil) == nil)
    }

    @Test("A base64-wrapped Mcp-Name is decoded before comparison")
    func base64HeaderValue() {
        let name = "list_sessions"
        let wrapped = "=?base64?" + Data(name.utf8).base64EncodedString() + "?="
        let request = modernRequest(method: "tools/call", params: ["name": .string(name)])
        #expect(MCPServer.headerMismatch(
            request: request, methodHeader: "tools/call", nameHeader: wrapped,
            versionHeader: MCPProtocol.modernVersion) == nil)
    }

    @Test("An undecodable base64 sentinel fails the comparison rather than passing")
    func malformedBase64HeaderValue() {
        let request = modernRequest(method: "tools/call", params: ["name": .string("list_sessions")])
        #expect(MCPServer.headerMismatch(
            request: request, methodHeader: "tools/call", nameHeader: "=?base64?!!!not-base64!!!?=",
            versionHeader: MCPProtocol.modernVersion) != nil)
    }

    @Test("An Mcp-Name sent for a method with no name is rejected")
    func spuriousNameHeader() {
        let request = modernRequest(method: "tools/list")
        #expect(MCPServer.headerMismatch(
            request: request, methodHeader: "tools/list", nameHeader: "whatever",
            versionHeader: MCPProtocol.modernVersion) != nil)
    }
}
