// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation
@testable import TheoNotesCore

/// Replays `Fixtures/cli/cli-observed.json` against the read commands: the error cases word
/// for word, the success shapes by key order and value kind.
@Suite struct ReadCommandsContractTests {
    private static func observed() throws -> JSONValue {
        try JSONValue(parsing: Data(contentsOf: ArgvParserTests.observedURL))
    }

    private static let readCommands: [[String]] = [["list"], ["search"], ["show"], ["tags", "list"], ["pin", "list"]]

    private static func isReadCommand(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if first == "tags" || first == "pin" { return args.count >= 2 && args[1] == "list" }
        return readCommands.contains([first])
    }

    private static func reworded(_ s: String) -> String {
        s.replacingOccurrences(of: "bearcli", with: "theonotes").replacingOccurrences(of: "Bear ", with: "Theo Notes ")
    }

    /// Errors of list, search, show, tags list and pin list that the command itself reports (the
    /// parser's own are replayed by `ArgvParserTests`) come out identically, against an empty library.
    @Test func commandLevelErrorsEqualTheObservedBearcliOutput() throws {
        let lib = try TestLibrary.make()
        let parserMarkers = ["Missing value for", "is invalid for", "Unknown option", "Unexpected argument", "Query starts with"]
        var checked = 0
        for entry in try Self.observed()["errors"]?.array ?? [] {
            let args = (entry["args"]?.array ?? []).compactMap(\.string)
            guard Self.isReadCommand(args) else { continue }
            let stdout = entry["stdout"]?.string ?? ""
            let stderr = entry["stderr"]?.string ?? ""
            if parserMarkers.contains(where: { stdout.contains($0) || stderr.contains($0) }) { continue }
            let run = cli(lib, args)
            #expect(run.exit == Int32(entry["exit"]?.intValue ?? -1), "\(args)")
            // Messages are our own wording: the exit status, the error code of a JSON reply,
            // the stream the text goes to and the `Error: ` lead of a plain one are what is compared.
            if stdout.isEmpty {
                #expect(run.out.isEmpty, "\(args)")
                #expect(run.err.hasPrefix("Error: ") == stderr.hasPrefix("Error: "), "\(args)")
                #expect(stderr.isEmpty ? run.err.isEmpty : !run.err.isEmpty, "\(args)")
            } else if let wanted = try? JSONValue(parsing: Data(stdout.utf8)), wanted["error"] != nil {
                let got = try JSONValue(parsing: Data(run.out.utf8))
                #expect(got["error"]?["code"] == wanted["error"]?["code"], "\(args)")
                #expect(got["error"]?.keys == wanted["error"]?.keys, "\(args)")
                #expect(run.err.isEmpty, "\(args)")
            } else {
                #expect(run.out == Self.reworded(stdout), "\(args)")
                #expect(run.err == Self.reworded(stderr), "\(args)")
            }
            checked += 1
        }
        #expect(checked >= 18)
    }

    private func cli(_ lib: TestLibrary, _ args: [String]) -> CLIResult {
        runCLI(["baerchen", "--data-dir", lib.paths.root.path] + args)
    }

    // MARK: Shapes

    private static func fields(of value: JSONValue?) -> [(String, JSONValue)] {
        if case .object(let fields)? = value { return fields }
        return []
    }

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

    /// Same keys in the same order, same kinds of values; arrays compare their first elements
    /// when both sides have one (the fixture's tag and pin lists are masked, so their length differs).
    private static func sameShape(_ actual: JSONValue, _ template: JSONValue, path: String = "$") -> [String] {
        let isNumberTemplate = template == .string("int")
        let wantedKind = isNumberTemplate ? "number" : kind(template)
        guard kind(actual) == wantedKind else { return ["\(path): \(kind(actual)) instead of \(wantedKind)"] }
        switch (actual, template) {
        case (.object, .object):
            guard actual.keys == template.keys else { return ["\(path): keys \(actual.keys) instead of \(template.keys)"] }
            return template.keys.flatMap { key in sameShape(actual[key]!, template[key]!, path: path + "." + key) }
        case (.array(let a), .array(let t)):
            guard let a = a.first, let t = t.first else { return [] }
            return sameShape(a, t, path: path + "[0]")
        default:
            return []
        }
    }

    private func shapesLibrary() throws -> (TestLibrary, String) {
        let lib = try TestLibrary.make(
            [
                TestNote(text: "# Alpha\n#a #a/b\n- [ ] t\n- [x] d\ne", pinned: true),
                TestNote(text: "# Beta\ne"),
            ])
        return (lib, try lib.id(titled: "Alpha"))
    }

    @Test func jsonShapesEqualTheObservedOnes() throws {
        let (lib, alpha) = try shapesLibrary()
        let shapes = try Self.observed()["shapes"]
        var checked = 0
        var problems: [String] = []
        for (name, shape) in Self.fields(of: shapes) {
            var args = (shape["args"]?.array ?? []).compactMap(\.string)
            guard Self.isReadCommand(args), args.contains("json"), !args.contains("<ID-ATTACHMENTS>"),
                let template = shape["stdout"], Self.kind(template) != "string"
            else { continue }
            args = args.map { $0.hasPrefix("<ID") ? alpha : $0 }
            let run = cli(lib, args)
            if run.exit != 0 { problems.append("\(name): exit \(run.exit) \(run.err)"); continue }
            let actual = try run.json()
            problems += Self.sameShape(actual, template).map { "\(name) \($0)" }
            checked += 1
        }
        #expect(problems.isEmpty, "\(problems)")
        #expect(checked >= 10)
    }

    @Test func tsvAndCsvShapesEqualTheObservedOnes() throws {
        let (lib, alpha) = try shapesLibrary()
        var checked = 0
        for (name, shape) in Self.fields(of: try Self.observed()["shapes"]) {
            var args = (shape["args"]?.array ?? []).compactMap(\.string)
            guard Self.isReadCommand(args), !args.contains("json"), !args.contains("<ID-ATTACHMENTS>"),
                let rows = shape["stdout"]?.array, let first = rows.first?.array
            else { continue }
            args = args.map { $0.hasPrefix("<ID") ? alpha : $0 }
            let run = cli(lib, args)
            #expect(run.exit == 0, "\(name)")
            let isCSV = args.contains("csv")
            let firstLine = String(run.out.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
            if isCSV {
                #expect(firstLine == first.compactMap(\.string).joined(separator: ","), "\(name)")
            } else {
                #expect(firstLine.split(separator: "\t", omittingEmptySubsequences: false).count == first.count, "\(name)")
            }
            checked += 1
        }
        #expect(checked >= 5)
    }

    @Test func emptyAndCountOutputsMatchTheObservedFacts() throws {
        let facts = try #require(try Self.observed()["facts"])
        let lib = try TestLibrary.make([TestNote(text: "# One"), TestNote(text: "# Two")])
        #expect(facts["zeroLimitPrintsNothing"] == .bool(true))
        let zero = cli(lib, ["list", "-n", "0"])
        #expect(zero.exit == 0 && zero.out == "" && zero.err == "")
        func expected(_ key: String) -> String? {
            facts[key]?["expected"]?.string?.replacingOccurrences(of: "N", with: "2")
        }
        #expect(cli(lib, ["list", "--count"]).out == expected("countTSV"))
        #expect(cli(lib, ["list", "--count", "--format", "csv"]).out == expected("countCSV"))
        #expect(cli(lib, ["list", "--count", "--format", "json"]).out == expected("countJSON"))
        #expect(cli(lib, ["search", "One", "--count", "--format", "json"]).out == #"{"count":1}"# + "\n")
        #expect(cli(lib, ["tags", "list", "--count", "--format", "json"]).out == #"{"count":0}"# + "\n")
        let allKeys = (facts["cliListAllKeys"]?.array ?? []).compactMap(\.string)
        let row = try #require(try cli(lib, ["list", "--fields", "all", "--format", "json"]).json().array?.first)
        #expect(row.keys == allKeys)
        let searchKeys = (facts["cliSearchAllKeys"]?.array ?? []).compactMap(\.string)
        let hit = try #require(try cli(lib, ["search", "One", "--fields", "all", "--format", "json"]).json().array?.first)
        #expect(hit.keys == searchKeys)
        let searchContent = (facts["cliSearchAllContentKeys"]?.array ?? []).compactMap(\.string)
        let withContent = try #require(try cli(lib, ["search", "One", "--fields", "all,content", "--format", "json"]).json().array?.first)
        #expect(withContent.keys == searchContent)
    }
}
