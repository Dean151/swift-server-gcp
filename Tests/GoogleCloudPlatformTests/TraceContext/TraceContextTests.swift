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

import HTTPTypes
import Testing
@testable import GoogleCloudPlatform

@Suite("traceparent parsing (W3C Trace Context)")
struct TraceparentTests {
    @Test("Valid v00 traceparent extracts trace id, span id and sampled flag")
    func validV00() {
        let parsed = TraceContext.parseTraceparent(
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        )
        #expect(parsed?.traceID == "0af7651916cd43dd8448eb211c80319c")
        #expect(parsed?.spanID == "b7ad6b7169203331")
        #expect(parsed?.sampled == true)
        #expect(parsed?.source == .traceparent)
    }

    @Test("Unsampled flag is recognised")
    func unsampledFlag() {
        let parsed = TraceContext.parseTraceparent(
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00"
        )
        #expect(parsed?.sampled == false)
    }

    @Test("Future versions with extra fields still parse the stable prefix")
    func futureVersionExtraFields() {
        // Hypothetical v01 with an extra trailing field — we accept it
        // because trace-id and span-id positions are spec-stable.
        let parsed = TraceContext.parseTraceparent(
            "01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-extra"
        )
        #expect(parsed?.traceID == "0af7651916cd43dd8448eb211c80319c")
        #expect(parsed?.spanID == "b7ad6b7169203331")
    }

    @Test("All-zero trace id is rejected")
    func allZeroTraceID() {
        let parsed = TraceContext.parseTraceparent(
            "00-00000000000000000000000000000000-b7ad6b7169203331-01"
        )
        #expect(parsed == nil)
    }

    @Test("All-zero span id is rejected")
    func allZeroSpanID() {
        let parsed = TraceContext.parseTraceparent(
            "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01"
        )
        #expect(parsed == nil)
    }

    @Test("Wrong-length trace id is rejected")
    func wrongLengthTraceID() {
        let parsed = TraceContext.parseTraceparent(
            "00-0af7651916cd43dd8448eb211c80319-b7ad6b7169203331-01"
        )
        #expect(parsed == nil)
    }

    @Test("Non-hex characters are rejected")
    func nonHex() {
        let parsed = TraceContext.parseTraceparent(
            "00-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-b7ad6b7169203331-01"
        )
        #expect(parsed == nil)
    }

    @Test("Garbage input is rejected")
    func garbage() {
        #expect(TraceContext.parseTraceparent("") == nil)
        #expect(TraceContext.parseTraceparent("not-a-traceparent") == nil)
        #expect(TraceContext.parseTraceparent("00-abc") == nil)
    }
}

@Suite("X-Cloud-Trace-Context parsing")
struct XCloudTraceTests {
    @Test("Full header with trace id, span and sampled flag")
    func fullHeader() {
        let parsed = TraceContext.parseXCloudTrace("105445aa7843bc8bf206b12000100000/1234;o=1")
        #expect(parsed?.traceID == "105445aa7843bc8bf206b12000100000")
        #expect(parsed?.spanID == "1234")
        #expect(parsed?.sampled == true)
        #expect(parsed?.source == .xCloudTraceContext)
    }

    @Test("Trace id alone (no span, no options) is accepted")
    func traceIDOnly() {
        let parsed = TraceContext.parseXCloudTrace("105445aa7843bc8bf206b12000100000")
        #expect(parsed?.traceID == "105445aa7843bc8bf206b12000100000")
        #expect(parsed?.spanID == nil)
        #expect(parsed?.sampled == nil)
    }

    @Test("o=0 marks the trace as not sampled")
    func notSampled() {
        let parsed = TraceContext.parseXCloudTrace("105445aa7843bc8bf206b12000100000/1;o=0")
        #expect(parsed?.sampled == false)
    }

    @Test("Trace id with bad length is rejected")
    func badLength() {
        #expect(TraceContext.parseXCloudTrace("abc/1;o=1") == nil)
    }

    @Test("All-zero trace id is rejected")
    func allZeroTraceID() {
        #expect(TraceContext.parseXCloudTrace("00000000000000000000000000000000/1") == nil)
    }
}

@Suite("TraceContext.extract precedence")
struct TraceContextExtractTests {
    private let validTraceparent =
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    private let validXCloud =
        "105445aa7843bc8bf206b12000100000/1;o=1"

    @Test("traceparent wins over X-Cloud-Trace-Context when both are present")
    func traceparentBeatsXCloud() {
        var headers = HTTPFields()
        headers[TraceContext.traceparentHeader] = validTraceparent
        headers[TraceContext.xCloudTraceHeader] = validXCloud
        let trace = TraceContext.extract(from: headers)
        #expect(trace?.source == .traceparent)
        #expect(trace?.traceID == "0af7651916cd43dd8448eb211c80319c")
    }

    @Test("tracestate is attached when accompanying a valid traceparent")
    func tracestatePassthrough() {
        var headers = HTTPFields()
        headers[TraceContext.traceparentHeader] = validTraceparent
        headers[TraceContext.tracestateHeader] = "vendor1=foo,vendor2=bar"
        let trace = TraceContext.extract(from: headers)
        #expect(trace?.traceState == "vendor1=foo,vendor2=bar")
    }

    @Test("Falls back to X-Cloud-Trace-Context when traceparent is malformed")
    func fallbackToXCloud() {
        var headers = HTTPFields()
        headers[TraceContext.traceparentHeader] = "garbage"
        headers[TraceContext.xCloudTraceHeader] = validXCloud
        let trace = TraceContext.extract(from: headers)
        #expect(trace?.source == .xCloudTraceContext)
    }

    @Test("Returns nil when no recognised header is present")
    func noHeaders() {
        let headers = HTTPFields()
        #expect(TraceContext.extract(from: headers) == nil)
    }

    @Test("Returns nil when both headers are malformed")
    func bothMalformed() {
        var headers = HTTPFields()
        headers[TraceContext.traceparentHeader] = "garbage"
        headers[TraceContext.xCloudTraceHeader] = "also-garbage"
        #expect(TraceContext.extract(from: headers) == nil)
    }
}

@Suite("TraceContext.forwardingHeaders")
struct TraceContextForwardingHeadersTests {
    @Test("traceparent-sourced context round-trips into an equivalent traceparent")
    func traceparentRoundTrip() {
        let parsed = TraceContext.parseTraceparent(
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        )
        let headers = parsed?.forwardingHeaders ?? HTTPFields()
        #expect(headers[TraceContext.traceparentHeader]
            == "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
    }

    @Test("Unsampled flag is preserved in the emitted traceparent")
    func unsampledFlagPropagates() {
        let parsed = TraceContext.parseTraceparent(
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00"
        )
        let headers = parsed?.forwardingHeaders ?? HTTPFields()
        #expect(headers[TraceContext.traceparentHeader]?.hasSuffix("-00") == true)
    }

    @Test("X-Cloud-sourced context is upgraded to W3C traceparent with hex span id")
    func xCloudUpgradedToTraceparent() {
        let parsed = TraceContext.parseXCloudTrace(
            "105445aa7843bc8bf206b12000100000/1234;o=1"
        )
        let headers = parsed?.forwardingHeaders ?? HTTPFields()
        // decimal 1234 → 0x4d2, zero-padded to 16 hex chars.
        #expect(headers[TraceContext.traceparentHeader]
            == "00-105445aa7843bc8bf206b12000100000-00000000000004d2-01")
    }

    @Test("X-Cloud-Trace-Context is also emitted for legacy GCP services")
    func xCloudLegacyHeaderEmitted() {
        let parsed = TraceContext.parseXCloudTrace(
            "105445aa7843bc8bf206b12000100000/1234;o=1"
        )
        let headers = parsed?.forwardingHeaders ?? HTTPFields()
        // Decimal span id round-trips unchanged.
        #expect(headers[TraceContext.xCloudTraceHeader]
            == "105445aa7843bc8bf206b12000100000/1234;o=1")
    }

    @Test("traceparent-sourced hex span id is rendered as decimal in X-Cloud header")
    func traceparentHexConvertedToDecimal() {
        let parsed = TraceContext.parseTraceparent(
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        )
        let headers = parsed?.forwardingHeaders ?? HTTPFields()
        // 0xb7ad6b7169203331 = 13_235_353_014_750_950_193
        #expect(headers[TraceContext.xCloudTraceHeader]
            == "0af7651916cd43dd8448eb211c80319c/13235353014750950193;o=1")
    }

    @Test("X-Cloud header omits ;o= when the sampling decision is unknown")
    func xCloudOmitsSamplingWhenUnknown() {
        // X-Cloud without `;o=` leaves sampled = nil.
        let parsed = TraceContext.parseXCloudTrace("105445aa7843bc8bf206b12000100000/1")
        let headers = parsed?.forwardingHeaders ?? HTTPFields()
        #expect(headers[TraceContext.xCloudTraceHeader]
            == "105445aa7843bc8bf206b12000100000/1")
    }

    @Test("Unknown sampling decision is propagated as not-sampled")
    func unknownSamplingDefaultsToZero() {
        // X-Cloud without `;o=` leaves sampled = nil.
        let parsed = TraceContext.parseXCloudTrace("105445aa7843bc8bf206b12000100000/1")
        let headers = parsed?.forwardingHeaders ?? HTTPFields()
        #expect(headers[TraceContext.traceparentHeader]?.hasSuffix("-00") == true)
    }

    @Test("tracestate is forwarded verbatim alongside traceparent")
    func tracestatePassesThrough() {
        var inbound = HTTPFields()
        inbound[TraceContext.traceparentHeader]
            = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        inbound[TraceContext.tracestateHeader] = "vendor1=foo,vendor2=bar"
        let trace = TraceContext.extract(from: inbound)
        let outbound = trace?.forwardingHeaders ?? HTTPFields()
        #expect(outbound[TraceContext.tracestateHeader] == "vendor1=foo,vendor2=bar")
    }

    @Test("Context without a span id skips traceparent but still emits X-Cloud")
    func noSpanFallsBackToXCloudOnly() {
        // X-Cloud-Trace-Context with just the trace id has no span.
        let parsed = TraceContext.parseXCloudTrace("105445aa7843bc8bf206b12000100000")
        let headers = parsed?.forwardingHeaders ?? HTTPFields()
        // W3C traceparent requires a span id, so it's not emitted.
        #expect(headers[TraceContext.traceparentHeader] == nil)
        // But X-Cloud doesn't, so we still propagate the trace id.
        #expect(headers[TraceContext.xCloudTraceHeader]
            == "105445aa7843bc8bf206b12000100000")
    }

    @Test("tracestate alone (no span) is not emitted — W3C forbids bare tracestate")
    func noBareTracestate() {
        let context = TraceContext(
            traceID: "0af7651916cd43dd8448eb211c80319c",
            spanID: nil,
            traceState: "vendor1=foo",
            sampled: true,
            source: .traceparent
        )
        #expect(context.forwardingHeaders[TraceContext.tracestateHeader] == nil)
    }
}

@Suite("Span-id normalisation on TraceContext")
struct TraceContextSpanIDHexTests {
    @Test("traceparent span id is already 16-hex and passes through unchanged")
    func traceparentSpanPassesThrough() {
        let parsed = TraceContext.parseTraceparent(
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        )
        #expect(parsed?.spanIDHex == "b7ad6b7169203331")
    }

    @Test("X-Cloud-Trace-Context decimal span id is zero-padded to 16 hex chars")
    func xCloudDecimalSpanToHex() {
        let parsed = TraceContext.parseXCloudTrace(
            "105445aa7843bc8bf206b12000100000/1234;o=1"
        )
        // decimal 1234 == 0x4d2 → 16-char hex with leading zeros
        #expect(parsed?.spanIDHex == "00000000000004d2")
    }

    @Test("X-Cloud-Trace-Context max-uint64 span id formats correctly")
    func xCloudMaxUInt64() {
        let parsed = TraceContext.parseXCloudTrace(
            "105445aa7843bc8bf206b12000100000/18446744073709551615"
        )
        #expect(parsed?.spanIDHex == "ffffffffffffffff")
    }

    @Test("X-Cloud-Trace-Context with no span id has no hex representation")
    func xCloudMissingSpan() {
        let parsed = TraceContext.parseXCloudTrace("105445aa7843bc8bf206b12000100000")
        #expect(parsed?.spanIDHex == nil)
    }
}
