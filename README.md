# swift-server-gcp

A lightweight Swift toolkit for running services on **Google Cloud Platform**.
No giant SDK, no SwiftNIO dependency — just the small pieces a Swift server
actually needs to talk to GCP's logging and tracing surface.

## What's in the box

| Module | Purpose |
| --- | --- |
| `GcpJsonLogHandler` | A [`swift-log`](https://github.com/apple/swift-log) `LogHandler` that emits one JSON object per line, shaped to [Cloud Logging's structured-logging contract](https://cloud.google.com/logging/docs/structured-logging). Severity, source location, and trace correlation fields are mapped automatically. |
| `TraceContext` | W3C Trace Context (`traceparent` / `tracestate`) + Google's legacy `X-Cloud-Trace-Context`. Parses inbound request headers, builds outbound forwarding headers, and bridges between the two formats. |

The two modules are designed to interoperate but don't depend on each other —
you can adopt one without the other.

## Requirements

- Swift **6.0** or later (the package opts in to Swift 6 language mode)
- macOS **13+** or Linux
- Dependencies: [`swift-log`](https://github.com/apple/swift-log) ≥ 1.6,
  [`swift-http-types`](https://github.com/apple/swift-http-types) ≥ 1.3

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Dean151/swift-server-gcp.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "MyServer",
        dependencies: [
            .product(name: "GoogleCloudPlatform", package: "swift-server-gcp"),
        ]
    ),
]
```

## Usage

### Structured logging for Cloud Logging

Bootstrap `swift-log` once at startup. When running on GCP (Cloud Run, GKE,
Compute Engine, App Engine flex), Cloud Logging picks up JSON written to
stdout and parses the special fields.

```swift
import Logging
import GoogleCloudPlatform

LoggingSystem.bootstrap { label in
    GcpJsonLogHandler(
        label: label,
        googleCloudProject: ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
    )
}

let logger = Logger(label: "my-service")
logger.info("server started", metadata: ["port": "8080"])
```

Each log line looks like:

```json
{
  "severity": "INFO",
  "message": "server started",
  "time": "2026-05-25T10:40:00.123Z",
  "logger": "my-service",
  "logging.googleapis.com/sourceLocation": {
    "file": "main.swift", "line": "12", "function": "run()"
  },
  "port": "8080"
}
```

#### Severity mapping

| `swift-log` level | Cloud Logging severity |
| --- | --- |
| `.trace`, `.debug` | `DEBUG` |
| `.info` | `INFO` |
| `.notice` | `NOTICE` |
| `.warning` | `WARNING` |
| `.error` | `ERROR` |
| `.critical` | `CRITICAL` |

#### Linking logs to traces

If your logger metadata contains the standard trace keys
(`trace.id`, `trace.span_id`, `trace.sampled`), the handler rewrites them to
the Cloud-Logging-recognised fields so the entry deep-links to its Cloud
Trace span:

```swift
logger.info("handling request", metadata: [
    "trace.id": "0af7651916cd43dd8448eb211c80319c",
    "trace.span_id": "b7ad6b7169203331",
    "trace.sampled": "true",
])
```

becomes

```json
{
  "logging.googleapis.com/trace": "projects/my-project/traces/0af7651916cd43dd8448eb211c80319c",
  "logging.googleapis.com/spanId": "b7ad6b7169203331",
  "logging.googleapis.com/trace_sampled": true,
  ...
}
```

The key constants are published on `TraceContext.MetadataKey` so middleware
and log handlers share a single source of truth.

### Trace propagation

`TraceContext` reads either format from an incoming request's
[`HTTPFields`](https://github.com/apple/swift-http-types) and produces a
matched pair of headers to forward downstream.

```swift
import HTTPTypes
import GoogleCloudPlatform

func handle(headers: HTTPFields) {
    guard let trace = TraceContext.extract(from: headers) else {
        // No usable trace header — fall back to your own request id.
        return
    }

    // Attach to logger metadata for the duration of the request.
    var logger = Logger(label: "handler")
    logger[metadataKey: TraceContext.MetadataKey.traceID] = "\(trace.traceID)"
    if let span = trace.spanID {
        logger[metadataKey: TraceContext.MetadataKey.spanID] = "\(span)"
    }
    if let sampled = trace.sampled {
        logger[metadataKey: TraceContext.MetadataKey.sampled] = "\(sampled)"
    }

    // When you call another service, forward the trace.
    let outbound = trace.forwardingHeaders
    // outbound contains both `traceparent`/`tracestate` and `X-Cloud-Trace-Context`.
}
```

What it handles for you:

- **Format precedence** — `traceparent` wins over `X-Cloud-Trace-Context` when
  both are present.
- **Validation** — all-zero trace/span ids are rejected per spec; malformed
  headers fall through to the next format or to `nil`.
- **Span-id normalisation** — W3C uses 16-hex, X-Cloud uses decimal uint64.
  `forwardingHeaders` converts between them so a context received in one
  format propagates cleanly in both.
- **`tracestate` pass-through** — verbatim, but only emitted alongside a
  valid `traceparent` (W3C forbids it standalone).
- **Conservative sampling** — unknown sampling decisions become `00` in
  W3C output; the `;o=` segment is simply omitted from the X-Cloud header.

## Design notes

- **No GCP SDK**
- **No SwiftNIO dependency**
- **Strict concurrency**
- **Decoupled trace ↔ log handover**

## Contributions

Issues and PRs welcome.

## License

[MIT](LICENSE) © Thomas Durand.
