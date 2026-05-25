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
import Testing
@testable import GoogleCloudPlatform

@Suite("GcpJsonLogHandler JSON encoding")
struct GcpJsonLogHandlerTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_716_633_600)

    @Test("Encodes the required top-level Cloud Logging keys")
    func emitsRequiredKeys() throws {
        let json = decode(encode())
        #expect(json["severity"] as? String == "INFO")
        #expect(json["message"] as? String == "hello")
        #expect(json["logger"] as? String == "latte.test")
        #expect(json["time"] is String)
        let source = json["logging.googleapis.com/sourceLocation"] as? [String: Any]
        #expect(source?["file"] as? String == "Foo.swift")
        #expect(source?["line"] as? String == "42")
        #expect(source?["function"] as? String == "bar()")
    }

    @Test("time field is RFC3339 in UTC with explicit Z and ms precision")
    func timeFieldIsRFC3339UTC() throws {
        // fixedDate = 2024-05-25 10:40:00 UTC. Cloud Logging requires
        // an explicit timezone (Z or ±HH:MM); ambiguous formats fall
        // back to ingestion time, which shows up as out-of-order entries
        // in the UI.
        let json = decode(encode())
        #expect(json["time"] as? String == "2024-05-25T10:40:00.000Z")
    }

    @Test("Maps swift-log levels to GCP severity names")
    func severityMapping() throws {
        let cases: [(Logger.Level, String)] = [
            (.trace, "DEBUG"),
            (.debug, "DEBUG"),
            (.info, "INFO"),
            (.notice, "NOTICE"),
            (.warning, "WARNING"),
            (.error, "ERROR"),
            (.critical, "CRITICAL"),
        ]
        for (level, expected) in cases {
            let json = decode(encode(level: level))
            #expect(json["severity"] as? String == expected, "\(level) → \(expected)")
        }
    }

    @Test("Plain metadata flows through as top-level fields")
    func metadataPromoted() throws {
        let json = decode(encode(callMetadata: [
            "request.id": "req-123",
            "hb.request.method": "GET",
        ]))
        #expect(json["request.id"] as? String == "req-123")
        #expect(json["hb.request.method"] as? String == "GET")
    }

    @Test("Generic trace.* metadata is renamed to GCP-special keys")
    func traceMetadataRenamed() throws {
        let json = decode(encode(
            callMetadata: [
                "trace.id": "0af7651916cd43dd8448eb211c80319c",
                "trace.span_id": "b7ad6b7169203331",
                "trace.sampled": .stringConvertible(true),
            ],
            googleCloudProject: "illumineering"
        ))
        #expect(json["logging.googleapis.com/trace"] as? String
            == "projects/illumineering/traces/0af7651916cd43dd8448eb211c80319c")
        #expect(json["logging.googleapis.com/spanId"] as? String == "b7ad6b7169203331")
        // GCP wants a real JSON bool here, not a string.
        #expect(json["logging.googleapis.com/trace_sampled"] as? Bool == true)
        // Generic keys must not also leak through under their old names.
        #expect(json["trace.id"] == nil)
        #expect(json["trace.span_id"] == nil)
        #expect(json["trace.sampled"] == nil)
    }

    @Test("Without a project the trace id is emitted bare (no resource prefix)")
    func traceWithoutProject() throws {
        let json = decode(encode(callMetadata: [
            "trace.id": "0af7651916cd43dd8448eb211c80319c",
        ]))
        #expect(json["logging.googleapis.com/trace"] as? String
            == "0af7651916cd43dd8448eb211c80319c")
    }

    @Test("Empty project string is treated the same as nil")
    func emptyProjectFallsBack() throws {
        let json = decode(encode(
            callMetadata: ["trace.id": "abc"],
            googleCloudProject: ""
        ))
        #expect(json["logging.googleapis.com/trace"] as? String == "abc")
    }

    @Test("Per-call metadata overrides handler metadata")
    func perCallOverridesHandler() throws {
        let json = decode(encode(
            handlerMetadata: ["env": "dev"],
            callMetadata: ["env": "prod"]
        ))
        #expect(json["env"] as? String == "prod")
    }

    @Test("Metadata can't clobber fixed GCP top-level keys")
    func reservedKeysProtected() throws {
        let json = decode(encode(callMetadata: [
            "severity": "BOGUS",
            "message": "spoofed",
        ]))
        #expect(json["severity"] as? String == "INFO")  // not "BOGUS"
        #expect(json["message"] as? String == "hello")  // not "spoofed"
    }

    @Test("Dictionary metadata nests as a JSON object")
    func nestedDictionaryMetadata() throws {
        let json = decode(encode(callMetadata: [
            "httpRequest": .dictionary([
                "requestMethod": .string("GET"),
                "status": .stringConvertible(200),
            ]),
        ]))
        let nested = json["httpRequest"] as? [String: Any]
        #expect(nested?["requestMethod"] as? String == "GET")
        #expect(nested?["status"] as? String == "200")
    }

    @Test("Array metadata nests as a JSON array")
    func arrayMetadata() throws {
        let json = decode(encode(callMetadata: [
            "tags": .array([.string("one"), .string("two")]),
        ]))
        let tags = json["tags"] as? [String]
        #expect(tags == ["one", "two"])
    }

    @Test("Each entry ends with a single newline")
    func newlineTerminated() {
        let raw = encode()
        #expect(raw.hasSuffix("\n"))
        let body = raw.dropLast()
        #expect(!body.contains("\n"))
    }

    @Test("File path is shortened to its basename")
    func sourceLocationShortensFile() throws {
        let json = decode(encode(file: "/long/absolute/path/to/Bar.swift"))
        let source = json["logging.googleapis.com/sourceLocation"] as? [String: Any]
        #expect(source?["file"] as? String == "Bar.swift")
    }

    // MARK: - Helpers

    private func encode(
        level: Logger.Level = .info,
        message: String = "hello",
        label: String = "latte.test",
        handlerMetadata: Logger.Metadata = [:],
        callMetadata: Logger.Metadata? = nil,
        file: String = "Foo.swift",
        function: String = "bar()",
        line: UInt = 42,
        googleCloudProject: String? = nil
    ) -> String {
        GcpJsonLogHandler.encodeEntry(
            level: level,
            message: message,
            label: label,
            handlerMetadata: handlerMetadata,
            callMetadata: callMetadata,
            file: file,
            function: function,
            line: line,
            googleCloudProject: googleCloudProject,
            now: Self.fixedDate
        )
    }

    private func decode(_ raw: String) -> [String: Any] {
        let trimmed = raw.trimmingCharacters(in: .newlines)
        let data = Data(trimmed.utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
