// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

import Foundation
import Testing
@testable import TheoNotesAutomation

@Suite struct OutputFormatTests {
    @Test func tsvEscapingAndFlags() {
        #expect(RecordWriter.tsv([[.string("a\tb\nc\\d\re"), .flag(false), .list(["#a", "#b c#"]), .list([])]])
                == "a\\tb\\nc\\\\d\\re\tno\t#a,#b c#\t\n")
    }

    @Test func tsvIntNullAndMultipleRows() {
        #expect(RecordWriter.tsv([[.int(3), .null, .flag(true)], [.string("x"), .int(-1), .null]]) == "3\t\tyes\nx\t-1\t\n")
        #expect(RecordWriter.tsv([]) == "")
    }

    @Test func csvQuotesRFC4180WithHeaderAndLF() {
        #expect(RecordWriter.csv(header: ["id", "tags"], [[.string("x\"y"), .list(["#a", "#b"])]]) == "id,tags\n\"x\"\"y\",\"#a,#b\"\n")
    }

    @Test func csvKeepsNewlinesRawInsideQuotesAndLeavesPlainFieldsBare() {
        #expect(RecordWriter.csv(header: ["a", "b", "c", "d"], [[.string("l1\nl2"), .flag(true), .int(7), .null]])
                == "a,b,c,d\n\"l1\nl2\",yes,7,\n")
        #expect(RecordWriter.csv(header: ["a"], []) == "a\n")
    }

    /// Controller ruling M5-R241: cells keep their fidelity like bearcli's, no formula neutralization.
    @Test func csvEmitsFormulaCellsAsTheyAre() {
        let rows: [[FieldValue]] = [[.string("=HYPERLINK(\"http://x\",\"y\")")], [.string("+1")], [.string("@SUM(A1)")], [.string("-2")]]
        #expect(RecordWriter.csv(header: ["title"], rows) == "title\n\"=HYPERLINK(\"\"http://x\"\",\"\"y\"\")\"\n+1\n@SUM(A1)\n-2\n")
    }

    @Test func csvQuotesBeforeCombiningMarksAndJoiners() {
        // Character-level comparison would see `"` + U+0301 as one grapheme and skip the quoting.
        #expect(RecordWriter.csv(header: ["a"], [[.string("a\"\u{0301}b")]]) == "a\n\"a\"\"\u{0301}b\"\n")
        #expect(RecordWriter.csv(header: ["a"], [[.string("x,\u{0301}y")]]) == "a\n\"x,\u{0301}y\"\n")
        #expect(RecordWriter.csv(header: ["a"], [[.string("q\"\u{200D}")]]) == "a\n\"q\"\"\u{200D}\"\n")
        #expect(RecordWriter.csv(header: ["a"], [[.string("l\n\u{0301}m")]]) == "a\n\"l\n\u{0301}m\"\n")
        #expect(RecordWriter.csv(header: ["a"], [[.string("e\u{0301}")]]) == "a\ne\u{0301}\n")
    }

    @Test func jsonObjectFromFields() {
        let v = RecordWriter.jsonObject([
            ("id", .string("N1")), ("length", .int(4)), ("locked", .flag(true)),
            ("tags", .list(["#a", "#b"])), ("subtitle", .null),
        ])
        #expect(v.serialized(sortedKeys: false) == ##"{"id":"N1","length":4,"locked":"yes","tags":["#a","#b"],"subtitle":null}"##)
    }

    @Test func jsonIsCompactKeepsOrderOrSortsAndWritesUnicodeRaw() {
        let v = JSONValue.object([("title", .string("Ä/—\n")), ("id", .int(1))])
        #expect(v.serialized(sortedKeys: false) == #"{"title":"Ä/—\n","id":1}"#)
        #expect(v.serialized(sortedKeys: true) == #"{"id":1,"title":"Ä/—\n"}"#)
    }

    @Test func jsonEscapesControlsQuotesAndBackslashes() {
        let v = JSONValue.string("a\"b\\c\n\r\t\u{08}\u{0C}\u{01}\u{1F}\u{7F}😀")
        #expect(v.serialized(sortedKeys: false) == "\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\u{7F}😀\"")
    }

    @Test func jsonSortedKeysApplyRecursivelyAndToArrays() {
        let v: JSONValue = ["b": [["z": 1, "a": .null]], "a": true]
        #expect(v.serialized(sortedKeys: true) == #"{"a":true,"b":[{"a":null,"z":1}]}"#)
    }

    @Test func jsonParsesKeepingOrderAndRoundTrips() throws {
        let text = #" { "z" : [1, -2, "xä😀\/"], "a" : { "t": true, "f": false, "n": null } } "#
        let v = try JSONValue(parsing: Data(text.utf8))
        #expect(v.keys == ["z", "a"])
        #expect(v["z"]?.array?.count == 3)
        #expect(v["z"]?.array?[2].string == "xä😀/")
        #expect(v["a"]?["t"] == .bool(true))
        #expect(v.serialized(sortedKeys: false) == #"{"z":[1,-2,"xä😀/"],"a":{"t":true,"f":false,"n":null}}"#)
    }

    @Test func jsonParseRejectsMalformedInput() {
        for bad in ["", "{", "[1,]", #"{"a":1,}"#, "01", "tru", #""\x""#, "\"a\nb\"", "[1] x", #"{"a" 1}"#, "1.", "1e", "-", "+1", ".5", "1e+", "--1", "0x1"] {
            #expect(throws: (any Error).self, "\(bad)") { try JSONValue(parsing: Data(bad.utf8)) }
        }
        #expect(throws: (any Error).self) { try JSONValue(parsing: Data(String(repeating: "[", count: 5000).utf8)) }
        #expect(throws: (any Error).self) { try JSONValue(parsing: Data([0x22, 0xFF, 0x22])) }
    }

    @Test func jsonParsesAnyValidNumberAndKeepsItsText() throws {
        let v = try JSONValue(parsing: Data(#"{"a":10.0,"b":1e3,"c":0.5,"d":-0,"e":2E-2,"f":7,"g":-12}"#.utf8))
        #expect(v["a"] == .number("10.0") && v["b"] == .number("1e3") && v["c"] == .number("0.5"))
        #expect(v["f"] == .int(7) && v["g"] == .int(-12))
        #expect(v.serialized(sortedKeys: false) == #"{"a":10.0,"b":1e3,"c":0.5,"d":-0,"e":2E-2,"f":7,"g":-12}"#)
        #expect(try JSONValue(parsing: Data(#"{"limit":10.0}"#.utf8))["limit"]?.intValue == 10)
    }

    @Test func intValueIsNilForNonIntegralOrOutOfRangeNumbers() throws {
        func int(_ text: String) throws -> Int? { try JSONValue(parsing: Data(text.utf8)).intValue }
        #expect(try int("10.0") == 10 && int("1e3") == 1000 && int("-2.0e1") == -20 && int("5") == 5 && int("0.0") == 0)
        #expect(try int("0.5") == nil && int("1e-1") == nil && int("2.0000001") == nil)
        #expect(try int("99999999999999999999") == nil && int("1e30") == nil && int("-1e30") == nil)
        #expect(JSONValue.string("5").intValue == nil && JSONValue.null.intValue == nil)
        #expect(JSONValue.int(-3).intValue == -3)
    }

    @Test func duplicateKeysLastValueWinsInFirstPosition() throws {
        let v = try JSONValue(parsing: Data(#"{"a":1,"b":2,"a":3}"#.utf8))
        #expect(v["a"] == .int(3) && v.keys == ["a", "b"])
        #expect(v.serialized(sortedKeys: false) == #"{"a":3,"b":2}"#)
    }

    @Test func nestingLimitIsExactly128Levels() {
        func nested(_ n: Int) -> Data { Data((String(repeating: "[", count: n) + String(repeating: "]", count: n)).utf8) }
        #expect(JSONValue.maxNestingDepth == 128)
        #expect(throws: Never.self) { try JSONValue(parsing: nested(128)) }
        #expect(throws: (any Error).self) { try JSONValue(parsing: nested(129)) }
        func nestedObjects(_ n: Int) -> Data {
            Data((String(repeating: #"{"a":"#, count: n) + "1" + String(repeating: "}", count: n)).utf8)
        }
        #expect(throws: Never.self) { try JSONValue(parsing: nestedObjects(128)) }
        #expect(throws: (any Error).self) { try JSONValue(parsing: nestedObjects(129)) }
    }

    @Test func jsonAccessorsAndRemovingKeys() {
        let v: JSONValue = ["a": 1, "b": ["a": 2, "c": [["a": 3, "d": "x"]]], "e": "s"]
        #expect(v["e"]?.string == "s" && v["missing"] == nil && v["a"]?.string == nil)
        #expect(v.keys == ["a", "b", "e"])
        #expect(v.removingKeys("a").serialized(sortedKeys: false) == #"{"b":{"c":[{"d":"x"}]},"e":"s"}"#)
        #expect(JSONValue.string("x").keys == [] && JSONValue.string("x").array == nil)
    }

    @Test func unescapeTextFlags() { #expect(TextEscapes.unescape(#"a\nb\tc\\n\q"#) == "a\nb\tc\\n\\q") }

    @Test func unescapeKeepsTrailingBackslashAndRoundTripsEscapeTSV() {
        #expect(TextEscapes.unescape(#"end\"#) == #"end\"#)
        let raw = "a\tb\nc\\d\re\\n"
        #expect(TextEscapes.unescape(TextEscapes.escapeTSV(raw)) == raw)
    }

    @Test func errorEnvelopeAndExitCodes() {
        let e = AutomationError(code: .noteNotFound, message: "Note not found: X", details: nil)
        #expect(e.envelope().serialized(sortedKeys: false) == #"{"error":{"code":"note_not_found","message":"Note not found: X"}}"#)
        #expect(e.exitCode == 1 && AutomationError(code: .usage, message: "", details: nil).exitCode == 64)
    }

    @Test func errorEnvelopeIncludesDetailsAndCodesAreSnakeCase() {
        let e = AutomationError(code: .ambiguous, message: "m", details: ["ids": ["A", "B"]])
        #expect(e.envelope().serialized(sortedKeys: false) == #"{"error":{"code":"ambiguous","message":"m","details":{"ids":["A","B"]}}}"#)
        let codes: [ErrorCode: String] = [
            .usage: "usage", .noteNotFound: "note_not_found", .notFound: "not_found", .ambiguous: "ambiguous",
            .noteLocked: "note_locked", .readOnly: "read_only", .outOfScope: "out_of_scope", .staleHash: "stale_hash",
            .attachmentsRemoved: "attachments_removed", .tagExists: "tag_exists", .lockedNotes: "locked_notes",
            .tagNotFound: "tag_not_found", .attachmentNotFound: "attachment_not_found", .invalidURL: "invalid_url",
            .fetchFailed: "fetch_failed", .libraryUnavailable: "library_unavailable", .appUnavailable: "app_unavailable",
            .busy: "busy", .internal: "internal", .appLocked: "app_locked",
        ]
        for (code, raw) in codes { #expect(code.rawValue == raw) }
        #expect(codes.count == 20)
    }

    @Test func contextFixedClockAndLiveDefaults() {
        let fixed = AutomationContext.fixed(TestLibrary.epoch)
        #expect(fixed.now() == TestLibrary.epoch)
        #expect(AutomationContext.live.now() > TestLibrary.epoch)
        #expect(AutomationContext.live.calendar == Calendar.autoupdatingCurrent)
        #expect(AutomationContext.live.locale == Locale.autoupdatingCurrent)
    }

    @Test func versionMatchesProjectYml() throws {
        // …/Packages/TheoNotesCore/Tests/TheoNotesAutomationTests/OutputFormatTests.swift → repo root
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        func value(_ key: String) -> String? {
            yml.split(separator: "\n").lazy.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(key + ":") else { return nil }
                return trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }.first
        }
        #expect(value("MARKETING_VERSION") == AutomationVersion.marketing)
        #expect(value("CURRENT_PROJECT_VERSION") == AutomationVersion.build)
        #expect(AutomationVersion.string == "\(AutomationVersion.marketing) (\(AutomationVersion.build))")
    }
}
