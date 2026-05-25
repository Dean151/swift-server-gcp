//
//  MIT License
//
//  Copyright (c) 2026 Thomas Durand
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import HTTPTypes

/// Distributed-tracing context extracted from incoming request headers.
///
/// We honour W3C Trace Context (`traceparent` + `tracestate`) first and
/// fall back to Google Cloud's legacy `X-Cloud-Trace-Context` when the
/// request comes through a GCP frontend that hasn't set the W3C header.
/// When neither is present we return `nil` — leaving framework-level
/// request IDs as the only correlation key.
///
/// Both header formats reserve all-zero IDs as "invalid"; we reject them.
public struct TraceContext: Sendable, Equatable {
    public enum Source: String, Sendable {
        case traceparent
        case xCloudTraceContext = "x-cloud-trace-context"
    }

    /// 32 hex chars (W3C trace-id format).
    public var traceID: String
    /// W3C span-id (16 hex chars) or X-Cloud-Trace-Context span id
    /// (decimal string). Stored verbatim — we don't normalise across
    /// formats because consumers only ever need the trace id for
    /// correlation; the span id is logged as-is.
    public var spanID: String?
    /// Verbatim `tracestate` header value when accompanying a
    /// `traceparent`. Opaque, passed through for downstream consumers
    /// (e.g. log aggregators that understand vendor extensions).
    public var traceState: String?
    /// Sampling flag when the upstream signalled one explicitly.
    public var sampled: Bool?
    public var source: Source

    public init(
        traceID: String,
        spanID: String? = nil,
        traceState: String? = nil,
        sampled: Bool? = nil,
        source: Source
    ) {
        self.traceID = traceID
        self.spanID = spanID
        self.traceState = traceState
        self.sampled = sampled
        self.source = source
    }

    public static let traceparentHeader = HTTPField.Name("traceparent")!
    public static let tracestateHeader = HTTPField.Name("tracestate")!
    public static let xCloudTraceHeader = HTTPField.Name("X-Cloud-Trace-Context")!

    /// Logger metadata key conventions used by middlewares that surface
    /// a `TraceContext` to swift-log. Defined here so any log handler
    /// (GCP, OTLP, plain text) can look up the same keys without
    /// importing the middleware that wrote them.
    public enum MetadataKey {
        public static let traceID = "trace.id"
        public static let spanID = "trace.span_id"
        public static let sampled = "trace.sampled"
    }

    /// Pull a trace context out of the request headers. Returns `nil`
    /// when no recognised header is present or both are malformed.
    public static func extract(from headers: HTTPFields) -> TraceContext? {
        if let value = headers[traceparentHeader],
           var parsed = parseTraceparent(value)
        {
            parsed.traceState = headers[tracestateHeader]
            return parsed
        }
        if let value = headers[xCloudTraceHeader],
           let parsed = parseXCloudTrace(value)
        {
            return parsed
        }
        return nil
    }

    /// W3C `traceparent` is `version-trace_id-parent_id-flags`:
    /// `00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01`.
    /// Per the spec, version `00` has exactly four hyphen-separated
    /// fields; later versions may append more but the trace-id and
    /// span-id positions are stable, so we tolerate trailing fields.
    static func parseTraceparent(_ value: String) -> TraceContext? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        let version = parts[0]
        let traceID = String(parts[1])
        let spanID = String(parts[2])
        let flags = parts[3]

        guard version.count == 2, version.allSatisfy(\.isHexDigit) else { return nil }
        guard isValidTraceID(traceID) else { return nil }
        guard isValidSpanID(spanID) else { return nil }
        guard flags.count >= 2, let flagsByte = UInt8(flags.prefix(2), radix: 16) else {
            return nil
        }

        return TraceContext(
            traceID: traceID,
            spanID: spanID,
            traceState: nil,
            sampled: (flagsByte & 0x01) == 0x01,
            source: .traceparent
        )
    }

    /// `X-Cloud-Trace-Context` is `TRACE_ID/SPAN_ID;o=TRACE_TRUE`:
    /// `105445aa7843bc8bf206b12000100000/1;o=1`. Span and options are
    /// both optional in the wild; only the trace id is required for us
    /// to consider the header useful.
    static func parseXCloudTrace(_ value: String) -> TraceContext? {
        var head: Substring = Substring(value)
        var sampled: Bool?

        if let semi = head.firstIndex(of: ";") {
            let options = head[head.index(after: semi)...]
            head = head[..<semi]
            for option in options.split(separator: ";") {
                guard let eq = option.firstIndex(of: "="),
                      option[..<eq].trimmingWhitespace() == "o"
                else { continue }
                let raw = option[option.index(after: eq)...].trimmingWhitespace()
                sampled = (raw == "1")
            }
        }

        let parts = head.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let traceID = String(parts[0])
        guard isValidTraceID(traceID) else { return nil }
        let spanID = parts.count == 2 ? String(parts[1]) : nil

        return TraceContext(
            traceID: traceID,
            spanID: spanID,
            traceState: nil,
            sampled: sampled,
            source: .xCloudTraceContext
        )
    }

    /// Headers to attach to an outbound HTTP request so the downstream
    /// joins this trace. Emits both W3C `traceparent`/`tracestate` and
    /// the legacy `X-Cloud-Trace-Context` — the W3C pair for modern
    /// tracers and GCLB/Cloud Run, the GCP header for older Google
    /// APIs and internal services that haven't picked up W3C yet.
    ///
    /// The span id is propagated verbatim (normalised to 16-hex for
    /// W3C, to decimal uint64 for X-Cloud); this is pass-through
    /// propagation, not span creation — the downstream sees the same
    /// span as this service. Callers that mint a child span should
    /// rewrite the span-id segment after the fact.
    ///
    /// `tracestate` is only emitted alongside a `traceparent`; per
    /// W3C, a bare `tracestate` is meaningless and downstreams must
    /// ignore it.
    ///
    /// `X-Cloud-Trace-Context` is always emitted because every field
    /// after the trace id is optional in that format — so we can
    /// propagate a useful header even when the span id is missing,
    /// and we omit `;o=` when the sampling decision is unknown rather
    /// than fabricating a default.
    public var forwardingHeaders: HTTPFields {
        var fields = HTTPFields()

        // W3C requires a span id and a flags byte. Unknown sampling is
        // propagated as not-sampled — the conservative choice, since
        // upstream would have set the bit if it wanted the trace
        // recorded.
        if let span = spanIDHex {
            let flags = sampled == true ? "01" : "00"
            fields[Self.traceparentHeader] = "00-\(traceID)-\(span)-\(flags)"
            if let traceState {
                fields[Self.tracestateHeader] = traceState
            }
        }

        // X-Cloud format is `TRACE_ID[/SPAN_DECIMAL][;o=0|1]`. We go
        // through `spanIDHex` so a W3C-sourced hex span id converts
        // cleanly to decimal uint64 (16 hex chars always fit in 64
        // bits), and an X-Cloud-sourced decimal span round-trips
        // unchanged.
        var xCloud = traceID
        if let decimal = spanIDHex.flatMap({ UInt64($0, radix: 16) }) {
            xCloud += "/\(decimal)"
        }
        if let sampled {
            xCloud += ";o=\(sampled ? 1 : 0)"
        }
        fields[Self.xCloudTraceHeader] = xCloud

        return fields
    }

    /// Span id normalised to 16-char hex. `traceparent` already gives
    /// us hex; `X-Cloud-Trace-Context` gives a decimal uint64 which we
    /// zero-pad to 16 hex chars. Returns nil when no span id is
    /// available or the value can't be represented in either form.
    public var spanIDHex: String? {
        guard let spanID else { return nil }
        if spanID.count == 16, spanID.allSatisfy(\.isHexDigit) {
            return spanID
        }
        if let decimal = UInt64(spanID), decimal != 0 {
            return String(format: "%016llx", decimal)
        }
        return nil
    }

    private static func isValidTraceID(_ id: String) -> Bool {
        id.count == 32
            && id.allSatisfy(\.isHexDigit)
            && id != "00000000000000000000000000000000"
    }

    private static func isValidSpanID(_ id: String) -> Bool {
        id.count == 16
            && id.allSatisfy(\.isHexDigit)
            && id != "0000000000000000"
    }
}

private extension Substring {
    func trimmingWhitespace() -> Substring {
        var s = self
        while let first = s.first, first.isWhitespace { s = s.dropFirst() }
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return s
    }
}
