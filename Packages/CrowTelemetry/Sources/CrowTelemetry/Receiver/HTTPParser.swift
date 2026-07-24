import Foundation

/// A parsed HTTP/1.1 request. Header keys are normalized to lowercase.
struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Get a header value (case-insensitive lookup).
    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Content-Length from headers, or 0 if absent.
    var contentLength: Int {
        guard let value = header("Content-Length"), let length = Int(value) else { return 0 }
        return length
    }
}

/// Minimal HTTP/1.1 response builder.
struct HTTPResponse: Sendable {
    let statusCode: Int
    let statusText: String
    let body: Data

    static func ok(body: Data = Data("{}".utf8)) -> HTTPResponse {
        HTTPResponse(statusCode: 200, statusText: "OK", body: body)
    }

    static func badRequest(message: String = "Bad Request") -> HTTPResponse {
        HTTPResponse(statusCode: 400, statusText: "Bad Request", body: errorBody(message))
    }

    static func notFound() -> HTTPResponse {
        HTTPResponse(statusCode: 404, statusText: "Not Found", body: errorBody("Not Found"))
    }

    /// Build the `{"error": …}` body with proper JSON escaping.
    ///
    /// Parser messages quote request-controlled values (`Content-Type`, a chunk
    /// size, the request path), so a quote or backslash in one of them would
    /// otherwise break out of the string and emit malformed JSON.
    private static func errorBody(_ message: String) -> Data {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["error": message],
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return Data(#"{"error":"Bad Request"}"#.utf8)
        }
        return data
    }

    /// Serialize to HTTP/1.1 response bytes.
    func serialize() -> Data {
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        var data = Data(response.utf8)
        data.append(body)
        return data
    }
}

/// Minimal HTTP/1.1 request parser for OTLP payloads.
///
/// Handles `Content-Length` and `Transfer-Encoding: chunked` framing; no
/// keep-alive (the receiver closes each connection after responding) and no
/// compressed bodies. Requests it cannot frame or read are reported as errors
/// rather than passed on with an empty body — silently handing `JSONDecoder` a
/// zero-byte body produced an unattributable decode error (#823).
enum HTTPParser {

    /// Reject absurd bodies rather than buffering them (64 MiB).
    static let maxBodyBytes = 64 * 1024 * 1024

    /// Parse result from feeding data into the parser.
    enum ParseResult: Sendable {
        /// A complete request was parsed.
        case complete(HTTPRequest)
        /// More data is needed (headers not complete or body incomplete).
        case needsMore
        /// The data is malformed.
        case error(String)
    }

    /// Methods that carry a request body and therefore require framing.
    private static let bodyMethods: Set<String> = ["POST", "PUT", "PATCH"]

    /// Attempt to parse a complete HTTP request from the accumulated data.
    ///
    /// - Parameter data: All data received so far on the connection.
    /// - Returns: Parse result indicating complete, needs more data, or error.
    static func parse(_ data: Data) -> ParseResult {
        // Find the end of headers (double CRLF)
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = data.range(of: separator) else {
            // Check for unreasonably large headers (> 8KB without end)
            if data.count > 8192 {
                return .error("Headers too large")
            }
            return .needsMore
        }

        let headerData = data[data.startIndex..<separatorRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .error("Invalid header encoding")
        }

        // Parse request line and headers
        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            return .error("Missing request line")
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            return .error("Malformed request line")
        }

        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let expectsBody = bodyMethods.contains(method.uppercased())
        if expectsBody, let rejection = rejectUnsupportedEncoding(headers) {
            return .error(rejection)
        }

        let bodyStart = separatorRange.upperBound
        let available = data.count - data.distance(from: data.startIndex, to: bodyStart)

        // Framing: chunked takes precedence over Content-Length (RFC 9112 §6.1).
        let transferEncoding = headers["transfer-encoding"]?.lowercased()
        if transferEncoding?.contains("chunked") == true {
            switch dechunk(data, from: bodyStart) {
            case .needsMore:
                return .needsMore
            case let .error(message):
                return .error(message)
            case let .complete(body):
                return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
            }
        }

        if let value = headers["content-length"] {
            guard let contentLength = Int(value), contentLength >= 0 else {
                return .error("Malformed Content-Length: \(quoted(value))")
            }
            guard contentLength <= maxBodyBytes else {
                return .error("Body too large: \(contentLength) bytes")
            }
            if available < contentLength {
                return .needsMore
            }
            let body = data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)]
            return .complete(HTTPRequest(method: method, path: path, headers: headers, body: Data(body)))
        }

        // No framing at all. A body-bearing request without Content-Length or
        // chunked encoding cannot be read; saying so beats forwarding an empty
        // body that fails later as an opaque decode error.
        if expectsBody {
            return .error("Missing Content-Length or Transfer-Encoding on \(quoted(method)) \(quoted(path))")
        }
        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: Data()))
    }

    /// Quote a request-controlled value into an error message.
    ///
    /// Bounded so an 8 KiB header cannot bloat the 400 response or the log line
    /// it is echoed into. Escaping is handled where the JSON body is built.
    private static func quoted(_ value: String, limit: Int = 120) -> String {
        value.count <= limit ? value : String(value.prefix(limit)) + "…"
    }

    /// Reject bodies this parser cannot read, naming the reason.
    private static func rejectUnsupportedEncoding(_ headers: [String: String]) -> String? {
        if let encoding = headers["content-encoding"]?.lowercased(),
           !encoding.isEmpty, encoding != "identity" {
            return "Unsupported Content-Encoding: \(quoted(encoding)) (OTLP export must be uncompressed)"
        }
        if let contentType = headers["content-type"]?.lowercased() {
            // Tolerate parameters, e.g. "application/json; charset=utf-8".
            let mediaType = contentType.split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? contentType
            guard mediaType == "application/json" || mediaType.hasSuffix("+json") else {
                return "Unsupported Content-Type: \(quoted(mediaType)) (OTLP/JSON only)"
            }
        }
        return nil
    }

    private enum ChunkedResult {
        case complete(Data)
        case needsMore
        case error(String)
    }

    /// Reassemble a `Transfer-Encoding: chunked` body.
    ///
    /// Trailers after the terminating zero-length chunk are consumed and
    /// discarded; the receiver has no use for them.
    private static func dechunk(_ data: Data, from start: Data.Index) -> ChunkedResult {
        let crlf = Data("\r\n".utf8)
        var cursor = start
        var body = Data()

        while true {
            guard let lineEnd = data.range(of: crlf, in: cursor..<data.endIndex)?.lowerBound else {
                return .needsMore
            }
            let sizeField = data[cursor..<lineEnd]
            guard let sizeText = String(data: sizeField, encoding: .utf8) else {
                return .error("Invalid chunk size encoding")
            }
            // A chunk size may carry extensions: "1a;name=value".
            let hex = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                return .error("Malformed chunk size: \(quoted(sizeText))")
            }

            let chunkStart = data.index(lineEnd, offsetBy: crlf.count)

            if size == 0 {
                // Terminating chunk: an immediate CRLF, or trailers then CRLFCRLF.
                if data.distance(from: chunkStart, to: data.endIndex) >= crlf.count,
                   data[chunkStart..<data.index(chunkStart, offsetBy: crlf.count)] == crlf {
                    return .complete(body)
                }
                guard data.range(of: Data("\r\n\r\n".utf8), in: chunkStart..<data.endIndex) != nil else {
                    return .needsMore
                }
                return .complete(body)
            }

            // Compare against the remaining budget rather than summing: a chunk
            // size near `Int.max` is well-formed hex, and `body.count + size`
            // would trap on overflow before the cap could reject it.
            guard size <= maxBodyBytes, body.count <= maxBodyBytes - size else {
                return .error("Chunked body too large")
            }
            // Chunk data plus its trailing CRLF must both have arrived.
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + crlf.count else {
                return .needsMore
            }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            let terminatorEnd = data.index(chunkEnd, offsetBy: crlf.count)
            // A chunk must end with CRLF; without this check a wrong size
            // silently desyncs the stream and corrupts the rest of the body.
            guard data[chunkEnd..<terminatorEnd] == crlf else {
                return .error("Malformed chunk terminator")
            }
            body.append(data[chunkStart..<chunkEnd])
            cursor = terminatorEnd
        }
    }
}
