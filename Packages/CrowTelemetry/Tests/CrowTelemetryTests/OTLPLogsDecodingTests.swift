import Foundation
import Testing
@testable import CrowTelemetry

/// Tests for OTLP/JSON logs decoding (issue #823).
///
/// Every `/v1/logs` export from Claude Code was rejected with the generic
/// "isn't in the correct format", so no event ever reached the database. The
/// cause was type strictness, not transport: Claude Code stamps
/// `event.sequence` (and token/duration counters) onto every log record, and
/// the OpenTelemetry JS exporter encodes those as `{"intValue": <number>}`
/// while the model required `{"intValue": "<string>"}`. One mismatched
/// attribute failed the whole payload.
///
/// `claude-code-logs-export.json` is a real capture from Claude Code 2.1.219
/// with identifiers replaced; every JSON *type* is untouched, so the numeric
/// `intValue` fields that caused the bug are still numeric.

private func loadFixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
        "fixture \(name).json missing from the test bundle"
    )
    return try Data(contentsOf: url)
}

private func decodeLogs(_ json: String) throws -> OTLPLogsPayload {
    try JSONDecoder().decode(OTLPLogsPayload.self, from: Data(json.utf8))
}

/// Wrap a single log record in a minimal but complete logs payload.
private func logsPayload(records: String, resourceID: String = "11111111-2222-3333-4444-555555555555") -> String {
    """
    {"resourceLogs":[{
      "resource":{"attributes":[
        {"key":"crow.session.id","value":{"stringValue":"\(resourceID)"}}]},
      "scopeLogs":[{"logRecords":[\(records)]}]}]}
    """
}

// MARK: - Real capture

@Test("A real Claude Code /v1/logs export decodes")
func realExportDecodes() throws {
    let data = try loadFixture("claude-code-logs-export")
    let payload = try JSONDecoder().decode(OTLPLogsPayload.self, from: data)

    let resource = try #require(payload.resourceLogs.first)
    #expect(resource.resource?.crowSessionID == "11111111-2222-3333-4444-555555555555")

    let records = try #require(resource.scopeLogs?.first?.logRecords)
    #expect(records.count == 14)
}

@Test("The real export carries the numeric intValue attributes that broke decoding")
func realExportHasNumericIntValues() throws {
    let data = try loadFixture("claude-code-logs-export")

    // Guard the fixture itself: if a future re-capture stringifies these, the
    // regression test above would silently stop covering the bug.
    let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let resourceLogs = try #require(raw["resourceLogs"] as? [[String: Any]])
    let scopeLogs = try #require(resourceLogs[0]["scopeLogs"] as? [[String: Any]])
    let records = try #require(scopeLogs[0]["logRecords"] as? [[String: Any]])

    var numericIntValues = 0
    for record in records {
        for attribute in record["attributes"] as? [[String: Any]] ?? [] {
            let value = attribute["value"] as? [String: Any]
            if let number = value?["intValue"], number is NSNumber, !(number is NSString) {
                numericIntValues += 1
            }
        }
    }
    #expect(numericIntValues > 0, "fixture no longer exercises numeric intValue")

    // And they survive decoding as strings.
    let payload = try JSONDecoder().decode(OTLPLogsPayload.self, from: data)
    let decoded = try #require(payload.resourceLogs.first?.scopeLogs?.first?.logRecords)
    let sequences = decoded.compactMap { record in
        record.attributes.flatMap { extractAttribute("event.sequence", from: $0) }
    }
    #expect(sequences.count == decoded.count, "every record carries event.sequence")
    #expect(sequences.allSatisfy { Int($0) != nil })
}

@Test("Every record in the real export resolves a claude_code.* event name")
func realExportResolvesEventNames() throws {
    let data = try loadFixture("claude-code-logs-export")
    let payload = try JSONDecoder().decode(OTLPLogsPayload.self, from: data)
    let records = try #require(payload.resourceLogs.first?.scopeLogs?.first?.logRecords)

    let names = records.compactMap(\.resolvedEventName)
    #expect(names.count == records.count)
    #expect(names.allSatisfy { $0.hasPrefix("claude_code.") })
    // These are the names TelemetryDatabase's readers count.
    #expect(names.contains("claude_code.user_prompt"))
    #expect(names.contains("claude_code.api_request"))
}

// MARK: - AnyValue type tolerance

@Test("intValue decodes from a JSON number or a string")
func intValueAcceptsNumberOrString() throws {
    let payload = try decodeLogs(logsPayload(records: """
    {"body":{"stringValue":"claude_code.api_request"},"attributes":[
      {"key":"event.sequence","value":{"intValue":42}},
      {"key":"input_tokens","value":{"intValue":"1024"}}]}
    """))

    let attributes = try #require(payload.resourceLogs[0].scopeLogs?[0].logRecords?[0].attributes)
    #expect(extractAttribute("event.sequence", from: attributes) == "42")
    #expect(extractAttribute("input_tokens", from: attributes) == "1024")
}

@Test("int64 values beyond Double's exact range survive decoding")
func intValueKeepsPrecision() throws {
    let payload = try decodeLogs(logsPayload(records: """
    {"attributes":[{"key":"big","value":{"intValue":9007199254740993}}]}
    """))

    let attributes = try #require(payload.resourceLogs[0].scopeLogs?[0].logRecords?[0].attributes)
    #expect(extractAttribute("big", from: attributes) == "9007199254740993")
}

@Test("Composite attribute values flatten to JSON instead of vanishing")
func compositeValuesFlatten() throws {
    let payload = try decodeLogs(logsPayload(records: """
    {"attributes":[
      {"key":"workspace.host_paths","value":{"arrayValue":{"values":[
        {"stringValue":"/a"},{"stringValue":"/b"}]}}},
      {"key":"nested","value":{"kvlistValue":{"values":[
        {"key":"k","value":{"intValue":7}}]}}},
      {"key":"raw","value":{"bytesValue":"AQID"}}]}
    """))

    let attributes = try #require(payload.resourceLogs[0].scopeLogs?[0].logRecords?[0].attributes)
    #expect(extractAttribute("workspace.host_paths", from: attributes) == #"["\/a","\/b"]"#)
    #expect(extractAttribute("nested", from: attributes) == #"{"k":"7"}"#)
    #expect(extractAttribute("raw", from: attributes) == "AQID")
}

@Test("An attribute with no value decodes as empty rather than failing")
func attributeWithoutValueIsTolerated() throws {
    let payload = try decodeLogs(logsPayload(records: """
    {"attributes":[
      {"key":"undefined","value":{}},
      {"key":"kept","value":{"stringValue":"yes"}}]}
    """))

    let attributes = try #require(payload.resourceLogs[0].scopeLogs?[0].logRecords?[0].attributes)
    #expect(attributes.count == 2)
    #expect(extractAttribute("undefined", from: attributes) == nil)
    #expect(extractAttribute("kept", from: attributes) == "yes")
}

// MARK: - Scalar field tolerance

@Test(
    "severityNumber decodes from a number or an OTLP enum name",
    arguments: [("9", 9), ("\"SEVERITY_NUMBER_INFO\"", 9), ("\"SEVERITY_NUMBER_DEBUG3\"", 7),
                ("\"SEVERITY_NUMBER_FATAL\"", 21), ("\"13\"", 13)]
)
func severityNumberAcceptsNumberOrEnumName(encoded: String, expected: Int) throws {
    let payload = try decodeLogs(logsPayload(records: #"{"severityNumber":\#(encoded)}"#))
    #expect(payload.resourceLogs[0].scopeLogs?[0].logRecords?[0].severityNumber == expected)
}

@Test("timeUnixNano decodes from a string or a number")
func timestampAcceptsStringOrNumber() throws {
    let payload = try decodeLogs(logsPayload(records: """
    {"timeUnixNano":"1784916871131000000"},
    {"timeUnixNano":1784916871131000000}
    """))

    let records = try #require(payload.resourceLogs[0].scopeLogs?[0].logRecords)
    #expect(records[0].timeUnixNano == "1784916871131000000")
    #expect(records[1].timeUnixNano == "1784916871131000000")
}

@Test("aggregationTemporality decodes from a number or an enum name")
func temporalityAcceptsNumberOrEnumName() throws {
    func decodeSum(_ encoded: String) throws -> OTLPAggregationTemporality {
        let json = """
        {"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"m",
          "sum":{"aggregationTemporality":\(encoded),"isMonotonic":true,
                 "dataPoints":[{"asInt":5}]}}]}]}]}
        """
        let payload = try JSONDecoder().decode(OTLPMetricsPayload.self, from: Data(json.utf8))
        return try #require(payload.resourceMetrics[0].scopeMetrics?[0].metrics?[0].sum).temporality
    }

    #expect(try decodeSum("2") == .cumulative)
    #expect(try decodeSum("\"AGGREGATION_TEMPORALITY_DELTA\"") == .delta)
}

@Test("Metric asInt decodes from a number as well as a string")
func metricAsIntAcceptsNumber() throws {
    let json = """
    {"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.token.usage",
      "sum":{"aggregationTemporality":1,"isMonotonic":true,
             "dataPoints":[{"asInt":1500},{"asInt":"2500"}]}}]}]}]}
    """
    let payload = try JSONDecoder().decode(OTLPMetricsPayload.self, from: Data(json.utf8))
    let points = try #require(payload.resourceMetrics[0].scopeMetrics?[0].metrics?[0].sum?.dataPoints)
    #expect(points.map(\.numericValue) == [1500, 2500])
}

// MARK: - Per-record resilience

/// Decode with a diagnostics box attached, the way the receiver does.
private func decodeLogsReportingSkips(
    _ json: String
) throws -> (payload: OTLPLogsPayload, diagnostics: OTLPDecodeDiagnostics) {
    let diagnostics = OTLPDecodeDiagnostics()
    let decoder = JSONDecoder()
    decoder.userInfo[.otlpDiagnostics] = diagnostics
    return (try decoder.decode(OTLPLogsPayload.self, from: Data(json.utf8)), diagnostics)
}

@Test("A malformed record is skipped, not fatal to the whole export")
func malformedRecordIsSkipped() throws {
    // The middle element is a string where a record object belongs.
    let (payload, diagnostics) = try decodeLogsReportingSkips(logsPayload(records: """
    {"body":{"stringValue":"claude_code.user_prompt"}},
    "not a record",
    {"body":{"stringValue":"claude_code.tool_result"}}
    """))

    let records = try #require(payload.resourceLogs[0].scopeLogs?[0].logRecords)
    #expect(records.count == 2)
    #expect(records.compactMap(\.resolvedEventName) == ["claude_code.user_prompt", "claude_code.tool_result"])
    #expect(diagnostics.skipped("logRecords") == 1)
    #expect(diagnostics.summary == "1 logRecords")
}

@Test("Consecutive malformed records are each skipped without stalling")
func consecutiveMalformedRecordsAreSkipped() throws {
    let (payload, diagnostics) = try decodeLogsReportingSkips(logsPayload(records: """
    "bad", 17, null, {"body":{"stringValue":"claude_code.user_prompt"}}
    """))

    let records = try #require(payload.resourceLogs[0].scopeLogs?[0].logRecords)
    #expect(records.count == 1)
    #expect(diagnostics.skipped("logRecords") == 3)
}

@Test("A malformed scope costs that scope, not the whole resource")
func malformedScopeIsSkipped() throws {
    let json = """
    {"resourceLogs":[{
      "resource":{"attributes":[
        {"key":"crow.session.id","value":{"stringValue":"11111111-2222-3333-4444-555555555555"}}]},
      "scopeLogs":["not a scope",
        {"logRecords":[{"body":{"stringValue":"claude_code.user_prompt"}}]}]}]}
    """
    let (payload, diagnostics) = try decodeLogsReportingSkips(json)

    let resource = try #require(payload.resourceLogs.first)
    #expect(resource.resource?.crowSessionID == "11111111-2222-3333-4444-555555555555")
    #expect(resource.scopeLogs?.count == 1)
    #expect(resource.scopeLogs?[0].logRecords?[0].resolvedEventName == "claude_code.user_prompt")
    #expect(diagnostics.skipped("scopeLogs") == 1)
}

@Test("A malformed metrics scope costs that scope, not the whole resource")
func malformedMetricsScopeIsSkipped() throws {
    let json = """
    {"resourceMetrics":[{
      "resource":{"attributes":[
        {"key":"crow.session.id","value":{"stringValue":"11111111-2222-3333-4444-555555555555"}}]},
      "scopeMetrics":[17,
        {"metrics":[{"name":"claude_code.cost.usage",
          "sum":{"aggregationTemporality":1,"isMonotonic":true,"dataPoints":[{"asDouble":1.5}]}}]}]}]}
    """
    let diagnostics = OTLPDecodeDiagnostics()
    let decoder = JSONDecoder()
    decoder.userInfo[.otlpDiagnostics] = diagnostics
    let payload = try decoder.decode(OTLPMetricsPayload.self, from: Data(json.utf8))

    let resource = try #require(payload.resourceMetrics.first)
    #expect(resource.resource?.crowSessionID == "11111111-2222-3333-4444-555555555555")
    #expect(resource.scopeMetrics?.count == 1)
    #expect(resource.scopeMetrics?[0].metrics?[0].name == "claude_code.cost.usage")
    #expect(diagnostics.skipped("scopeMetrics") == 1)
}

@Test("A field that should be an array but isn't is reported, not silently dropped")
func nonArrayFieldIsReported() throws {
    let (payload, diagnostics) = try decodeLogsReportingSkips(logsPayload(records: """
    {"body":{"stringValue":"claude_code.user_prompt"},"attributes":{"not":"an array"}}
    """))

    let record = try #require(payload.resourceLogs[0].scopeLogs?[0].logRecords?.first)
    #expect(record.attributes == nil)
    #expect(record.resolvedEventName == "claude_code.user_prompt")
    #expect(diagnostics.skipped("attributes") == 1)
}

@Test("Skips are reported only when something was actually dropped")
func cleanDecodeReportsNoSkips() throws {
    let diagnostics = OTLPDecodeDiagnostics()
    let decoder = JSONDecoder()
    decoder.userInfo[.otlpDiagnostics] = diagnostics
    _ = try decoder.decode(OTLPLogsPayload.self, from: try loadFixture("claude-code-logs-export"))

    #expect(diagnostics.summary == nil)
}

@Test("An empty payload decodes to no resources instead of throwing")
func emptyPayloadIsNotAnError() throws {
    #expect(try decodeLogs("{}").resourceLogs.isEmpty)
    #expect(try decodeLogs(#"{"resourceLogs":[]}"#).resourceLogs.isEmpty)
}

// MARK: - Event name resolution

@Test("A bare event.name is qualified with the claude_code prefix")
func bareEventNameIsQualified() throws {
    let payload = try decodeLogs(logsPayload(records: """
    {"body":{"stringValue":"claude_code.user_prompt"},
     "attributes":[{"key":"event.name","value":{"stringValue":"user_prompt"}}]}
    """))
    #expect(payload.resourceLogs[0].scopeLogs?[0].logRecords?[0].resolvedEventName
        == "claude_code.user_prompt")
}

@Test("An already-qualified event name is left alone")
func qualifiedEventNameIsPreserved() throws {
    let payload = try decodeLogs(logsPayload(records: """
    {"attributes":[{"key":"event.name","value":{"stringValue":"claude_code.tool_result"}}]}
    """))
    #expect(payload.resourceLogs[0].scopeLogs?[0].logRecords?[0].resolvedEventName
        == "claude_code.tool_result")
}

@Test("A top-level eventName field wins over the attribute")
func topLevelEventNameWins() throws {
    let payload = try decodeLogs(logsPayload(records: """
    {"eventName":"claude_code.api_error",
     "attributes":[{"key":"event.name","value":{"stringValue":"user_prompt"}}]}
    """))
    #expect(payload.resourceLogs[0].scopeLogs?[0].logRecords?[0].resolvedEventName
        == "claude_code.api_error")
}

@Test("The body names the event when no event.name attribute is present")
func bodyIsTheEventNameFallback() throws {
    let payload = try decodeLogs(logsPayload(records: """
    {"body":{"stringValue":"claude_code.compaction"}}
    """))
    #expect(payload.resourceLogs[0].scopeLogs?[0].logRecords?[0].resolvedEventName
        == "claude_code.compaction")
}

@Test("A record with nothing to name it resolves to nil")
func unnamedRecordResolvesToNil() throws {
    let payload = try decodeLogs(logsPayload(records: #"{"severityNumber":9}"#))
    #expect(payload.resourceLogs[0].scopeLogs?[0].logRecords?[0].resolvedEventName == nil)
}

// MARK: - Failure diagnostics

/// A strict shape, standing in for whatever a future OTLP model requires — the
/// point is the rendering of a `DecodingError` that carries a coding path.
private struct StrictProbe: Decodable {
    struct Item: Decodable {
        let value: String
    }

    let items: [Item]
}

@Test("A decode failure is described by coding path, not a generic message")
func decodeFailureNamesTheField() {
    do {
        _ = try JSONDecoder().decode(StrictProbe.self, from: Data(#"{"items":[{"value":1}]}"#.utf8))
        Issue.record("expected the decode to fail")
    } catch {
        // Every DecodingError shares this one unhelpful string — it is what the
        // receiver used to log, and why #823 was undiagnosable from the log.
        #expect(error.localizedDescription
            == "The data couldn’t be read because it isn’t in the correct format.")

        let described = OTLPReceiver.describe(error)
        #expect(described.contains("typeMismatch"))
        #expect(described.contains("items[0].value"))
    }
}

@Test("A body that is not JSON at all is still described usefully")
func nonJSONBodyIsDescribed() {
    do {
        _ = try JSONDecoder().decode(OTLPLogsPayload.self, from: Data("not json".utf8))
        Issue.record("expected the decode to fail")
    } catch {
        let described = OTLPReceiver.describe(error)
        #expect(described.contains("dataCorrupted"))
        #expect(described.contains("<root>"))
    }
}

@Test("Repeated failures are throttled to one report per interval")
func failuresAreThrottled() {
    let throttle = FailureThrottle(interval: 60)
    let start = Date()

    #expect(throttle.claim("/v1/logs", now: start) == 0)
    #expect(throttle.claim("/v1/logs", now: start.addingTimeInterval(5)) == nil)
    #expect(throttle.claim("/v1/logs", now: start.addingTimeInterval(10)) == nil)
    // A different signal reports independently.
    #expect(throttle.claim("/v1/metrics", now: start.addingTimeInterval(10)) == 0)
    // Past the interval, the next report carries the suppressed count.
    #expect(throttle.claim("/v1/logs", now: start.addingTimeInterval(61)) == 2)
    #expect(throttle.claim("/v1/logs", now: start.addingTimeInterval(122)) == 0)
}
