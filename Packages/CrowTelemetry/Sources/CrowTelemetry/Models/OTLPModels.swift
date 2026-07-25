import Foundation

// MARK: - Decode Diagnostics

/// Collects non-fatal decode losses (records/attributes skipped) for one decode.
///
/// Tolerant decoding deliberately drops malformed elements instead of failing
/// the whole export — this box is how that silent loss gets reported. Pass one
/// in via `JSONDecoder.userInfo[.otlpDiagnostics]`.
public final class OTLPDecodeDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    public init() {}

    /// Number of elements skipped under `label` (e.g. `"logRecords"`).
    public func skipped(_ label: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[label] ?? 0
    }

    /// Human-readable summary, or `nil` when nothing was skipped.
    public var summary: String? {
        lock.lock()
        defer { lock.unlock() }
        guard !counts.isEmpty else { return nil }
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
    }

    fileprivate func recordSkip(_ label: String) {
        lock.lock()
        defer { lock.unlock() }
        counts[label, default: 0] += 1
    }
}

public extension CodingUserInfoKey {
    /// Key for an `OTLPDecodeDiagnostics` collecting skipped elements.
    static let otlpDiagnostics = CodingUserInfoKey(rawValue: "com.corveil.crow.otlp.diagnostics")!
}

// MARK: - Tolerant Decoding Helpers

/// Consumes any JSON value without inspecting it.
///
/// Used to advance an unkeyed container past an element that failed to decode —
/// `JSONDecoder` does not advance `currentIndex` when `decode` throws.
private struct SkippedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Maps an OTLP/JSON enum name to its number, e.g. `SEVERITY_NUMBER_INFO` → 9.
///
/// The protobuf JSON mapping allows enums to travel as either the number or the
/// symbolic name; Claude Code sends numbers, other SDKs send names.
private func otlpEnumValue(_ name: String, prefix: String, cases: [String: Int]) -> Int? {
    var bare = name.uppercased()
    if bare.hasPrefix(prefix) { bare.removeFirst(prefix.count) }
    if let exact = cases[bare] { return exact }
    // Severity names carry a 1-4 suffix within each band: DEBUG2 = DEBUG + 1.
    guard let last = bare.last, let offset = last.wholeNumberValue, (2...4).contains(offset) else {
        return nil
    }
    guard let base = cases[String(bare.dropLast())] else { return nil }
    return base + offset - 1
}

private let severityNumberCases: [String: Int] = [
    "UNSPECIFIED": 0, "TRACE": 1, "DEBUG": 5, "INFO": 9,
    "WARN": 13, "ERROR": 17, "FATAL": 21,
]

private let aggregationTemporalityCases: [String: Int] = [
    "UNSPECIFIED": 0, "DELTA": 1, "CUMULATIVE": 2,
]

extension KeyedDecodingContainer {
    /// Whether `key` is present and not JSON `null`.
    private func hasValue(_ key: Key) -> Bool {
        contains(key) && !((try? decodeNil(forKey: key)) ?? true)
    }

    /// Decode any JSON scalar as a `String`.
    ///
    /// OTLP/JSON producers are inconsistent about scalar types, so accept
    /// whatever arrives rather than failing the entire export.
    func otlpString(_ key: Key) -> String? {
        guard hasValue(key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? decode(UInt64.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        if let value = try? decode(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    /// Decode an int64 field, which OTLP/JSON permits as a number *or* a string.
    ///
    /// Kept as a `String` so values beyond `Double`'s exact range (nanosecond
    /// timestamps, token counts) survive intact.
    func otlpInt64String(_ key: Key) -> String? {
        guard hasValue(key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        if let value = try? decode(UInt64.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func otlpDouble(_ key: Key) -> Double? {
        guard hasValue(key) else { return nil }
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func otlpBool(_ key: Key) -> Bool? {
        guard hasValue(key) else { return nil }
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Bool(value.lowercased()) }
        return nil
    }

    /// Decode an enum field sent as either its number or its symbolic name.
    func otlpEnum(_ key: Key, prefix: String, cases: [String: Int]) -> Int? {
        guard hasValue(key) else { return nil }
        if let value = try? decode(Int.self, forKey: key) { return value }
        guard let name = try? decode(String.self, forKey: key) else { return nil }
        if let numeric = Int(name) { return numeric }
        return otlpEnumValue(name, prefix: prefix, cases: cases)
    }

    /// Decode an array element-by-element, skipping any element that fails.
    ///
    /// A single malformed log record should cost that record, not the whole
    /// export. Skips are counted into the decoder's `OTLPDecodeDiagnostics`
    /// under `label` so the loss is reported rather than silent.
    func otlpLenientArray<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        label: String,
        diagnostics: OTLPDecodeDiagnostics?
    ) -> [T]? {
        guard hasValue(key) else { return nil }
        guard var unkeyed = try? nestedUnkeyedContainer(forKey: key) else {
            // Present but not an array — report the loss rather than hiding it.
            diagnostics?.recordSkip(label)
            return nil
        }

        var elements: [T] = []
        while !unkeyed.isAtEnd {
            if let element = try? unkeyed.decode(T.self) {
                elements.append(element)
                continue
            }
            diagnostics?.recordSkip(label)
            // `decode` leaves the index untouched when it throws; step over the
            // bad element explicitly, and bail out if even that fails so this
            // cannot spin.
            guard (try? unkeyed.decode(SkippedValue.self)) != nil else { break }
        }
        return elements
    }
}

private extension Decoder {
    var otlpDiagnostics: OTLPDecodeDiagnostics? {
        userInfo[.otlpDiagnostics] as? OTLPDecodeDiagnostics
    }
}

// MARK: - OTLP Attribute Types

/// An OTLP key-value attribute.
public struct OTLPAttribute: Codable, Sendable {
    public let key: String
    public let value: OTLPAnyValue

    public init(key: String, value: OTLPAnyValue) {
        self.key = key
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        // OTel JS emits `{}` for an undefined value — treat a missing or
        // unreadable value as empty rather than failing the attribute.
        value = (try? container.decode(OTLPAnyValue.self, forKey: .value)) ?? OTLPAnyValue()
    }
}

/// An OTLP value that can be a string, int, double, bool, array, kvlist, or bytes.
///
/// Decoding is deliberately permissive: OTLP/JSON producers disagree about
/// scalar encodings (notably `intValue`, which Claude Code sends as a JSON
/// number while the protobuf JSON mapping also permits a string), and a strict
/// model turns any disagreement into a total export failure. Composite values
/// (`arrayValue`/`kvlistValue`) are flattened into `stringValue` as compact
/// JSON so they survive as something readable instead of vanishing.
public struct OTLPAnyValue: Codable, Sendable {
    public var stringValue: String?
    public var intValue: String?  // int64; kept as a string to preserve range
    public var doubleValue: Double?
    public var boolValue: Bool?

    /// Extract the value as a string regardless of type.
    public var asString: String? {
        if let s = stringValue { return s }
        if let s = intValue { return s }
        if let d = doubleValue { return String(describing: d) }
        if let b = boolValue { return String(describing: b) }
        return nil
    }

    /// Extract the value as a double regardless of type.
    public var asDouble: Double? {
        if let d = doubleValue { return d }
        if let s = intValue, let d = Double(s) { return d }
        if let s = stringValue, let d = Double(s) { return d }
        return nil
    }

    public init() {}

    public init(stringValue: String) {
        self.stringValue = stringValue
    }

    public init(intValue: String) {
        self.intValue = intValue
    }

    public init(doubleValue: Double) {
        self.doubleValue = doubleValue
    }

    public init(boolValue: Bool) {
        self.boolValue = boolValue
    }

    private enum CodingKeys: String, CodingKey {
        case stringValue, intValue, doubleValue, boolValue
        case arrayValue, kvlistValue, bytesValue
    }

    private struct ArrayValue: Decodable {
        let values: [OTLPAnyValue]?
    }

    private struct KvlistValue: Decodable {
        let values: [OTLPAttribute]?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stringValue = container.otlpString(.stringValue)
        intValue = container.otlpInt64String(.intValue)
        doubleValue = container.otlpDouble(.doubleValue)
        boolValue = container.otlpBool(.boolValue)

        guard stringValue == nil else { return }

        if let array = try? container.decode(ArrayValue.self, forKey: .arrayValue) {
            let items = (array.values ?? []).map { $0.asString ?? "" }
            stringValue = Self.jsonString(from: items)
        } else if let kvlist = try? container.decode(KvlistValue.self, forKey: .kvlistValue) {
            var dict: [String: String] = [:]
            for entry in kvlist.values ?? [] {
                dict[entry.key] = entry.value.asString ?? ""
            }
            stringValue = Self.jsonString(from: dict)
        } else {
            // bytesValue is base64 text per the JSON mapping; keep it verbatim.
            stringValue = container.otlpString(.bytesValue)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(stringValue, forKey: .stringValue)
        try container.encodeIfPresent(intValue, forKey: .intValue)
        try container.encodeIfPresent(doubleValue, forKey: .doubleValue)
        try container.encodeIfPresent(boolValue, forKey: .boolValue)
    }

    private static func jsonString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Extract an attribute value by key from an array of attributes.
public func extractAttribute(_ key: String, from attributes: [OTLPAttribute]) -> String? {
    attributes.first(where: { $0.key == key })?.value.asString
}

/// Extract a numeric attribute value by key from an array of attributes.
public func extractNumericAttribute(_ key: String, from attributes: [OTLPAttribute]) -> Double? {
    attributes.first(where: { $0.key == key })?.value.asDouble
}

// MARK: - Metrics Payload

/// Top-level OTLP metrics export request.
public struct OTLPMetricsPayload: Codable, Sendable {
    public let resourceMetrics: [ResourceMetrics]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceMetrics = container.otlpLenientArray(
            ResourceMetrics.self,
            forKey: .resourceMetrics,
            label: "resourceMetrics",
            diagnostics: decoder.otlpDiagnostics
        ) ?? []
    }
}

/// A set of metrics from a single resource (e.g., a Claude Code process).
public struct ResourceMetrics: Codable, Sendable {
    public let resource: OTLPResource?
    public let scopeMetrics: [ScopeMetrics]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resource = try? container.decodeIfPresent(OTLPResource.self, forKey: .resource)
        scopeMetrics = container.otlpLenientArray(
            ScopeMetrics.self,
            forKey: .scopeMetrics,
            label: "scopeMetrics",
            diagnostics: decoder.otlpDiagnostics
        )
    }
}

/// Metrics from a single instrumentation scope.
public struct ScopeMetrics: Codable, Sendable {
    public let scope: InstrumentationScope?
    public let metrics: [OTLPMetric]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try? container.decodeIfPresent(InstrumentationScope.self, forKey: .scope)
        metrics = container.otlpLenientArray(
            OTLPMetric.self,
            forKey: .metrics,
            label: "metrics",
            diagnostics: decoder.otlpDiagnostics
        )
    }
}

/// A single metric with its name and data points.
public struct OTLPMetric: Codable, Sendable {
    public let name: String
    public let unit: String?
    public let description: String?
    // Metrics can be sum, gauge, or histogram — Claude Code uses sum (counters).
    public let sum: OTLPSum?
    public let gauge: OTLPGauge?
}

/// OTLP aggregation temporality (metrics.proto AggregationTemporality).
public enum OTLPAggregationTemporality: Int, Sendable {
    case unspecified = 0
    case delta = 1
    case cumulative = 2
}

/// A sum metric (monotonic counter or non-monotonic up-down counter).
public struct OTLPSum: Codable, Sendable {
    public let dataPoints: [OTLPNumberDataPoint]?
    public let isMonotonic: Bool?
    public let aggregationTemporality: Int?  // 1 = delta, 2 = cumulative

    public var temporality: OTLPAggregationTemporality {
        OTLPAggregationTemporality(rawValue: aggregationTemporality ?? 0) ?? .unspecified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataPoints = container.otlpLenientArray(
            OTLPNumberDataPoint.self,
            forKey: .dataPoints,
            label: "dataPoints",
            diagnostics: decoder.otlpDiagnostics
        )
        isMonotonic = container.otlpBool(.isMonotonic)
        aggregationTemporality = container.otlpEnum(
            .aggregationTemporality,
            prefix: "AGGREGATION_TEMPORALITY_",
            cases: aggregationTemporalityCases
        )
    }
}

/// A gauge metric (point-in-time value).
public struct OTLPGauge: Codable, Sendable {
    public let dataPoints: [OTLPNumberDataPoint]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataPoints = container.otlpLenientArray(
            OTLPNumberDataPoint.self,
            forKey: .dataPoints,
            label: "dataPoints",
            diagnostics: decoder.otlpDiagnostics
        )
    }
}

/// A single numeric data point in a metric.
public struct OTLPNumberDataPoint: Codable, Sendable {
    public let attributes: [OTLPAttribute]?
    public let timeUnixNano: String?
    public let startTimeUnixNano: String?
    public let asInt: String?     // int64, sent as a string or a number
    public let asDouble: Double?

    /// Get the numeric value as a Double.
    public var numericValue: Double {
        if let d = asDouble { return d }
        if let s = asInt, let d = Double(s) { return d }
        return 0
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attributes = container.otlpLenientArray(
            OTLPAttribute.self,
            forKey: .attributes,
            label: "attributes",
            diagnostics: decoder.otlpDiagnostics
        )
        timeUnixNano = container.otlpInt64String(.timeUnixNano)
        startTimeUnixNano = container.otlpInt64String(.startTimeUnixNano)
        asInt = container.otlpInt64String(.asInt)
        asDouble = container.otlpDouble(.asDouble)
    }
}

// MARK: - Logs Payload

/// Top-level OTLP logs export request.
public struct OTLPLogsPayload: Codable, Sendable {
    public let resourceLogs: [ResourceLogs]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceLogs = container.otlpLenientArray(
            ResourceLogs.self,
            forKey: .resourceLogs,
            label: "resourceLogs",
            diagnostics: decoder.otlpDiagnostics
        ) ?? []
    }
}

/// Log records from a single resource.
public struct ResourceLogs: Codable, Sendable {
    public let resource: OTLPResource?
    public let scopeLogs: [ScopeLogs]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resource = try? container.decodeIfPresent(OTLPResource.self, forKey: .resource)
        scopeLogs = container.otlpLenientArray(
            ScopeLogs.self,
            forKey: .scopeLogs,
            label: "scopeLogs",
            diagnostics: decoder.otlpDiagnostics
        )
    }
}

/// Log records from a single instrumentation scope.
public struct ScopeLogs: Codable, Sendable {
    public let scope: InstrumentationScope?
    public let logRecords: [OTLPLogRecord]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try? container.decodeIfPresent(InstrumentationScope.self, forKey: .scope)
        logRecords = container.otlpLenientArray(
            OTLPLogRecord.self,
            forKey: .logRecords,
            label: "logRecords",
            diagnostics: decoder.otlpDiagnostics
        )
    }
}

/// A single OTLP log record (used for events).
public struct OTLPLogRecord: Codable, Sendable {
    public let timeUnixNano: String?
    public let observedTimeUnixNano: String?
    public let body: OTLPAnyValue?
    public let severityNumber: Int?
    public let severityText: String?
    public let attributes: [OTLPAttribute]?
    /// Top-level `eventName` (OTLP logs v1.x). Claude Code leaves it unset today
    /// and names events via the `event.name` attribute instead.
    public let eventName: String?

    /// The event name to store, qualified the way Claude Code documents it.
    ///
    /// On the wire the `event.name` attribute holds the *bare* name
    /// (`user_prompt`) while the fully-qualified `claude_code.user_prompt` sits
    /// in the body. Readers in `TelemetryDatabase` match the qualified form, so
    /// unqualified names are prefixed here at ingest.
    ///
    /// The `claude_code.` prefix assumes a single producer, which holds because
    /// `AgentLaunch` exports the `OTEL_*` env only for `agent.kind ==
    /// .claudeCode` — no other harness reaches this receiver. If a second agent
    /// ever exports here, this needs a source-aware prefix (derived from the
    /// resource's `service.name`) rather than a constant.
    public var resolvedEventName: String? {
        let candidate = eventName
            ?? attributes.flatMap { extractAttribute("event.name", from: $0) }
            ?? body?.asString
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate.contains(".") ? candidate : "claude_code.\(candidate)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeUnixNano = container.otlpInt64String(.timeUnixNano)
        observedTimeUnixNano = container.otlpInt64String(.observedTimeUnixNano)
        body = try? container.decodeIfPresent(OTLPAnyValue.self, forKey: .body)
        severityNumber = container.otlpEnum(
            .severityNumber,
            prefix: "SEVERITY_NUMBER_",
            cases: severityNumberCases
        )
        severityText = container.otlpString(.severityText)
        eventName = container.otlpString(.eventName)
        attributes = container.otlpLenientArray(
            OTLPAttribute.self,
            forKey: .attributes,
            label: "attributes",
            diagnostics: decoder.otlpDiagnostics
        )
    }
}

// MARK: - Shared Types

/// An OTLP resource describing the entity producing telemetry.
public struct OTLPResource: Codable, Sendable {
    public let attributes: [OTLPAttribute]?

    /// Extract `crow.session.id` from resource attributes.
    public var crowSessionID: String? {
        guard let attrs = attributes else { return nil }
        return extractAttribute("crow.session.id", from: attrs)
    }

    /// Extract `session.id` from resource attributes.
    public var sessionID: String? {
        guard let attrs = attributes else { return nil }
        return extractAttribute("session.id", from: attrs)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attributes = container.otlpLenientArray(
            OTLPAttribute.self,
            forKey: .attributes,
            label: "attributes",
            diagnostics: decoder.otlpDiagnostics
        )
    }
}

/// An instrumentation scope (library/module that produced the data).
public struct InstrumentationScope: Codable, Sendable {
    public let name: String?
    public let version: String?
}
