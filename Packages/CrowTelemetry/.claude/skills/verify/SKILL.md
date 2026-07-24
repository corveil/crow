---
name: verify
description: Drive CrowTelemetry's OTLP ingest end-to-end — boot the real receiver, POST OTLP JSON with curl, inspect the SQLite db.
---

# Verifying CrowTelemetry changes

The package's runtime surface is `TelemetryService` (`OTLPReceiver` HTTP
listener on localhost + `TelemetryDatabase` SQLite file). There is no
standalone binary — build a throwaway harness executable that depends on this
package and boots the service:

```swift
// Sources/otlp-harness/main.swift — usage: otlp-harness <port> <data-dir>
import Foundation
import CrowTelemetry
let service = try TelemetryService(port: UInt16(CommandLine.arguments[1])!,
                                   dataDirectory: CommandLine.arguments[2]) { id in
    print("[harness] data received for session \(id)")
}
Task { try await service.start() }
dispatchMain()
```

Harness `Package.swift`: swift-tools-version 6.0, `platforms: [.macOS(.v14)]`,
`.package(path: "<repo>/Packages/CrowTelemetry")`. Build with `swift build`,
run in the background, then drive it.

Gotchas:
- Ingest is OTLP **HTTP/JSON only** (`OTEL_EXPORTER_OTLP_PROTOCOL=http/json`),
  paths `/v1/metrics` and `/v1/logs`, POST only. One request per connection
  (the receiver closes it after responding). `Content-Length` and
  `Transfer-Encoding: chunked` both work; a compressed body or a non-JSON
  `Content-Type` is rejected by name.
- The resource must carry `crow.session.id` (a UUID string) in
  `resource.attributes`, or the payload is silently skipped.
- Datapoint values: `asDouble` (number) or `asInt` (string **or** number).
- Sum metrics take `aggregationTemporality` (1=delta, 2=cumulative, or the
  `AGGREGATION_TEMPORALITY_*` name) and `isMonotonic`; cumulative sums are
  normalized to deltas at insert.
- Decoding is deliberately tolerant (#823): scalars are accepted in either
  their number or string form, and a malformed record is skipped with a
  `skipped malformed N logRecords` log line rather than failing the export.
- Event names arrive **bare** in the `event.name` attribute (`user_prompt`);
  they are qualified to `claude_code.user_prompt` at ingest, which is the form
  `countEvents` and `turnAnalytics` match on.
- Decode failures log the `DecodingError` coding path, which names the
  offending field. Set `CROW_TELEMETRY_LOG_RAW_BODIES=1` to also log a
  truncated raw body — off by default because bodies carry account IDs and
  emails. Repeat failures are throttled to one report per minute per path.

Minimal payload:

```json
{"resourceMetrics":[{"resource":{"attributes":[{"key":"crow.session.id","value":{"stringValue":"<UUID>"}}]},
 "scopeMetrics":[{"metrics":[{"name":"claude_code.cost.usage",
   "sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asDouble":1.0}]}}]}]}]}
```

Observe results with the sqlite3 CLI against `<data-dir>/telemetry.db`:
`SELECT metric_name, value, attributes_json FROM metrics ORDER BY id` and
compare `SUM(value)` per metric to the expected total. Events land in the
`events` table via `/v1/logs`.
