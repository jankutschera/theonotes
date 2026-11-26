// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// Replays the tool calls of `probeMCP` (Fixtures/cli/cli-observed.json, `shapes` named `mcp-…`)
/// through `MCPServer` and `MCPTools`: error envelopes word for word, success results by key order
/// (sorted at every level) and value kind. Masked values in the fixture (ids, titles, tag names) are
/// only compared by kind.
@Suite struct MCPToolsContractTests {
    private static func kind(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "bool"
        case .int, .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    private static func sameShape(_ actual: JSONValue, _ template: JSONValue, path: String = "$") -> [String] {
        let wanted: String
        switch template {
        case .string("int"): wanted = "number"
        case .string("bool"): wanted = "bool"
        default: wanted = kind(template)
        }
        guard kind(actual) == wanted else { return ["\(path): \(kind(actual)) instead of \(wanted)"] }
        switch (actual, template) {
        case (.object, .object):
            guard actual.keys == template.keys else { return ["\(path): keys \(actual.keys) instead of \(template.keys)"] }
            return template.keys.flatMap { sameShape(actual[$0]!, template[$0]!, path: path + "." + $0) }
        case (.array(let a), .array(let t)):
            guard let a = a.first, let t = t.first else { return [] }
            return sameShape(a, t, path: path + "[0]")
        default:
            return []
        }
    }

    private static let notes: [TestNote] = [
        TestNote(text: "# Alpha\n#a-a/a #a-a\n- [ ] t\n- [x] d\ne lead\n", pinned: true),
        TestNote(text: "# Sectioned\nlead e\n## Same\none e\n## Same\ntwo e\n"),
        TestNote(text: "# Files\nbody e"),
    ]

    @Test func observedToolCallsAnswerWithTheObservedShapes() async throws {
        let f = try ToolFixture(Self.notes)
        let alpha = try f.lib.id(titled: "Alpha")
        let sectioned = try f.lib.id(titled: "Sectioned")
        let files = try f.lib.id(titled: "Files")
        let service = AutomationService(library: f.lib.library, context: .fixed(TestLibrary.epoch))
        _ = try service.addAttachment(.id(files), data: Data([1, 2, 3]), filename: "a-9.jpg", preservingModifiedDate: false)
        let outline = try await f.ok("read_note_outline", #"{"id":"\#(sectioned)"}"#)["outline"]?.array ?? []
        let sameAddresses = outline.compactMap { $0["address"]?.string }.filter { $0.contains("Same") && !$0.hasSuffix("preamble") }
        let firstAddress = try #require(outline.first?["address"]?.string)

        let observed = try MCPFixtures.load("Fixtures/cli/cli-observed.json")
        var checked = 0
        var problems: [String] = []
        for (name, shape) in observedShapes(observed) {
            guard let call = shape["request"]?["params"], let tool = call["name"]?.string, shape["request"]?["method"] == "tools/call",
                tool != "no_such_tool", case .object(let argFields)? = call["arguments"]
            else { continue }
            var arguments: [(String, JSONValue)] = []
            for (key, value) in argFields {
                var value = value
                switch value.string {
                case "<ID>", "<ID-MULTI-TAG>": value = .string(alpha)
                case "<ID-SECTIONED>": value = .string(sectioned)
                case "<ID-ATTACHMENTS>": value = .string(files)
                case "<ADDRESS-MISSING>": value = "## Nope"
                case "<ADDRESS-AMBIGUOUS>": value = "## Same"
                default: if key == "address" { value = .string(firstAddress) }
                }
                arguments.append((key, value))
            }
            let request = JSONValue.object([
                ("jsonrpc", "2.0"), ("id", 1), ("method", "tools/call"),
                ("params", .object([("name", .string(tool)), ("arguments", .object(arguments))])),
            ])
            let replies = try await runServer([request.serialized(sortedKeys: false)], handler: f.tools)
            let result = try #require(replies.first?["result"], "\(name)")
            let expected = try #require(shape["response"]?["result"])
            let isError = expected["isError"] != nil
            if isError {
                #expect(result["isError"] == true, "\(name)")
                #expect(result.keys.sorted() == ["content", "isError"], "\(name)")
                let text = try #require(result["content"]?.array?.first?["text"]?.string)
                let envelope = try JSONValue(parsing: Data(text.utf8))
                let want = try #require(expected["content"]?.array?.first?["text"])
                #expect(envelope["error"]?["code"] == want["error"]?["code"], "\(name)")
                if name.contains("ambiguous") {
                    #expect(envelope["error"]?["message"] == "2 sections match that address; repeat the call with one of the candidates.")
                    problems += Self.sameShape(envelope["error"]?["details"] ?? .null, want["error"]?["details"] ?? .null).map { "\(name) \($0)" }
                } else {
                    // Messages are our own wording: the code and the shape are what is compared.
                    #expect(envelope["error"]?["message"]?.string?.isEmpty == false, "\(name)")
                    #expect(envelope["error"]?.keys == want["error"]?.keys, "\(name)")
                }
                #expect(text == envelope.serialized(sortedKeys: true), "\(name)")
            } else {
                #expect(result.keys == ["content", "structuredContent"], "\(name)")
                problems += Self.sameShape(result["structuredContent"] ?? .null, expected["structuredContent"] ?? .null)
                    .map { "\(name) \($0)" }
                let text = try #require(result["content"]?.array?.first?["text"]?.string)
                #expect(text == result["structuredContent"]?.serialized(sortedKeys: true), "\(name)")
            }
            checked += 1
        }
        #expect(problems.isEmpty, "\(problems)")
        #expect(checked >= 30, "replayed \(checked)")
        #expect(sameAddresses.count == 2)
    }

    private func observedShapes(_ observed: JSONValue) -> [(String, JSONValue)] {
        guard case .object(let fields)? = observed["shapes"] else { return [] }
        return fields.filter { $0.0.hasPrefix("mcp-") }
    }
}
