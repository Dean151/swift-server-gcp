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
import Logging

/// A `swift-log` `LogHandler` that emits one JSON object per log entry
/// to stdout, shaped for Google Cloud Logging's structured-logging
/// ingestion contract:
///
///   - `severity` — GCP severity name (DEBUG/INFO/NOTICE/WARNING/ERROR/CRITICAL).
///   - `message` — formatted log message.
///   - `time` — RFC3339 timestamp with milliseconds, UTC.
///   - `logger` — the swift-log label (originating logger name).
///   - `logging.googleapis.com/sourceLocation` — file/line/function.
///   - All metadata entries are merged onto the root object; the
///     `trace.id`, `trace.span_id`, `trace.sampled` keys attached by
///     a deployment-agnostic trace middleware are renamed to the
///     `logging.googleapis.com/{trace,spanId,trace_sampled}` keys that
///     Cloud Logging promotes to link the entry to its Cloud Trace span.
///     The key names are duplicated here (rather than imported from the
///     trace package) so this handler doesn't take a dependency on the
///     middleware that writes them.
///
/// Reference: <https://cloud.google.com/logging/docs/structured-logging>.
public struct GcpJsonLogHandler: LogHandler {
    public var logLevel: Logger.Level = .info
    public var metadata: Logger.Metadata = [:]

    private let label: String
    /// GCP project id used to build the `logging.googleapis.com/trace`
    /// resource name. When nil, the trace id is emitted as-is — log
    /// entries still group together by trace id in queries, but won't
    /// deep-link to Cloud Trace.
    private let googleCloudProject: String?

    public init(label: String, googleCloudProject: String? = nil) {
        self.label = label
        self.googleCloudProject = googleCloudProject
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        let line = Self.encodeEntry(
            level: event.level,
            message: event.message.description,
            label: label,
            handlerMetadata: self.metadata,
            callMetadata: event.metadata,
            file: event.file,
            function: event.function,
            line: event.line,
            googleCloudProject: googleCloudProject,
            now: Date()
        )
        Self.write(line)
    }

    /// Pure encode step extracted so tests can assert on the wire shape
    /// without touching stdout.
    static func encodeEntry(
        level: Logger.Level,
        message: String,
        label: String,
        handlerMetadata: Logger.Metadata,
        callMetadata: Logger.Metadata?,
        file: String,
        function: String,
        line: UInt,
        googleCloudProject: String?,
        now: Date
    ) -> String {
        var entry: [String: Any] = [
            "severity": gcpSeverity(level),
            "message": message,
            "time": iso8601.format(now),
            "logger": label,
            "logging.googleapis.com/sourceLocation": [
                "file": shortFile(file),
                "line": String(line),
                "function": function,
            ],
        ]

        // Per-call metadata takes precedence over the handler's defaults.
        var combined = handlerMetadata.merging(callMetadata ?? [:]) { _, new in new }

        // Translate the generic trace.* metadata keys (set by a
        // deployment-agnostic trace middleware that knows nothing about
        // GCP) into the Cloud-Logging-recognised keys. The project
        // prefix is the handler's responsibility because the
        // resource-name format is GCP-specific too.
        promoteTraceMetadata(into: &entry, from: &combined, googleCloudProject: googleCloudProject)

        // Whatever's left flows through as plain top-level fields, but
        // never clobbers a key we already set above.
        for (key, value) in combined where entry[key] == nil {
            entry[key] = encode(value)
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: entry, options: []),
            let json = String(data: data, encoding: .utf8)
        else {
            // Fall back to a hand-rolled minimal entry so a misencoded
            // metadata value can't silently drop the log line.
            return #"{"severity":"\#(gcpSeverity(level))","message":\#(jsonEscaped(message))}"# + "\n"
        }
        return json + "\n"
    }

    private static func promoteTraceMetadata(
        into entry: inout [String: Any],
        from metadata: inout Logger.Metadata,
        googleCloudProject: String?
    ) {
        if let traceID = metadata.removeValue(forKey: "trace.id").flatMap(extractString) {
            if let project = googleCloudProject, !project.isEmpty {
                entry["logging.googleapis.com/trace"] = "projects/\(project)/traces/\(traceID)"
            } else {
                entry["logging.googleapis.com/trace"] = traceID
            }
        }
        if let spanID = metadata.removeValue(forKey: "trace.span_id").flatMap(extractString) {
            entry["logging.googleapis.com/spanId"] = spanID
        }
        if let sampled = metadata.removeValue(forKey: "trace.sampled").flatMap(extractString) {
            // Cloud Logging documents this field as a JSON bool — emit
            // a real bool when the value parses, fall through to the
            // string form otherwise so the data isn't lost.
            entry["logging.googleapis.com/trace_sampled"] = Bool(sampled) ?? sampled
        }
    }

    private static func extractString(_ value: Logger.MetadataValue) -> String? {
        switch value {
        case .string(let s): return s
        case .stringConvertible(let c): return c.description
        case .array, .dictionary: return nil
        }
    }

    // MARK: - Internals

    /// `Date.ISO8601FormatStyle` is `Sendable`, unlike `ISO8601DateFormatter`,
    /// so it's safe to hold as a `static let` under strict concurrency.
    private static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Stdout writes from multiple tasks need serialising so two log
    /// lines can't interleave bytes. POSIX guarantees atomicity only up
    /// to PIPE_BUF, which is well below the size of a structured-log
    /// payload with metadata.
    private static let writeLock = NSLock()

    private static func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func gcpSeverity(_ level: Logger.Level) -> String {
        switch level {
        case .trace, .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .critical: return "CRITICAL"
        }
    }

    private static func shortFile(_ path: String) -> String {
        guard let lastSlash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: lastSlash)...])
    }

    private static func encode(_ value: Logger.MetadataValue) -> Any {
        switch value {
        case .string(let string): return string
        case .stringConvertible(let convertible): return convertible.description
        case .dictionary(let dict):
            var out: [String: Any] = [:]
            for (key, value) in dict { out[key] = encode(value) }
            return out
        case .array(let array):
            return array.map(encode)
        }
    }

    private static func jsonEscaped(_ s: String) -> String {
        // Cheap escape for the fallback path — only handles the bytes
        // JSONSerialization would have rejected (control chars + quotes
        // + backslash).
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case let c where c.value < 0x20:
                out.append(String(format: "\\u%04x", c.value))
            default: out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
        return out
    }
}
