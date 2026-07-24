import Foundation
import Testing
@testable import CrowTelemetry

/// Tests for the OTLP HTTP request parser (issue #823).
///
/// The parser previously derived the body from `Content-Length` alone and
/// returned a *complete* request with an empty body whenever that header was
/// missing — turning any framing surprise into the same unattributable
/// "invalid payload" as a real schema mismatch.

private func request(
    _ head: String,
    body: String = "",
    headers: [String: String] = [:]
) -> Data {
    var text = "\(head) HTTP/1.1\r\nHost: localhost\r\n"
    for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
        text += "\(key): \(value)\r\n"
    }
    text += "\r\n"
    var data = Data(text.utf8)
    data.append(Data(body.utf8))
    return data
}

private func parsed(_ data: Data) throws -> HTTPRequest {
    guard case let .complete(request) = HTTPParser.parse(data) else {
        Issue.record("expected a complete request, got \(HTTPParser.parse(data))")
        throw ParseFailure()
    }
    return request
}

private func errorMessage(_ data: Data) throws -> String {
    guard case let .error(message) = HTTPParser.parse(data) else {
        Issue.record("expected an error, got \(HTTPParser.parse(data))")
        throw ParseFailure()
    }
    return message
}

private struct ParseFailure: Error {}

private let json = #"{"resourceLogs":[]}"#

// MARK: - Content-Length framing

@Test("A Content-Length framed request parses")
func contentLengthRequestParses() throws {
    let result = try parsed(request(
        "POST /v1/logs",
        body: json,
        headers: ["Content-Type": "application/json", "Content-Length": "\(json.utf8.count)"]
    ))

    #expect(result.method == "POST")
    #expect(result.path == "/v1/logs")
    #expect(String(decoding: result.body, as: UTF8.self) == json)
}

@Test("Header lookup stays case-insensitive after normalization")
func headerLookupIsCaseInsensitive() throws {
    let result = try parsed(request(
        "POST /v1/logs",
        body: json,
        headers: ["CONTENT-TYPE": "application/json", "content-length": "\(json.utf8.count)"]
    ))

    #expect(result.header("Content-Type") == "application/json")
    #expect(result.header("content-type") == "application/json")
    #expect(result.contentLength == json.utf8.count)
}

@Test("A body split across reads needs more data before completing")
func splitBodyNeedsMore() throws {
    let full = request(
        "POST /v1/logs",
        body: json,
        headers: ["Content-Type": "application/json", "Content-Length": "\(json.utf8.count)"]
    )
    let partial = full.prefix(full.count - 5)

    guard case .needsMore = HTTPParser.parse(Data(partial)) else {
        Issue.record("a truncated body should ask for more data")
        return
    }
    #expect(String(decoding: try parsed(full).body, as: UTF8.self) == json)
}

@Test("Headers arriving without their terminator need more data")
func partialHeadersNeedMore() {
    guard case .needsMore = HTTPParser.parse(Data("POST /v1/logs HTTP/1.1\r\nHost: local".utf8)) else {
        Issue.record("incomplete headers should ask for more data")
        return
    }
}

// MARK: - Chunked framing

@Test("A chunked request is reassembled")
func chunkedRequestParses() throws {
    let body = "5\r\n{\"res\r\n3\r\nour\r\n0\r\n\r\n"
    let result = try parsed(request(
        "POST /v1/logs",
        body: body,
        headers: ["Content-Type": "application/json", "Transfer-Encoding": "chunked"]
    ))

    #expect(String(decoding: result.body, as: UTF8.self) == "{\"resour")
}

@Test("Chunk extensions and trailers are tolerated")
func chunkedExtensionsAndTrailersParse() throws {
    let body = "4;name=value\r\ntest\r\n0\r\nX-Trailer: v\r\n\r\n"
    let result = try parsed(request(
        "POST /v1/logs",
        body: body,
        headers: ["Content-Type": "application/json", "Transfer-Encoding": "chunked"]
    ))

    #expect(String(decoding: result.body, as: UTF8.self) == "test")
}

@Test("A chunked body split mid-stream needs more data")
func chunkedSplitNeedsMore() {
    let partial = request(
        "POST /v1/logs",
        body: "8\r\n{\"res",
        headers: ["Content-Type": "application/json", "Transfer-Encoding": "chunked"]
    )

    guard case .needsMore = HTTPParser.parse(partial) else {
        Issue.record("an unterminated chunked body should ask for more data")
        return
    }
}

@Test("A malformed chunk size is an error, not an empty body")
func malformedChunkSizeIsAnError() throws {
    let data = request(
        "POST /v1/logs",
        body: "zz\r\nbad\r\n0\r\n\r\n",
        headers: ["Content-Type": "application/json", "Transfer-Encoding": "chunked"]
    )
    #expect(try errorMessage(data).contains("Malformed chunk size"))
}

// MARK: - Framing and encoding rejections

@Test("A POST with no framing is rejected instead of yielding an empty body")
func unframedPostIsRejected() throws {
    let data = request("POST /v1/logs", body: json, headers: ["Content-Type": "application/json"])

    // The pre-fix behaviour was `.complete` with a zero-byte body, which then
    // failed in JSONDecoder as an opaque "invalid payload".
    #expect(try errorMessage(data).contains("Missing Content-Length or Transfer-Encoding"))
}

@Test("A non-numeric Content-Length is rejected")
func malformedContentLengthIsRejected() throws {
    let data = request(
        "POST /v1/logs",
        body: json,
        headers: ["Content-Type": "application/json", "Content-Length": "abc"]
    )
    #expect(try errorMessage(data).contains("Malformed Content-Length"))
}

@Test("A protobuf body is rejected by name rather than handed to JSONDecoder")
func protobufContentTypeIsRejected() throws {
    let data = request(
        "POST /v1/logs",
        body: json,
        headers: ["Content-Type": "application/x-protobuf", "Content-Length": "\(json.utf8.count)"]
    )
    let message = try errorMessage(data)
    #expect(message.contains("Unsupported Content-Type"))
    #expect(message.contains("application/x-protobuf"))
}

@Test("A charset parameter on the content type is tolerated")
func contentTypeParametersAreTolerated() throws {
    let result = try parsed(request(
        "POST /v1/logs",
        body: json,
        headers: ["Content-Type": "application/json; charset=utf-8",
                  "Content-Length": "\(json.utf8.count)"]
    ))
    #expect(String(decoding: result.body, as: UTF8.self) == json)
}

@Test("A compressed body is rejected by name")
func gzipContentEncodingIsRejected() throws {
    let data = request(
        "POST /v1/logs",
        body: json,
        headers: ["Content-Type": "application/json",
                  "Content-Encoding": "gzip",
                  "Content-Length": "\(json.utf8.count)"]
    )
    let message = try errorMessage(data)
    #expect(message.contains("Unsupported Content-Encoding"))
    #expect(message.contains("gzip"))
}

@Test("An identity Content-Encoding is accepted")
func identityContentEncodingIsAccepted() throws {
    let result = try parsed(request(
        "POST /v1/logs",
        body: json,
        headers: ["Content-Type": "application/json",
                  "Content-Encoding": "identity",
                  "Content-Length": "\(json.utf8.count)"]
    ))
    #expect(String(decoding: result.body, as: UTF8.self) == json)
}

@Test("A GET without framing is still a complete request")
func bodylessMethodNeedsNoFraming() throws {
    let result = try parsed(request("GET /v1/logs"))
    #expect(result.method == "GET")
    #expect(result.body.isEmpty)
}

@Test("An oversized Content-Length is rejected")
func oversizedBodyIsRejected() throws {
    let data = request(
        "POST /v1/logs",
        headers: ["Content-Type": "application/json",
                  "Content-Length": "\(HTTPParser.maxBodyBytes + 1)"]
    )
    #expect(try errorMessage(data).contains("Body too large"))
}

@Test("Oversized headers are rejected rather than buffered forever")
func oversizedHeadersAreRejected() throws {
    var data = Data("POST /v1/logs HTTP/1.1\r\n".utf8)
    data.append(Data(String(repeating: "X", count: 9000).utf8))
    #expect(try errorMessage(data).contains("Headers too large"))
}
