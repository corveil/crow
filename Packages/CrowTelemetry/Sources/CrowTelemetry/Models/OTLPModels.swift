import Foundation

// MARK: - OTLP Attribute Types

/// An OTLP key-value attribute.
public struct OTLPAttribute: Codable, Sendable {
    public let key: String
    public let value: OTLPAnyValue

    public init(key: String, value: OTLPAnyValue) {
        self.key = key
        self.value = value
    }
}

/// An OTLP value that can be a string, int, double, or bool.
public struct OTLPAnyValue: Codable, Sendable {
    public var stringValue: String?
    public var intValue: String?  // OTLP encodes int64 as string
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

    public init(stringValue: String) {
        self.stringValue = stringValue
    }

    public init(intValue: String) {
        self.intValue = intValue
    }

    public init(doubleValue: Double) {
        self.doubleValue = doubleValue
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
}

/// A set of metrics from a single resource (e.g., a Claude Code process).
public struct ResourceMetrics: Codable, Sendable {
    public let resource: OTLPResource?
    public let scopeMetrics: [ScopeMetrics]?
}

/// Metrics from a single instrumentation scope.
public struct ScopeMetrics: Codable, Sendable {
    public let scope: InstrumentationScope?
    public let metrics: [OTLPMetric]?
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
}

/// A gauge metric (point-in-time value).
public struct OTLPGauge: Codable, Sendable {
    public let dataPoints: [OTLPNumberDataPoint]?
}

/// A single numeric data point in a metric.
public struct OTLPNumberDataPoint: Codable, Sendable {
    public let attributes: [OTLPAttribute]?
    public let timeUnixNano: String?
    public let startTimeUnixNano: String?
    public let asInt: String?     // int64 encoded as string
    public let asDouble: Double?

    /// Get the numeric value as a Double.
    public var numericValue: Double {
        if let d = asDouble { return d }
        if let s = asInt, let d = Double(s) { return d }
        return 0
    }
}

// MARK: - Logs Payload

/// Top-level OTLP logs export request.
public struct OTLPLogsPayload: Codable, Sendable {
    public let resourceLogs: [ResourceLogs]
}

/// Log records from a single resource.
public struct ResourceLogs: Codable, Sendable {
    public let resource: OTLPResource?
    public let scopeLogs: [ScopeLogs]?
}

/// Log records from a single instrumentation scope.
public struct ScopeLogs: Codable, Sendable {
    public let scope: InstrumentationScope?
    public let logRecords: [OTLPLogRecord]?
}

/// A single OTLP log record (used for events).
public struct OTLPLogRecord: Codable, Sendable {
    public let timeUnixNano: String?
    public let observedTimeUnixNano: String?
    public let body: OTLPAnyValue?
    public let severityNumber: Int?
    public let severityText: String?
    public let attributes: [OTLPAttribute]?

    /// Extract the event name from the `event.name` attribute.
    public var eventName: String? {
        guard let attrs = attributes else { return nil }
        return extractAttribute("event.name", from: attrs)
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
}

/// An instrumentation scope (library/module that produced the data).
public struct InstrumentationScope: Codable, Sendable {
    public let name: String?
    public let version: String?
}
